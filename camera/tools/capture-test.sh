#!/bin/sh
# Load the S5KC505A driver, wire csiphy0 -> csid0 -> ispif0 -> vfe0_rdi0 and grab raw frames.
# Usage (root): capture-test.sh [WxH] [count]
SIZE=${1:-640x490}; N=${2:-10}
lsmod | grep -q '^s5kc505a' || { for m in v4l2-cci v4l2-fwnode v4l2-async videodev mc; do modprobe $m; done; insmod /usr/local/lib/tsv-camera/s5kc505a.ko; sleep 1; }
M="media-ctl -d /dev/media0"
S=$($M -p | grep -o 's5kc505a [0-9-]*' | head -1)
$M -r
$M -l '"msm_csiphy0":1->"msm_csid0":0[1],"msm_csid0":1->"msm_ispif0":0[1],"msm_ispif0":1->"msm_vfe0_rdi0":0[1]'
F="SGRBG10_1X10/$SIZE field:none"
for e in "'$S':0" '"msm_csiphy0":0' '"msm_csid0":0' '"msm_ispif0":0' '"msm_vfe0_rdi0":0'; do $M -V "$e[fmt:$F]" >/dev/null || echo "fmt fail $e"; done
V=$($M -e msm_vfe0_video0)
W=${SIZE%x*}; H=${SIZE#*x}
rm -f /tmp/raw.bin
timeout 20 v4l2-ctl -d $V --set-fmt-video=width=$W,height=$H,pixelformat=pgAA --stream-mmap --stream-count=$N --stream-skip=3 --stream-to=/tmp/raw.bin 2>&1 | tail -2
ls -l /tmp/raw.bin 2>/dev/null
