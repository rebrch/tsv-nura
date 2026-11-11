"""Develop packed RAW10 GRBG frames from the S5KC505A: average frames, demosaic, white balance, gamma, rotate.
usage: develop.py raw.bin W H NFRAMES out.png"""
import sys, numpy as np
from PIL import Image
path, W, H, N, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
d = np.fromfile(path, np.uint8)
fs = d.size // N; stride = fs // H
frames = d[: fs * N].reshape(N, H, stride)[:, :, : W * 5 // 4].reshape(N, H, W // 4, 5).astype(np.uint16)
lo = frames[..., 4]
px = np.stack([(frames[..., k] << 2) | ((lo >> (2 * k)) & 3) for k in range(4)], -1).reshape(N, H, W)
raw = np.clip(px.astype(np.float32).mean(0) - 64, 0, None)          # average + black level
# bilinear demosaic, GRBG: (0,0)=G (0,1)=R (1,0)=B (1,1)=G
R = np.zeros_like(raw); G = np.zeros_like(raw); B = np.zeros_like(raw)
R[0::2, 1::2] = raw[0::2, 1::2]; B[1::2, 0::2] = raw[1::2, 0::2]
G[0::2, 0::2] = raw[0::2, 0::2]; G[1::2, 1::2] = raw[1::2, 1::2]
def conv(a, k):
    p = np.pad(a, 1, mode="reflect"); o = np.zeros_like(a)
    for dy in range(3):
        for dx in range(3):
            o += k[dy][dx] * p[dy:dy + a.shape[0], dx:dx + a.shape[1]]
    return o
krb = [[.25, .5, .25], [.5, 1, .5], [.25, .5, .25]]; kg = [[0, .25, 0], [.25, 1, .25], [0, .25, 0]]
rgb = np.stack([conv(R, krb), conv(G, kg), conv(B, krb)], -1)
m = rgb.reshape(-1, 3).mean(0); rgb *= m[1] / m                       # gray-world white balance
rgb /= np.percentile(rgb, 99.5)                                       # exposure normalise
rgb = np.clip(rgb, 0, 1) ** (1 / 2.2)
img = Image.fromarray((rgb * 255).astype(np.uint8)).rotate(90, expand=True)   # sensor mounted at 270
img.save(out); print(out, img.size, "WB gains", np.round(m[1] / m, 2))
