#!/usr/bin/env python3
"""Render VRAM/palette/OAM from a gbaharness dump directory (stdlib only).

usage:
  render_vram.py DUMPDIR bitmap  OUT.png [--mode 3|4|5] [--page 0|1]
  render_vram.py DUMPDIR bg N    OUT.png          # full BG N map, using the dump's BGxCNT/DISPCNT
  render_vram.py DUMPDIR tiles   OUT.png [--base 0x0000] [--bpp 4|8] [--count 512] [--palbank 0] [--obj]
  render_vram.py DUMPDIR palette OUT.png
  render_vram.py DUMPDIR oam                      # decoded OAM entries (TSV on stdout)

DUMPDIR is a gbaharness dumps/fNNNNNN_label directory (vram.bin, palette.bin,
oam.bin, io.bin). BG N is rendered as text or affine depending on the video
mode in DISPCNT (mode 1: BG2 affine; mode 2: BG2/BG3 affine). Palette index 0
is drawn with the backdrop color. Rendering follows GBATEK; it is a viewer,
not an accurate compositor (no windows, blending, mosaic or scroll).

OUT.png is checked by outpath.py: a relative path resolves under analysis-out/
($MRA_OUT), and a path git would track is refused. DUMPDIR is relative to the
current directory.
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from outpath import out_file  # noqa: E402
from pngutil import write_png  # noqa: E402


def rgb(c):
    r, g, b = c & 31, (c >> 5) & 31, (c >> 10) & 31
    return bytes(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)))


class Dump:
    def __init__(self, d):
        self.vram = open(os.path.join(d, "vram.bin"), "rb").read()
        pal = open(os.path.join(d, "palette.bin"), "rb").read()
        self.pal = [struct.unpack_from("<H", pal, i * 2)[0] for i in range(512)]
        self.prgb = [rgb(c) for c in self.pal]
        self.oam = open(os.path.join(d, "oam.bin"), "rb").read()
        io = open(os.path.join(d, "io.bin"), "rb").read()
        self.io16 = lambda off: struct.unpack_from("<H", io, off)[0]

    def tile_pixel(self, base, tile, bpp, x, y):
        if bpp == 4:
            off = base + tile * 32 + y * 4 + (x >> 1)
            if off >= len(self.vram):
                return 0
            v = self.vram[off]
            return (v >> 4) if (x & 1) else (v & 15)
        off = base + tile * 64 + y * 8 + x
        return self.vram[off] if off < len(self.vram) else 0


def cmd_bitmap(dm, a):
    mode = a.mode if a.mode is not None else dm.io16(0) & 7
    page = a.page if a.page is not None else (dm.io16(0) >> 4) & 1
    if mode == 3:
        w, h, out = 240, 160, bytearray()
        for i in range(w * h):
            out += rgb(struct.unpack_from("<H", dm.vram, i * 2)[0])
    elif mode == 4:
        w, h, base, out = 240, 160, 0xA000 * page, bytearray()
        for i in range(w * h):
            out += dm.prgb[dm.vram[base + i]]
    elif mode == 5:
        w, h, base, out = 160, 128, 0xA000 * page, bytearray()
        for i in range(w * h):
            out += rgb(struct.unpack_from("<H", dm.vram, base + i * 2)[0])
    else:
        sys.exit("bitmap needs mode 3/4/5")
    write_png(a.out, w, h, out)
    print("bitmap mode %d page %d -> %s" % (mode, page, a.out))


def cmd_bg(dm, a):
    n = a.n
    cnt = dm.io16(0x8 + 2 * n)
    mode = dm.io16(0) & 7
    char_base = ((cnt >> 2) & 3) * 0x4000
    screen_base = ((cnt >> 8) & 31) * 0x800
    size = cnt >> 14
    affine = (mode == 1 and n == 2) or (mode == 2 and n in (2, 3))
    back = dm.prgb[0]
    if affine:
        dim = 128 << size
        tiles_per_row = dim // 8
        out = bytearray(dim * dim * 3)
        for ty in range(tiles_per_row):
            for tx in range(tiles_per_row):
                t = dm.vram[screen_base + ty * tiles_per_row + tx]
                for y in range(8):
                    row = ((ty * 8 + y) * dim + tx * 8) * 3
                    for x in range(8):
                        p = dm.tile_pixel(char_base, t, 8, x, y)
                        out[row + x * 3:row + x * 3 + 3] = dm.prgb[p] if p else back
        write_png(a.out, dim, dim, out)
        print("BG%d affine %dx%d char_base 0x%X screen_base 0x%X (BG%dCNT=0x%04X) -> %s"
              % (n, dim, dim, char_base, screen_base, n, cnt, a.out))
        return
    w = 512 if size in (1, 3) else 256
    h = 512 if size in (2, 3) else 256
    c256 = (cnt >> 7) & 1
    out = bytearray(w * h * 3)
    for ty in range(h // 8):
        for tx in range(w // 8):
            sb = (tx >> 5) + (ty >> 5) * (w // 256)
            off = screen_base + sb * 0x800 + ((ty & 31) * 32 + (tx & 31)) * 2
            se = struct.unpack_from("<H", dm.vram, off)[0] if off + 1 < len(dm.vram) else 0
            t, hf, vf, pb = se & 0x3FF, (se >> 10) & 1, (se >> 11) & 1, se >> 12
            for y in range(8):
                sy = 7 - y if vf else y
                row = ((ty * 8 + y) * w + tx * 8) * 3
                for x in range(8):
                    sx = 7 - x if hf else x
                    p = dm.tile_pixel(char_base, t, 8 if c256 else 4, sx, sy)
                    col = back if p == 0 else (dm.prgb[p] if c256 else dm.prgb[pb * 16 + p])
                    out[row + x * 3:row + x * 3 + 3] = col
    write_png(a.out, w, h, out)
    print("BG%d text %dx%d %s char_base 0x%X screen_base 0x%X (BG%dCNT=0x%04X) -> %s"
          % (n, w, h, "8bpp" if c256 else "4bpp", char_base, screen_base, n, cnt, a.out))


def cmd_tiles(dm, a):
    per_row = 32
    rows = (a.count + per_row - 1) // per_row
    w, h = per_row * 8, rows * 8
    out = bytearray(w * h * 3)
    pal_off = 256 if a.obj else 0
    for t in range(a.count):
        tx, ty = t % per_row, t // per_row
        for y in range(8):
            for x in range(8):
                p = dm.tile_pixel(a.base, t, a.bpp, x, y)
                idx = pal_off + (p if a.bpp == 8 else a.palbank * 16 + p)
                d = ((ty * 8 + y) * w + tx * 8 + x) * 3
                out[d:d + 3] = dm.prgb[idx] if p else b"\x00\x00\x00"
    write_png(a.out, w, h, out)
    print("%d tiles %dbpp from VRAM 0x%X -> %s" % (a.count, a.bpp, a.base, a.out))


def cmd_palette(dm, a):
    cell = 8
    w, h = 16 * cell, 32 * cell
    out = bytearray(w * h * 3)
    for i in range(512):
        cx, cy = (i % 16) * cell, (i // 16) * cell
        for y in range(cell):
            for x in range(cell):
                d = ((cy + y) * w + cx + x) * 3
                out[d:d + 3] = dm.prgb[i]
    write_png(a.out, w, h, out)
    print("palette (rows 0-15 BG, 16-31 OBJ) -> %s" % a.out)


def cmd_oam(dm, a):
    shapes = {(0, 0): "8x8", (0, 1): "16x16", (0, 2): "32x32", (0, 3): "64x64",
              (1, 0): "16x8", (1, 1): "32x8", (1, 2): "32x16", (1, 3): "64x32",
              (2, 0): "8x16", (2, 1): "8x32", (2, 2): "16x32", (2, 3): "32x64"}
    print("index\tx\ty\tsize\ttile\tpalbank\tprio\taffine\tdouble_or_hidden\thflip\tvflip\tcolors256\tmode")
    for i in range(128):
        a0, a1, a2 = struct.unpack_from("<HHH", dm.oam, i * 8)
        aff = (a0 >> 8) & 1
        dbl_or_hide = (a0 >> 9) & 1
        if not aff and dbl_or_hide:
            continue  # hidden
        y, x = a0 & 0xFF, a1 & 0x1FF
        if x >= 256:
            x -= 512
        shape, size = a0 >> 14, a1 >> 14
        print("%d\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%d\t%s\t%s\t%d\t%d" % (
            i, x, y, shapes.get((shape, size), "?"), a2 & 0x3FF, a2 >> 12, (a2 >> 10) & 3,
            ("group%d" % ((a1 >> 9) & 31)) if aff else "-", dbl_or_hide,
            "-" if aff else (a1 >> 12) & 1, "-" if aff else (a1 >> 13) & 1, (a0 >> 13) & 1, (a0 >> 10) & 3))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dump")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("bitmap")
    p.add_argument("out")
    p.add_argument("--mode", type=int)
    p.add_argument("--page", type=int)
    p = sub.add_parser("bg")
    p.add_argument("n", type=int)
    p.add_argument("out")
    p = sub.add_parser("tiles")
    p.add_argument("out")
    p.add_argument("--base", type=lambda s: int(s, 0), default=0)
    p.add_argument("--bpp", type=int, default=4)
    p.add_argument("--count", type=int, default=512)
    p.add_argument("--palbank", type=int, default=0)
    p.add_argument("--obj", action="store_true", help="use the OBJ palette")
    p = sub.add_parser("palette")
    p.add_argument("out")
    sub.add_parser("oam")
    a = ap.parse_args()
    if getattr(a, "out", None) is not None:
        a.out = out_file(a.out)
    dm = Dump(a.dump)
    {"bitmap": cmd_bitmap, "bg": cmd_bg, "tiles": cmd_tiles, "palette": cmd_palette, "oam": cmd_oam}[a.cmd](dm, a)


if __name__ == "__main__":
    main()
