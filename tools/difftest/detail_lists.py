#!/usr/bin/env python3
"""Capture lists for the detail pass of scripts/replay-test.sh.

Stdlib only; run with python3 -I.

usage: detail_lists.py DETAIL.tsv --cap N [--max-ranges 32]

DETAIL.tsv is compare.py --detail-out: "REF_FRAME<TAB>TEST_FRAME<TAB>..."
per line. For each side (REF, then TEST) this prints one line

  LIST LAST CAPTURED LEFT

LIST is the frame list for GBARECOMP_CAPTURE_LINES/_RAW and the harness's
--capture-lines/--capture-raw ("A-B,C-D,..."), LAST its last frame (how far
the side runs), CAPTURED the number of frames the list holds and LEFT the
number of requested frames it leaves out.

A capture list holds at most --max-ranges ranges (both engines accept 32).
Ranges are merged across the smallest gaps first, which captures frames
nobody asked for, but only while the list holds at most --cap frames: past
that, the ranges after the last one that fits are left out (LEFT), rather
than writing an unbounded number of frames (each costs about 116 KB per
side). Exit 2 on bad input.
"""
import argparse
import sys


def capture_list(frames, cap, max_ranges=32):
    """Ranges [(a, b)] to capture for the requested frames, and how many of
    them are left out. At most max_ranges ranges and at most `cap` frames
    (cap >= the number of distinct frames requested)."""
    want = sorted(set(frames))
    rs = []
    for f in want:
        if rs and f == rs[-1][1] + 1:
            rs[-1][1] = f
        else:
            rs.append([f, f])
    total = len(want)
    while len(rs) > max_ranges:
        i = min(range(len(rs) - 1), key=lambda k: rs[k + 1][0] - rs[k][1])
        gap = rs[i + 1][0] - rs[i][1] - 1
        if total + gap > cap:
            break  # every other gap is at least as wide
        total += gap
        rs[i][1] = rs[i + 1][1]
        del rs[i + 1]
    rs = rs[:max_ranges]
    left = sum(1 for f in want if f > rs[-1][1]) if rs else 0
    return [(a, b) for a, b in rs], left


def main(argv=None, out=None):
    out = out or sys.stdout
    ap = argparse.ArgumentParser(prog="detail_lists.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("detail")
    ap.add_argument("--cap", type=int, required=True)
    ap.add_argument("--max-ranges", type=int, default=32)
    args = ap.parse_args(argv)
    cols = ([], [])
    try:
        with open(args.detail) as fh:
            for n, line in enumerate(fh, 1):
                parts = line.rstrip("\n").split("\t")
                try:
                    a, b = int(parts[0]), int(parts[1])
                except (ValueError, IndexError):
                    print("detail_lists.py: %s:%d: not 'REF_FRAME<TAB>TEST_FRAME'" % (args.detail, n), file=sys.stderr)
                    return 2
                cols[0].append(a)
                cols[1].append(b)
    except OSError as e:
        print("detail_lists.py: %s: %s" % (args.detail, e.strerror or e), file=sys.stderr)
        return 2
    if not cols[0]:
        print("detail_lists.py: %s: no frame" % args.detail, file=sys.stderr)
        return 2
    if args.max_ranges < 1 or args.cap < len(set(cols[0])) or args.cap < len(set(cols[1])):
        print("detail_lists.py: --cap must be at least the number of frames requested, --max-ranges at least 1",
              file=sys.stderr)
        return 2
    for frames in cols:
        rs, left = capture_list(frames, args.cap, args.max_ranges)
        print("%s %d %d %d" % (",".join("%d-%d" % r for r in rs), rs[-1][1],
                               sum(b - a + 1 for a, b in rs), left), file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
