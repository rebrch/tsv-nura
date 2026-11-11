#!/bin/bash
# Re-create the stock Android device tree from a stock boot image (the TSV's DTB has board-id 0x1010520,
# model "APQ8053 Lite DragonBoard V2.0"). Sources for boot.img, either:
#   - image/boot.img in the stock firmware package CD-18781Y.200628.084.zip (see flash/firehose/SOURCE.md), or
#   - your own unit's stock `boot` partition: `edl r boot boot.img` BEFORE flashing (afterwards `boot` holds lk2nd),
#     or carve it out of backup/emmc-full.bin using the offsets in backup/partitions.txt.
# Usage: camera/vendor/dt/extract-stock-dtb.sh path/to/boot.img      (needs dtc)
set -euo pipefail
IMG="${1:?usage: $0 boot.img}"; OUT="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -I - "$IMG" "$T" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(); n = i = 0
while (i := d.find(b'\xd0\x0d\xfe\xed', i)) >= 0:
    size = struct.unpack('>I', d[i + 4:i + 8])[0]
    if 1000 < size < 3_000_000:
        open(f'{sys.argv[2]}/{n}.dtb', 'wb').write(d[i:i + size]); n += 1
    i += 4
PY
for f in "$T"/*.dtb; do
  dtc -q -I dtb -O dts "$f" -o "$f.dts" 2>/dev/null || continue
  if grep -q 'qcom,board-id = <0x1010520 0x00>' "$f.dts"; then
    cp "$f" "$OUT/apq8053-lite-dragonboard-v2-tsv-stock.dtb"
    dtc -q -I dtb -O dts "$f" -o "$OUT/apq8053-lite-dragonboard-v2-tsv-stock.dts"
    echo "wrote $OUT/apq8053-lite-dragonboard-v2-tsv-stock.{dtb,dts}"; exit 0
  fi
done
echo "no TSV DTB (board-id 0x1010520) found in $IMG" >&2; exit 1
