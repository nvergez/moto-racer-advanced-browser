#!/usr/bin/env python3
"""Capture files: join two engines' records, diff line records, read a console log.

Stdlib only; run with python3 -I. The file format is in README.md next to
this script. This is the interim comparison P2-03 needs (a join on the frame
column); the comparator with allowlists and tolerances is P2-09's.

usage: capture.py COMMAND ...

  join A B [--frames LIST] [--columns C,...]
      Join two per-frame capture files (capture.tsv) on the frame column and
      report, per column present in both, how many frames are equal and which
      differ. The engine-specific columns (cycles, bridge_insns) are left out
      unless --columns names them. Exit 1 if a compared column differs.
  lines A B [--frames LIST] [--max N]
      Compare two full line-record files (capture.lines.tsv): per frame, the
      lines and the columns that differ, with the first N lines' values
      (default 3). Exit 1 if a line differs.
  extract LOG
      Print the capture records in a console log, where each line is
      prefixed "[capture] " (GBARECOMP_CAPTURE=-), as the TSV the file sink
      writes. Exit 1 if a record line is 2,000 characters or longer, the
      browser console's limit (packaging/web/bootstrap.js).

LIST is "1-3000", "4200" or several of those separated by commas.
"""
import argparse
import sys

PREFIX = "[capture] "
ENGINE_SPECIFIC = ("cycles", "bridge_insns")
CONSOLE_LIMIT = 2000


class CaptureError(Exception):
    """Bad input: reported as "capture.py: ..." without a traceback."""


def parse_frames(text):
    ranges = []
    for tok in text.split(","):
        tok = tok.strip()
        if not tok:
            continue
        try:
            if "-" in tok:
                a, b = tok.split("-", 1)
                lo, hi = int(a, 0), int(b, 0)
            else:
                lo = hi = int(tok, 0)
        except ValueError:
            raise CaptureError("bad frame list %r" % text) from None
        if lo > hi:
            raise CaptureError("bad frame range %r" % tok)
        ranges.append((lo, hi))
    if not ranges:
        raise CaptureError("empty frame list")
    return ranges


def in_frames(ranges, f):
    return ranges is None or any(lo <= f <= hi for lo, hi in ranges)


def compress(frames, limit=20):
    """[1,2,3,7] -> "1-3,7"; at most `limit` ranges, then "... (N more)"."""
    out = []
    for f in frames:
        if out and f == out[-1][1] + 1:
            out[-1][1] = f
        else:
            out.append([f, f])
    text = ",".join(str(a) if a == b else "%d-%d" % (a, b) for a, b in out[:limit])
    if len(out) > limit:
        text += ",... (%d more ranges)" % (len(out) - limit)
    return text


def read_table(path, keys):
    """Header and {key tuple: row list}; keys are the leading integer columns."""
    try:
        with open(path, encoding="utf-8") as f:
            header = f.readline().rstrip("\r\n").split("\t")
            if header[:len(keys)] != list(keys):
                raise CaptureError("%s: header does not start with %s" % (path, "\\t".join(keys)))
            rows = {}
            for n, line in enumerate(f, 2):
                parts = line.rstrip("\r\n").split("\t")
                if len(parts) != len(header):
                    raise CaptureError("%s:%d: %d columns, header has %d" % (path, n, len(parts), len(header)))
                try:
                    key = tuple(int(parts[i]) for i in range(len(keys)))
                except ValueError:
                    raise CaptureError("%s:%d: %s is not a number" % (path, n, "/".join(keys))) from None
                if key in rows:
                    raise CaptureError("%s:%d: %s %s appears twice" % (path, n, "/".join(keys), key))
                rows[key] = parts
    except OSError as e:
        raise CaptureError("%s: %s" % (path, e.strerror or e)) from None
    except UnicodeDecodeError as e:
        raise CaptureError("%s: not a text file (%s)" % (path, e.reason)) from None
    if not rows:
        raise CaptureError("%s: no records" % path)
    return header, rows


def describe(name, rows):
    frames = sorted({k[0] for k in rows})
    return "%s %d (%d-%d)" % (name, len(frames), frames[0], frames[-1])


def cmd_join(args, out):
    frames = parse_frames(args.frames) if args.frames else None
    ha, a = read_table(args.a, ("frame",))
    hb, b = read_table(args.b, ("frame",))
    common = sorted(k for k in set(a) & set(b) if in_frames(frames, k[0]))
    if not common:
        raise CaptureError("no common frames%s" % (" in " + args.frames if args.frames else ""))
    if args.columns:
        cols = [c.strip() for c in args.columns.split(",") if c.strip()]
        for c in cols:
            if c not in ha or c not in hb:
                raise CaptureError("column %s is not in both files" % c)
    else:
        cols = [c for c in ha if c != "frame" and c in hb and c not in ENGINE_SPECIFIC]
    print("frames: %s, %s, compared %d (%d-%d)" % (
        describe("A", a), describe("B", b), len(common), common[0][0], common[-1][0]), file=out)
    only = [c for c in ha if c not in hb] + [c for c in hb if c not in ha]
    if only:
        print("columns in one file only: %s" % ", ".join(only), file=out)
    ia = {c: ha.index(c) for c in cols}
    ib = {c: hb.index(c) for c in cols}
    failed = False
    width = max(len(c) for c in cols)
    for c in cols:
        diff = [k[0] for k in common if a[k][ia[c]] != b[k][ib[c]]]
        failed = failed or bool(diff)
        print("%-*s  equal %6d  differ %6d  %s" % (width, c, len(common) - len(diff), len(diff), compress(diff)),
              file=out)
    return 1 if failed else 0


def cmd_lines(args, out):
    frames = parse_frames(args.frames) if args.frames else None
    ha, a = read_table(args.a, ("frame", "line"))
    hb, b = read_table(args.b, ("frame", "line"))
    if ha != hb:
        raise CaptureError("the two files have different columns")
    keys = sorted(k for k in set(a) & set(b) if in_frames(frames, k[0]))
    only = sorted(k for k in set(a) ^ set(b) if in_frames(frames, k[0]))
    by_frame = {}
    for k in keys:
        if a[k] != b[k]:
            d = [(ha[i], a[k][i], b[k][i]) for i in range(2, len(ha)) if a[k][i] != b[k][i]]
            by_frame.setdefault(k[0], []).append((k[1], d))
    print("line records: %d compared, %d in one file only%s, %d differ in %d frames" % (
        len(keys), len(only), " (first: frame %d line %d)" % only[0] if only else "",
        sum(len(v) for v in by_frame.values()), len(by_frame)), file=out)
    for f in sorted(by_frame):
        v = by_frame[f]
        cols = sorted({c for _, d in v for c, _, _ in d}, key=ha.index)
        print("frame %d: %d lines (%s), columns %s" % (f, len(v), compress([l for l, _ in v]), " ".join(cols)),
              file=out)
        for line, d in v[:args.max]:
            print("  line %d: %s" % (line, " ".join("%s %s/%s" % x for x in d)), file=out)
    return 1 if by_frame or only else 0


def cmd_extract(args, out):
    status = 0
    try:
        with open(args.log, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                if not line.startswith(PREFIX):
                    continue
                record = line.rstrip("\r\n")
                if len(record) >= CONSOLE_LIMIT:
                    print("capture.py: %s:%d: %d characters, the console keeps %d" % (
                        args.log, n, len(record), CONSOLE_LIMIT), file=sys.stderr)
                    status = 1
                out.write(record[len(PREFIX):] + "\n")
    except OSError as e:
        raise CaptureError("%s: %s" % (args.log, e.strerror or e)) from None
    return status


def main(argv=None, out=None):
    out = out or sys.stdout
    p = argparse.ArgumentParser(prog="capture.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("join")
    j.add_argument("a")
    j.add_argument("b")
    j.add_argument("--frames")
    j.add_argument("--columns")
    li = sub.add_parser("lines")
    li.add_argument("a")
    li.add_argument("b")
    li.add_argument("--frames")
    li.add_argument("--max", type=int, default=3)
    e = sub.add_parser("extract")
    e.add_argument("log")
    args = p.parse_args(argv)
    try:
        return {"join": cmd_join, "lines": cmd_lines, "extract": cmd_extract}[args.cmd](args, out)
    except CaptureError as err:
        print("capture.py: %s" % err, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
