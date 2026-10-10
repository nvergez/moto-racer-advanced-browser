#!/usr/bin/env python3
"""Tile harness screenshots into one labeled PNG for quick review.

usage: contact_sheet.py OUT.png IMG_OR_GLOB [...] [--cols N] [--scale S] [--frames A-B] [--every N]
Arguments may be glob patterns (quoted so the shell leaves them alone); they are
expanded and sorted here. --frames/--every filter on the frame number in the
file name (fNNNNNN...).
Each tile gets a label: the digits found in its file name (e.g. f000600 -> 600),
drawn with a built-in 3x5 digit font. Stdlib only.
OUT.png is checked by outpath.py: a relative path resolves under analysis-out/
($MRA_OUT), and a path git would track is refused. Input paths are relative to
the current directory.
"""
import argparse
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from outpath import out_file  # noqa: E402
from pngutil import read_png, write_png  # noqa: E402

FONT = {
    "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
    "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
    "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
    "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
    "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
    "_": ["000", "000", "000", "000", "111"],
}


def label_of(path):
    """Frame number from the file name, else from the parent directory (dump dirs)."""
    for part in (os.path.basename(path), os.path.basename(os.path.dirname(path))):
        m = re.search(r"f0*(\d+)", part)
        if m:
            return m.group(1)
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("images", nargs="+")
    ap.add_argument("--cols", type=int, default=5)
    ap.add_argument("--scale", type=int, default=1, help="integer upscale per tile")
    ap.add_argument("--frames", help="keep frames A-B (inclusive)")
    ap.add_argument("--every", type=int, default=0, help="keep frames divisible by N")
    a = ap.parse_args()
    out = out_file(a.out)
    paths = []
    for pat in a.images:
        hits = sorted(glob.glob(pat)) if any(c in pat for c in "*?[") else [pat]
        paths += hits
    lo, hi = (0, 1 << 31)
    if a.frames:
        lo, hi = (int(x) for x in a.frames.split("-"))
    kept = []
    for p in paths:
        lab = label_of(p)
        f = int(lab) if lab else None
        if f is not None and not (lo <= f <= hi):
            continue
        if f is not None and a.every and f % a.every:
            continue
        kept.append(p)
    if not kept:
        sys.exit("no images matched")
    tiles = [(p, read_png(p)) for p in kept]
    tw = max(t[1][0] for t in tiles) * a.scale
    th = max(t[1][1] for t in tiles) * a.scale
    pad, lab = 4, 14
    cols = min(a.cols, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    W = cols * (tw + pad) + pad
    H = rows * (th + lab + pad) + pad
    img = bytearray([40] * (W * H * 3))

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            img[(y * W + x) * 3:(y * W + x) * 3 + 3] = bytes(c)

    for i, (path, (w, h, rgb)) in enumerate(tiles):
        cx = pad + (i % cols) * (tw + pad)
        cy = pad + (i // cols) * (th + lab + pad)
        text = label_of(path)
        for k, ch in enumerate(text):
            glyph = FONT.get(ch)
            if not glyph:
                continue
            for gy, row in enumerate(glyph):
                for gx, bit in enumerate(row):
                    if bit == "1":
                        for dy in range(2):
                            for dx in range(2):
                                put(cx + k * 8 + gx * 2 + dx, cy + 1 + gy * 2 + dy, (255, 255, 0))
        oy = cy + lab
        for y in range(h * a.scale):
            sy = y // a.scale
            for x in range(w * a.scale):
                sx = x // a.scale
                s = (sy * w + sx) * 3
                d = ((oy + y) * W + cx + x) * 3
                img[d:d + 3] = rgb[s:s + 3]
    write_png(out, W, H, img)
    print("wrote %s (%d tiles, %dx%d)" % (out, len(tiles), W, H))


if __name__ == "__main__":
    main()
