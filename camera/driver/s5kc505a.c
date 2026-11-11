// SPDX-License-Identifier: GPL-2.0
/*
 * Samsung S5KC505A camera sensor (Lenovo ThinkSmart View front camera).
 *
 * Minimal driver: register tables come from the vendor Android sensor library
 * (libmmcamera_s5kc505a.so). SMIA-style register map, 2-lane MIPI CSI-2, RAW10.
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/regulator/consumer.h>
#include <media/v4l2-cci.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-subdev.h>

#include "s5kc505a_regs.h"

#define S5KC505A_REG_CHIP_ID		CCI_REG16(0x0000)
#define S5KC505A_CHIP_ID		0x5034
#define S5KC505A_REG_MODE_SELECT	CCI_REG8(0x0100)
#define S5KC505A_REG_EXPOSURE		CCI_REG16(0x0202)
#define S5KC505A_REG_AGAIN		CCI_REG16(0x0204)
#define S5KC505A_REG_FLL		CCI_REG16(0x0340)

#define S5KC505A_MCLK			24000000
#define S5KC505A_LANES			2
#define S5KC505A_BPP			10
#define S5KC505A_AGAIN_MIN		0x20	/* 1x */
#define S5KC505A_AGAIN_MAX		0x200	/* 16x */
#define S5KC505A_EXPOSURE_MARGIN	8
/*
 * Default frame rate. libcamera's simple pipeline leaves VBLANK alone, so this caps the
 * auto-exposure time: 10 fps allows 100 ms exposures for dim rooms.
 */
#define S5KC505A_DEFAULT_FPS		10
#define S5KC505A_DEFAULT_GAIN		0x80	/* 4x: start bright, AE converges faster indoors */

/* Per-lane bit rate (Mbps) is what the mode tables request in 0x0820; link freq = half. */
static const s64 s5kc505a_link_freqs[] = { 129000000, 429000000, 480000000 };

struct s5kc505a_mode {
	u32 width, height;
	struct v4l2_rect crop;	/* analogue crop in native pixel-array coordinates */
	u32 fll, llp;
	unsigned int link_freq_idx;
	const struct cci_reg_sequence *regs;
	unsigned int num_regs;
};

#define S5KC505A_NATIVE_W		2608
#define S5KC505A_NATIVE_H		1960

/* Crops from the x/y_addr_start/end registers (0x0344-0x034b) of each vendor mode table. */
#define MODE(w, h, cx, cy, cw, ch, f, l, lf, r) \
	{ w, h, { cx, cy, cw, ch }, f, l, lf, r, ARRAY_SIZE(r) }
static const struct s5kc505a_mode s5kc505a_modes[] = {
	MODE(1304, 980, 0, 0, 2608, 1960, 0x07ee, 0x0c28, 2, s5kc505a_1304x980),	/* 2x2 binned, full FoV */
	MODE(2608, 1960, 0, 0, 2608, 1960, 0x07ee, 0x0c28, 2, s5kc505a_2608x1960),
	MODE(1936, 1096, 336, 432, 1936, 1096, 0x048e, 0x0ac8, 1, s5kc505a_1936x1096),
	MODE(1296, 736, 8, 244, 2592, 1472, 0x0326, 0x0ac8, 1, s5kc505a_1296x736),
	MODE(640, 490, 24, 0, 2560, 1960, 0x0235, 0x0af0, 0, s5kc505a_640x490),
};

static const char * const s5kc505a_supplies[] = { "dovdd", "avdd", "dvdd" };

/* Bayer order is not documented; overridable while bringing the sensor up. */
static unsigned int bayer;
module_param(bayer, uint, 0444);
MODULE_PARM_DESC(bayer, "0=GRBG 1=RGGB 2=BGGR 3=GBRG");
static const u32 s5kc505a_codes[] = {
	MEDIA_BUS_FMT_SGRBG10_1X10, MEDIA_BUS_FMT_SRGGB10_1X10,
	MEDIA_BUS_FMT_SBGGR10_1X10, MEDIA_BUS_FMT_SGBRG10_1X10,
};

struct s5kc505a {
	struct device *dev;
	struct regmap *regmap;
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct clk *mclk;
	struct gpio_desc *reset, *standby;
	struct regulator_bulk_data supplies[ARRAY_SIZE(s5kc505a_supplies)];
	struct v4l2_ctrl_handler ctrls;
	struct v4l2_ctrl *link_freq, *pixel_rate, *exposure, *vblank, *hblank;
	const struct s5kc505a_mode *mode;
	bool streaming;
};

static inline struct s5kc505a *to_s5kc505a(struct v4l2_subdev *sd)
{
	return container_of(sd, struct s5kc505a, sd);
}

static u32 s5kc505a_code(void)
{
	return s5kc505a_codes[bayer & 3];
}

static int s5kc505a_power_on(struct s5kc505a *s)
{
	int ret;

	ret = regulator_bulk_enable(ARRAY_SIZE(s->supplies), s->supplies);
	if (ret)
		return ret;
	usleep_range(1000, 2000);
	ret = clk_prepare_enable(s->mclk);
	if (ret) {
		regulator_bulk_disable(ARRAY_SIZE(s->supplies), s->supplies);
		return ret;
	}
	gpiod_set_value_cansleep(s->standby, 0);
	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(s->reset, 0);
	usleep_range(10000, 12000);
	return 0;
}

static void s5kc505a_power_off(struct s5kc505a *s)
{
	gpiod_set_value_cansleep(s->reset, 1);
	gpiod_set_value_cansleep(s->standby, 1);
	clk_disable_unprepare(s->mclk);
	regulator_bulk_disable(ARRAY_SIZE(s->supplies), s->supplies);
}

static void s5kc505a_update_blank(struct s5kc505a *s)
{
	const struct s5kc505a_mode *m = s->mode;
	s64 pixel_rate = div_s64(s5kc505a_link_freqs[m->link_freq_idx] * 2 * S5KC505A_LANES,
				 S5KC505A_BPP);

	__v4l2_ctrl_s_ctrl(s->link_freq, m->link_freq_idx);
	__v4l2_ctrl_modify_range(s->pixel_rate, pixel_rate, pixel_rate, 1, pixel_rate);
	__v4l2_ctrl_modify_range(s->hblank, m->llp - m->width, m->llp - m->width, 1,
				 m->llp - m->width);
	/* A new mode starts at S5KC505A_DEFAULT_FPS (never faster than its own frame length). */
	u32 fll = max_t(u32, m->fll, div_s64(pixel_rate, (s64)m->llp * S5KC505A_DEFAULT_FPS));

	fll = min_t(u32, fll, 0xffff);
	__v4l2_ctrl_modify_range(s->vblank, m->fll - m->height, 0xffff - m->height, 1,
				 fll - m->height);
	__v4l2_ctrl_s_ctrl(s->vblank, fll - m->height);
	__v4l2_ctrl_modify_range(s->exposure, 1, fll - S5KC505A_EXPOSURE_MARGIN, 1,
				 fll - S5KC505A_EXPOSURE_MARGIN);
	__v4l2_ctrl_s_ctrl(s->exposure, fll - S5KC505A_EXPOSURE_MARGIN);
}

static int s5kc505a_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct s5kc505a *s = container_of(ctrl->handler, struct s5kc505a, ctrls);
	int ret = 0;

	if (ctrl->id == V4L2_CID_VBLANK) {
		u32 max = s->mode->height + ctrl->val - S5KC505A_EXPOSURE_MARGIN;

		__v4l2_ctrl_modify_range(s->exposure, 1, max, 1,
					 min_t(u32, s->exposure->val, max));
	}
	if (!s->streaming)
		return 0;	/* applied by __v4l2_ctrl_handler_setup() at stream on */

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		cci_write(s->regmap, S5KC505A_REG_EXPOSURE, ctrl->val, &ret);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		cci_write(s->regmap, S5KC505A_REG_AGAIN, ctrl->val, &ret);
		break;
	case V4L2_CID_VBLANK:
		cci_write(s->regmap, S5KC505A_REG_FLL, s->mode->height + ctrl->val, &ret);
		break;
	}
	return ret;
}

static const struct v4l2_ctrl_ops s5kc505a_ctrl_ops = {
	.s_ctrl = s5kc505a_set_ctrl,
};

static int s5kc505a_start(struct s5kc505a *s)
{
	const struct s5kc505a_mode *m = s->mode;
	int ret;

	ret = s5kc505a_power_on(s);
	if (ret)
		return ret;
	/* vendor table: 10 ms after the first write (0x0a02) */
	ret = cci_multi_reg_write(s->regmap, s5kc505a_global, 1, NULL);
	msleep(10);
	if (!ret)
		ret = cci_multi_reg_write(s->regmap, s5kc505a_global + 1,
					  ARRAY_SIZE(s5kc505a_global) - 1, NULL);
	if (!ret)
		ret = cci_multi_reg_write(s->regmap, m->regs, m->num_regs, NULL);
	if (ret)
		goto err;
	s->streaming = true;
	ret = __v4l2_ctrl_handler_setup(&s->ctrls);
	if (ret)
		goto err;
	ret = cci_write(s->regmap, S5KC505A_REG_MODE_SELECT, 1, NULL);
	if (ret)
		goto err;
	return 0;
err:
	s->streaming = false;
	s5kc505a_power_off(s);
	return ret;
}

static int s5kc505a_s_stream(struct v4l2_subdev *sd, int enable)
{
	struct s5kc505a *s = to_s5kc505a(sd);
	struct v4l2_subdev_state *state = v4l2_subdev_lock_and_get_active_state(sd);
	int ret = 0;

	if (enable && !s->streaming) {
		ret = s5kc505a_start(s);
	} else if (!enable && s->streaming) {
		cci_write(s->regmap, S5KC505A_REG_MODE_SELECT, 0, NULL);
		s->streaming = false;
		s5kc505a_power_off(s);
	}
	v4l2_subdev_unlock_state(state);
	return ret;
}

static void s5kc505a_fill_fmt(const struct s5kc505a_mode *m, struct v4l2_mbus_framefmt *f)
{
	f->width = m->width;
	f->height = m->height;
	f->code = s5kc505a_code();
	f->field = V4L2_FIELD_NONE;
	f->colorspace = V4L2_COLORSPACE_RAW;
	f->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
	f->quantization = V4L2_QUANTIZATION_FULL_RANGE;
	f->xfer_func = V4L2_XFER_FUNC_NONE;
}

static int s5kc505a_set_fmt(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
			    struct v4l2_subdev_format *fmt)
{
	struct s5kc505a *s = to_s5kc505a(sd);
	const struct s5kc505a_mode *m;

	m = v4l2_find_nearest_size(s5kc505a_modes, ARRAY_SIZE(s5kc505a_modes), width, height,
				   fmt->format.width, fmt->format.height);
	s5kc505a_fill_fmt(m, &fmt->format);
	*v4l2_subdev_state_get_format(state, 0) = fmt->format;
	if (fmt->which == V4L2_SUBDEV_FORMAT_ACTIVE) {
		if (s->streaming)
			return -EBUSY;
		s->mode = m;
		s5kc505a_update_blank(s);
	}
	return 0;
}

static int s5kc505a_get_selection(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
				  struct v4l2_subdev_selection *sel)
{
	struct s5kc505a *s = to_s5kc505a(sd);

	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
		sel->r = s->mode->crop;
		return 0;
	case V4L2_SEL_TGT_NATIVE_SIZE:
	case V4L2_SEL_TGT_CROP_BOUNDS:
	case V4L2_SEL_TGT_CROP_DEFAULT:
		sel->r = (struct v4l2_rect){ 0, 0, S5KC505A_NATIVE_W, S5KC505A_NATIVE_H };
		return 0;
	}
	return -EINVAL;
}

static int s5kc505a_enum_mbus_code(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
				   struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index)
		return -EINVAL;
	code->code = s5kc505a_code();
	return 0;
}

static int s5kc505a_enum_frame_size(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
				    struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index >= ARRAY_SIZE(s5kc505a_modes) || fse->code != s5kc505a_code())
		return -EINVAL;
	fse->min_width = fse->max_width = s5kc505a_modes[fse->index].width;
	fse->min_height = fse->max_height = s5kc505a_modes[fse->index].height;
	return 0;
}

static int s5kc505a_init_state(struct v4l2_subdev *sd, struct v4l2_subdev_state *state)
{
	s5kc505a_fill_fmt(&s5kc505a_modes[0], v4l2_subdev_state_get_format(state, 0));
	return 0;
}

static const struct v4l2_subdev_video_ops s5kc505a_video_ops = {
	.s_stream = s5kc505a_s_stream,
};

static const struct v4l2_subdev_pad_ops s5kc505a_pad_ops = {
	.enum_mbus_code = s5kc505a_enum_mbus_code,
	.enum_frame_size = s5kc505a_enum_frame_size,
	.get_fmt = v4l2_subdev_get_fmt,
	.set_fmt = s5kc505a_set_fmt,
	.get_selection = s5kc505a_get_selection,
};

static const struct v4l2_subdev_ops s5kc505a_subdev_ops = {
	.video = &s5kc505a_video_ops,
	.pad = &s5kc505a_pad_ops,
};

static const struct v4l2_subdev_internal_ops s5kc505a_internal_ops = {
	.init_state = s5kc505a_init_state,
};

static int s5kc505a_init_controls(struct s5kc505a *s)
{
	struct v4l2_ctrl_handler *h = &s->ctrls;
	struct v4l2_fwnode_device_properties props;
	int ret;

	v4l2_ctrl_handler_init(h, 10);
	s->link_freq = v4l2_ctrl_new_int_menu(h, &s5kc505a_ctrl_ops, V4L2_CID_LINK_FREQ,
					      ARRAY_SIZE(s5kc505a_link_freqs) - 1, 0,
					      s5kc505a_link_freqs);
	if (s->link_freq)
		s->link_freq->flags |= V4L2_CTRL_FLAG_READ_ONLY;
	s->pixel_rate = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_PIXEL_RATE, 1, 1, 1, 1);
	s->hblank = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_HBLANK, 0, 0, 1, 0);
	if (s->hblank)
		s->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;
	s->vblank = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_VBLANK, 0, 0xffff, 1, 0);
	s->exposure = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_EXPOSURE, 1, 0xffff, 1, 0x100);
	v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_ANALOGUE_GAIN, S5KC505A_AGAIN_MIN,
			  S5KC505A_AGAIN_MAX, 1, S5KC505A_DEFAULT_GAIN);

	ret = v4l2_fwnode_device_parse(s->dev, &props);
	if (!ret)
		v4l2_ctrl_new_fwnode_properties(h, &s5kc505a_ctrl_ops, &props);
	if (h->error)
		return h->error;
	mutex_lock(h->lock);
	s5kc505a_update_blank(s);
	mutex_unlock(h->lock);
	s->sd.ctrl_handler = h;
	return 0;
}

static int s5kc505a_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct s5kc505a *s;
	u64 id = 0;
	unsigned int i;
	int ret;

	s = devm_kzalloc(dev, sizeof(*s), GFP_KERNEL);
	if (!s)
		return -ENOMEM;
	s->dev = dev;
	s->mode = &s5kc505a_modes[0];

	s->mclk = devm_clk_get(dev, NULL);
	if (IS_ERR(s->mclk))
		return dev_err_probe(dev, PTR_ERR(s->mclk), "no clock\n");
	ret = clk_set_rate(s->mclk, S5KC505A_MCLK);
	if (ret)
		return dev_err_probe(dev, ret, "cannot set mclk to 24 MHz\n");
	s->reset = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(s->reset))
		return dev_err_probe(dev, PTR_ERR(s->reset), "no reset gpio\n");
	s->standby = devm_gpiod_get_optional(dev, "standby", GPIOD_OUT_HIGH);
	if (IS_ERR(s->standby))
		return dev_err_probe(dev, PTR_ERR(s->standby), "bad standby gpio\n");
	for (i = 0; i < ARRAY_SIZE(s5kc505a_supplies); i++)
		s->supplies[i].supply = s5kc505a_supplies[i];
	ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(s->supplies), s->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "supplies\n");
	s->regmap = devm_cci_regmap_init_i2c(client, 16);
	if (IS_ERR(s->regmap))
		return PTR_ERR(s->regmap);

	ret = s5kc505a_power_on(s);
	if (ret)
		return dev_err_probe(dev, ret, "power on\n");
	ret = cci_read(s->regmap, S5KC505A_REG_CHIP_ID, &id, NULL);
	s5kc505a_power_off(s);
	if (ret)
		return dev_err_probe(dev, ret, "cannot read chip id\n");
	if (id != S5KC505A_CHIP_ID)
		return dev_err_probe(dev, -ENODEV, "chip id 0x%04llx != 0x%04x\n", id,
				     S5KC505A_CHIP_ID);

	v4l2_i2c_subdev_init(&s->sd, client, &s5kc505a_subdev_ops);
	s->sd.internal_ops = &s5kc505a_internal_ops;
	s->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	s->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	ret = s5kc505a_init_controls(s);
	if (ret)
		goto err_ctrls;
	s->pad.flags = MEDIA_PAD_FL_SOURCE;
	ret = media_entity_pads_init(&s->sd.entity, 1, &s->pad);
	if (ret)
		goto err_ctrls;
	s->sd.state_lock = s->ctrls.lock;
	ret = v4l2_subdev_init_finalize(&s->sd);
	if (ret)
		goto err_entity;
	ret = v4l2_async_register_subdev_sensor(&s->sd);
	if (ret)
		goto err_state;
	dev_info(dev, "S5KC505A (id 0x%04llx) ready\n", id);
	return 0;

err_state:
	v4l2_subdev_cleanup(&s->sd);
err_entity:
	media_entity_cleanup(&s->sd.entity);
err_ctrls:
	v4l2_ctrl_handler_free(&s->ctrls);
	return ret;
}

static void s5kc505a_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct s5kc505a *s = to_s5kc505a(sd);

	v4l2_async_unregister_subdev(sd);
	v4l2_subdev_cleanup(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(&s->ctrls);
	if (s->streaming)
		s5kc505a_power_off(s);
}

static const struct of_device_id s5kc505a_of_match[] = {
	{ .compatible = "samsung,s5kc505a" },
	{ }
};
MODULE_DEVICE_TABLE(of, s5kc505a_of_match);

static struct i2c_driver s5kc505a_driver = {
	.driver = {
		.name = "s5kc505a",
		.of_match_table = s5kc505a_of_match,
	},
	.probe = s5kc505a_probe,
	.remove = s5kc505a_remove,
};
module_i2c_driver(s5kc505a_driver);

MODULE_DESCRIPTION("Samsung S5KC505A sensor driver (ThinkSmart View)");
MODULE_LICENSE("GPL");
