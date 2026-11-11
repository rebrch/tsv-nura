#!/bin/sh
# Live front camera for master-control: MJPEG on stdout as multipart parts (boundary "mcframe",
# each with Content-Length) until the reader goes away. Runs only while someone watches.
# libcamera (simple pipeline + soft ISP, S5KC505A helper) -> rotate upright (sensor mounted at 270) -> JPEG.
export LIBCAMERA_LOG_LEVELS='*:ERROR' MESA_SHADER_CACHE_DISABLE=true
exec gst-launch-1.0 -q libcamerasrc \
	! video/x-raw,width=1024,height=768,framerate=5/1 \
	! videoflip method=counterclockwise \
	! videoconvert ! jpegenc quality=60 \
	! multipartmux boundary=mcframe ! fdsink fd=1 sync=false
