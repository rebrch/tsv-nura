#!/usr/bin/env python3
"""Inspect a Qualcomm mm-camera sensor library (libmmcamera_<sensor>.so) from the TSV's vendor partition.

This is how the S5KC505A Linux driver's register tables (camera/driver/s5kc505a_regs.h) were obtained,
generalised so the same can be done for the other two sensors a ThinkSmart View may ship with
(OmniVision OV5693, Samsung S5K4E8).

  sensor-lib-dump.py LIB                      identity block + every register table found (offset, size, decoded mode)
  sensor-lib-dump.py LIB --dump OFFSET        print one table
  sensor-lib-dump.py LIB --header NAME=OFFSET [NAME=OFFSET ...]
                                              emit a C header of `struct cci_reg_sequence` tables for a Linux driver

Data layout (32-bit ARM, little endian, Qualcomm mm-camera "sensor_lib_t"):
  * identity block at the sensor name string: name[32], u32 slave_addr (8-bit form), u32 i2c_freq_mode,
    u32 addr_type, u32 data_type, u16 id_reg, u16 chip_id
  * register tables: arrays of {u16 reg_addr, u16 reg_data, u32 delay_ms}, terminated by an all-zero entry.
Which table is the global init and which are the per-resolution modes has to be decided by reading the decoded
output sizes (see README.md). For the S5KC505A: global init @0x6e20, modes @0x3eee4 0x42ef4 0x46f04 0x4af14 0x4ef24.
"""
import struct
import sys
from pathlib import Path

ENTRY = struct.Struct("<HHI")


def identity(d: bytes, name: str):
    i = d.find(name.encode() + b"\0")
    if i < 0:
        return None
    slave, freq, addr_t, data_t = struct.unpack_from("<IIII", d, i + 32)
    id_reg, chip_id = struct.unpack_from("<HH", d, i + 48)
    return dict(offset=i, slave_8bit=slave, slave_7bit=slave >> 1, i2c_freq_mode=freq,
                addr_type=addr_t, data_type=data_t, id_reg=id_reg, chip_id=chip_id)


def table(d: bytes, off: int):
    out = []
    while off + 8 <= len(d):
        a, v, dl = ENTRY.unpack_from(d, off)
        if a == 0 and v == 0 and dl == 0:
            return out
        out.append((a, v, dl))
        off += 8
    return out


def scan(d: bytes, min_len: int = 6):
    tables, i = [], 0
    while i + 8 <= len(d):
        j, n = i, 0
        while j + 8 <= len(d):
            a, v, dl = ENTRY.unpack_from(d, j)
            if a == 0 and v == 0 and dl == 0:
                break
            if not (0 < a < 0x8000 and dl < 1000):
                n = 0
                break
            j += 8
            n += 1
        if n >= min_len and j + 8 <= len(d) and d[j:j + 8] == b"\0" * 8:
            tables.append((i, n))
            i = j + 8
        else:
            i += 4
    return tables


def decode(t):
    r = {a: v for a, v, _ in t}
    info = []
    def w16(hi, lo):
        return (r[hi] << 8 | r[lo]) if hi in r and lo in r else None
    for label, (wh, wl, hh, hl) in (("SMIA", (0x034C, 0x034D, 0x034E, 0x034F)), ("OmniVision", (0x3808, 0x3809, 0x380A, 0x380B))):
        w, h = w16(wh, wl), w16(hh, hl)
        if w and h:
            info.append(f"{label} output {w}x{h}")
    if 0x0114 in r:
        info.append(f"lanes={r[0x0114] + 1}")
    if 0x0820 in r and 0x0821 in r:
        info.append(f"lane-Mbps={r[0x0820] << 8 | r[0x0821]}")
    if 0x0100 in r:
        info.append(f"mode_select={r[0x0100]}")
    if any(v > 0xFF for _, v, _ in t):
        info.append("16-bit data")
    return ", ".join(info)


def emit_header(lib: Path, pairs):
    d = lib.read_bytes()
    print("/* SPDX-License-Identifier: GPL-2.0 */")
    print(f"/* Register tables extracted from the vendor {lib.name} (ThinkSmart View). */\n")
    for name, off in pairs:
        t = table(d, off)
        width = "CCI_REG16" if any(v > 0xFF for _, v, _ in t) else "CCI_REG8"
        print(f"static const struct cci_reg_sequence {name}[] = {{")
        for a, v, dl in t:
            val = f"0x{v:04x}" if width == "CCI_REG16" else f"0x{v:02x}"
            print(f"\t{{ {width}(0x{a:04x}), {val} }}," + (f" /* vendor: delay {dl} ms after */" if dl else ""))
        print("};\n")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    lib = Path(sys.argv[1])
    d = lib.read_bytes()
    args = sys.argv[2:]
    if args[:1] == ["--dump"]:
        for a, v, dl in table(d, int(args[1], 0)):
            print(f"0x{a:04x} = 0x{v:02x}" + (f"  (+{dl} ms)" if dl else ""))
        return
    if args[:1] == ["--header"]:
        emit_header(lib, [(p.split("=")[0], int(p.split("=")[1], 0)) for p in args[1:]])
        return
    name = lib.stem.removeprefix("libmmcamera_")
    ident = identity(d, name)
    if ident:
        print(f"{name}: I2C 7-bit 0x{ident['slave_7bit']:02x} (8-bit 0x{ident['slave_8bit']:02x}), "
              f"chip id 0x{ident['chip_id']:04x} at reg 0x{ident['id_reg']:04x}, addr_type={ident['addr_type']}, "
              f"data_type={ident['data_type']}, i2c_freq_mode={ident['i2c_freq_mode']}")
    else:
        print(f"{name}: identity block not found")
    print("register tables (offset, entries, decoded):")
    for off, n in scan(d):
        print(f"  0x{off:05x}  {n:4d}  {decode(table(d, off))}")


if __name__ == "__main__":
    main()
