#!/usr/bin/env python3
"""Compare two engines' VBlank-start captures: the two comparisons of ADR 0001.

Stdlib only; run with python3 -I (Python 3.11 or newer, for tomllib). The
capture format is tools/capture/README.md; how the comparisons are defined,
and the allowlists, are in tools/difftest/README.md.

usage: compare.py REF TEST --against interp|mgba [options]

REF and TEST are per-frame capture files (capture.tsv) of the same route:
REF the reference, TEST the gbarecomp run under test. Frames are harness
frames; a REF frame f is compared with TEST frame f, or with the frame the
frame map gives.

  --against interp   comparison 1, recompilation correctness: TEST is the
                     recompiled build, REF gbarecomp's interpreter with the
                     BIOS interpreted too (MRA_INTERP_BIOS=1). Gated: the
                     frame CRC (fb) and every RAM region hash (ram_*) but the
                     regions comparison1.toml excludes, exact on every frame.
                     No allowlist.
  --against mgba     comparison 2, emulation fidelity: REF is the mGBA
                     harness. Gated: layer 1 (the per-line state, the lines
                     CRC and, in detail, the line records), layer 2 (pixels
                     at 5-bit precision, from raw frames: exact on lines with
                     no color effect, at most one step per channel on lines
                     with one) for every frame whose fb CRC differs, and every
                     RAM region hash; each difference fails unless an
                     allowlist entry covers it.
  Other shared columns (DISPCNT, mem_*, FIFO, io_writes, halt_writes) are
  reported, not gated; cycles is reported as the range of TEST - REF.

options:
  --frames LIST        REF frames to compare (default: every frame of REF)
  --frame-map SPEC     pair REF frame f with another TEST frame (below)
  --allowlist FILE     comparison 2 allowlist (tools/difftest/allowlists/)
  --route NAME         the route the captures are of: the allowlist must be
                       that route's
  --exclusions FILE    comparison 1 exclusions (default: comparison1.toml
                       next to this script)
  --ref-lines F, --test-lines F
                       full line records (STEM.lines.tsv) of frames to detail
  --ref-raw D, --test-raw D
                       raw frames (STEM.raw/) of frames to detail
  --detail-out FILE    write the frames that need detail (below)
  --max-detail N       at most N frames in --detail-out (default 1200)
  --json FILE          write the summary as JSON
  --frame-report FILE  write one row per frame that differs in a gated check,
                       with the detail (lines, columns, pixels) and how it
                       was accounted for (TSV)
  --list N             frame ranges listed per check (default 20)

LIST is "1-3290", "4200" or several of those separated by commas, ';' or
spaces. A frame map SPEC is one or more entries separated by commas:
"A-B:+K" pairs REF frames A-B with TEST frames f+K (K may be negative);
"A-B:~N" searches TEST frames f-N to f+N for each REF frame and takes the
one with the most equal gated columns (ties: the smallest |offset|, then the
lower frame), and prints the offsets it chose, as a fixed map. Frames outside
every entry are paired with the same frame (+0). A map is for runs known not
to be in lockstep (docs/phase2-plan.md, P2-09; phase2-race-lockstep.md); exit
gates use none unless the owner accepts one.

The per-frame pass streams both files and keeps counts, the frames that
differ and the first divergence. Frames whose CRCs differ need detail: line
records for a lines difference, raw frames (and line records, which say which
lines have a color effect) for an fb difference. --detail-out FILE lists
them, one "REF_FRAME<TAB>TEST_FRAME" per line, frames no allowlist entry
covers first, at most --max-detail; scripts/replay-test.sh re-runs both
engines with those records and calls this script again with them. A frame
whose fb differs and has no raw frames is "undetermined" for layer 2 and
fails unless the allowlist covers it. Each raw frame's CRC-32 must equal
the capture's fb for that frame, or the raw frames are refused (exit 2):
they are not from the captured runs. In comparison 1 an fb difference
always fails; the raw frames only locate it.

The report counts, for each allowlist entry and check, the compared frames
the entry covers (where it is the first entry that covers the check) and
those it hits. An entry that covers frames it does not hit is marked PARTLY
USED, with its unused frames listed: a range wider than the frames that
differ hides what a later change breaks there.

Exit 0 when every gated check passes and no frame is missing, 1 otherwise,
2 on bad input.
"""
import argparse
import array
import bisect
import json
import os
import re
import sys
import zlib

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("compare.py needs Python 3.11 or newer (tomllib); this is %s" % sys.version.split()[0])

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_EXCLUSIONS = os.path.join(HERE, "comparison1.toml")

WIDTH, HEIGHT = 240, 160
RAW_SIZE = WIDTH * HEIGHT * 2
ENGINE_SPECIFIC = ("cycles", "bridge_insns")
REGION_RE = re.compile(r"^[A-Za-z0-9_]{1,16}$")
CHECK_RE = re.compile(r"^(layer1|layer2|ram:(\*|[A-Za-z0-9_]{1,16}))$")


class CompareError(Exception):
    """Bad input: reported as "compare.py: ..." without a traceback."""


# ---------------------------------------------------------------- frame lists

def parse_frame_list(text, what="frame list"):
    """Sorted, merged [(lo, hi)]."""
    ranges = []
    for tok in re.split(r"[,;\s]+", text.strip()):
        if not tok:
            continue
        m = re.match(r"^(\d+)(?:-(\d+))?$", tok)
        if not m:
            raise CompareError("bad %s %r" % (what, text))
        lo = int(m.group(1))
        hi = int(m.group(2)) if m.group(2) else lo
        if lo > hi or lo < 1:
            raise CompareError("bad frame range %r in %s" % (tok, what))
        ranges.append((lo, hi))
    if not ranges:
        raise CompareError("empty %s" % what)
    return merge_ranges(sorted(ranges))


def merge_ranges(ranges):
    out = []
    for lo, hi in ranges:
        if out and lo <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], hi)
        else:
            out.append([lo, hi])
    return [(lo, hi) for lo, hi in out]


def to_ranges(frames):
    """Sorted frames -> [(lo, hi)]."""
    out = []
    for f in frames:
        if out and f == out[-1][1] + 1:
            out[-1][1] = f
        else:
            out.append([f, f])
    return [(lo, hi) for lo, hi in out]


def format_ranges(ranges, limit=None):
    """[(1, 3), (7, 7)] -> "1-3,7"; at most `limit` ranges, then "... (N more ranges)"."""
    shown = ranges if limit is None else ranges[:limit]
    text = ",".join(str(a) if a == b else "%d-%d" % (a, b) for a, b in shown)
    if limit is not None and len(ranges) > limit:
        text += ",... (%d more ranges)" % (len(ranges) - limit)
    return text


def in_ranges(ranges, f):
    i = bisect.bisect_right(ranges, (f, float("inf"))) - 1
    return i >= 0 and ranges[i][0] <= f <= ranges[i][1]


# ---------------------------------------------------------------- frame map

class FrameMap:
    """REF frame -> TEST frame: fixed offsets and searches per frame range."""

    def __init__(self, spec=None):
        self.spec = spec or ""
        self.entries = []  # (lo, hi, kind, value), kind "fixed" or "search"
        if not spec:
            return
        for tok in spec.split(","):
            tok = tok.strip()
            m = re.match(r"^(\d+)(?:-(\d+))?:(?:([+-]?\d+)|~(\d+))$", tok)
            if not m:
                raise CompareError("bad frame map entry %r (A-B:+K or A-B:~N)" % tok)
            lo = int(m.group(1))
            hi = int(m.group(2)) if m.group(2) else lo
            if lo < 1 or lo > hi:
                raise CompareError("bad frame range in frame map entry %r" % tok)
            if m.group(3) is not None:
                self.entries.append((lo, hi, "fixed", int(m.group(3))))
            else:
                n = int(m.group(4))
                if n < 1 or n > 60:
                    raise CompareError("frame map search width must be 1 to 60: %r" % tok)
                self.entries.append((lo, hi, "search", n))
        self.entries.sort()
        for a, b in zip(self.entries, self.entries[1:]):
            if b[0] <= a[1]:
                raise CompareError("frame map entries overlap: %d-%d and %d-%d" % (a[0], a[1], b[0], b[1]))

    def rule(self, f):
        for lo, hi, kind, value in self.entries:
            if lo <= f <= hi:
                return kind, value
        return "fixed", 0

    def reach(self):
        """Largest |offset| any entry can give."""
        return max([abs(v) for _, _, _, v in self.entries] + [0])

    def lowest(self):
        """Most negative offset any entry can give (<= 0)."""
        return min([v if k == "fixed" else -v for _, _, k, v in self.entries] + [0])


# ---------------------------------------------------------------- captures

class Capture:
    """A per-frame capture file read in frame order."""

    def __init__(self, path):
        self.path = path
        try:
            self.f = open(path, encoding="utf-8", newline="")
        except OSError as e:
            raise CompareError("%s: %s" % (path, e.strerror or e)) from None
        self.header = self.f.readline().rstrip("\r\n").split("\t")
        if not self.header or self.header[0] != "frame":
            raise CompareError("%s: not a capture file (the header does not start with frame)" % path)
        if len(set(self.header)) != len(self.header):
            raise CompareError("%s: a column appears twice in the header" % path)
        self.index = {c: i for i, c in enumerate(self.header)}
        self.line_no = 1
        self.last = 0
        self.frames = []

    def close(self):
        self.f.close()

    def rows(self):
        for line in self.f:
            self.line_no += 1
            parts = line.rstrip("\r\n").split("\t")
            if len(parts) != len(self.header):
                raise CompareError("%s:%d: %d columns, header has %d" % (
                    self.path, self.line_no, len(parts), len(self.header)))
            try:
                f = int(parts[0])
            except ValueError:
                raise CompareError("%s:%d: frame is not a number" % (self.path, self.line_no)) from None
            if f <= self.last:
                raise CompareError("%s:%d: frame %d after frame %d (frames must increase)" % (
                    self.path, self.line_no, f, self.last))
            self.last = f
            self.frames.append(f)
            yield f, parts
        self.f.close()


class Window:
    """TEST rows within reach of the REF frame being compared."""

    def __init__(self, capture, reach):
        self.it = capture.rows()
        self.rows = {}
        self.reach = reach
        self.done = False
        self.high = 0

    def fill(self, upto):
        while not self.done and self.high < upto:
            try:
                f, parts = next(self.it)
            except StopIteration:
                self.done = True
                break
            self.rows[f] = parts
            self.high = f

    def get(self, f):
        return self.rows.get(f)

    def drop_below(self, f):
        for k in [k for k in self.rows if k < f]:
            del self.rows[k]


# ---------------------------------------------------------------- lists

def load_toml(path):
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except OSError as e:
        raise CompareError("%s: %s" % (path, e.strerror or e)) from None
    except tomllib.TOMLDecodeError as e:
        raise CompareError("%s: %s" % (path, e)) from None


def need_text(where, spec, key, required=True):
    value = spec.get(key, "")
    if not isinstance(value, str) or (required and not value.strip()):
        raise CompareError("%s: %s must be a non-empty string" % (where, key))
    return value


class Exclusions:
    """comparison1.toml: RAM regions comparison 1 leaves out, each with its cause."""

    def __init__(self, path):
        self.path = path
        self.regions = {}
        if path is None:
            return
        data = load_toml(path)
        if data.get("schema") != 1:
            raise CompareError("%s: schema = 1 expected" % path)
        unknown = set(data) - {"schema", "exclude"}
        if unknown:
            raise CompareError("%s: unknown keys %s" % (path, sorted(unknown)))
        entries = data.get("exclude", [])
        if not isinstance(entries, list):
            raise CompareError("%s: exclude must be an array of tables" % path)
        for i, e in enumerate(entries, 1):
            where = "%s: exclude %d" % (path, i)
            if not isinstance(e, dict):
                raise CompareError("%s: must be a table" % where)
            unknown = set(e) - {"region", "cause", "ref"}
            if unknown:
                raise CompareError("%s: unknown keys %s" % (where, sorted(unknown)))
            region = need_text(where, e, "region")
            if not REGION_RE.match(region):
                raise CompareError("%s: region %r is not a region name of the spec" % (where, region))
            need_text(where, e, "cause")
            need_text(where, e, "ref")
            if region in self.regions:
                raise CompareError("%s: region %s is listed twice" % (where, region))
            self.regions[region] = e


class Allowlist:
    """A route's comparison 2 allowlist (tools/difftest/README.md)."""

    def __init__(self, path):
        self.path = path
        self.entries = []
        if path is None:
            return
        data = load_toml(path)
        if data.get("schema") != 1:
            raise CompareError("%s: schema = 1 expected" % path)
        unknown = set(data) - {"schema", "route", "against", "allow"}
        if unknown:
            raise CompareError("%s: unknown keys %s" % (path, sorted(unknown)))
        self.route = need_text(path, data, "route")
        if data.get("against") != "mgba":
            raise CompareError("%s: against = \"mgba\" expected (comparison 1 takes no allowlist)" % path)
        entries = data.get("allow", [])
        if not isinstance(entries, list):
            raise CompareError("%s: allow must be an array of tables" % path)
        ids = set()
        for i, e in enumerate(entries, 1):
            where = "%s: allow %d" % (path, i)
            if not isinstance(e, dict):
                raise CompareError("%s: must be a table" % where)
            unknown = set(e) - {"id", "frames", "checks", "cause", "ref", "fixed_by"}
            if unknown:
                raise CompareError("%s: unknown keys %s" % (where, sorted(unknown)))
            ident = need_text(where, e, "id")
            if not re.match(r"^[A-Za-z0-9_.-]+$", ident):
                raise CompareError("%s: id %r: use letters, digits, '_', '.' and '-'" % (where, ident))
            if ident in ids:
                raise CompareError("%s: id %s is used twice" % (where, ident))
            ids.add(ident)
            frames = parse_frame_list(need_text(where, e, "frames"), "frames of %s" % ident)
            checks = e.get("checks")
            if not isinstance(checks, list) or not checks:
                raise CompareError("%s: checks must be a non-empty array" % where)
            for c in checks:
                if not isinstance(c, str) or not CHECK_RE.match(c):
                    raise CompareError("%s: check %r: layer1, layer2, ram:REGION or ram:*" % (where, c))
            need_text(where, e, "cause")
            need_text(where, e, "ref")
            need_text(where, e, "fixed_by", required=False)
            self.entries.append({"id": ident, "frames": frames, "checks": list(checks),
                                 "cause": e["cause"], "ref": e["ref"], "fixed_by": e.get("fixed_by", "")})

    def check_regions(self, regions):
        for e in self.entries:
            for c in e["checks"]:
                if c.startswith("ram:") and c != "ram:*" and c[4:] not in regions:
                    raise CompareError("%s: entry %s names region %s, which the captures do not hash" % (
                        self.path, e["id"], c[4:]))

    def covers(self, check, frame):
        """The id of the first entry that covers (check, frame), or None."""
        for e in self.entries:
            if (check in e["checks"] or (check.startswith("ram:") and "ram:*" in e["checks"])) and \
                    in_ranges(e["frames"], frame):
                return e["id"]
        return None


# ---------------------------------------------------------------- detail

class LineRecords:
    """Full line records (STEM.lines.tsv), indexed by frame."""

    def __init__(self, path):
        self.path = path
        try:
            self.f = open(path, "rb")
        except OSError as e:
            raise CompareError("%s: %s" % (path, e.strerror or e)) from None
        self.header = self.f.readline().decode("ascii", "replace").rstrip("\r\n").split("\t")
        if self.header[:2] != ["frame", "line"]:
            raise CompareError("%s: not a line-record file" % path)
        self.offsets = {}
        pos = self.f.tell()
        for raw in self.f:
            tab = raw.find(b"\t")
            try:
                frame = int(raw[:tab])
            except ValueError:
                raise CompareError("%s: bad frame field in %r" % (path, raw[:40])) from None
            if frame not in self.offsets:
                self.offsets[frame] = pos
            pos += len(raw)

    def frame(self, f):
        """{line: [values...]} for frame f, or None."""
        pos = self.offsets.get(f)
        if pos is None:
            return None
        self.f.seek(pos)
        out = {}
        for raw in self.f:
            parts = raw.decode("ascii", "replace").rstrip("\r\n").split("\t")
            if int(parts[0]) != f:
                break
            if len(parts) != len(self.header):
                raise CompareError("%s: frame %d line %s: %d columns, header has %d" % (
                    self.path, f, parts[1], len(parts), len(self.header)))
            out[int(parts[1])] = parts[2:]
        return out


def effect_lines(header, lines):
    """Lines on which a color effect can apply, from one engine's line records.

    Brightness (BLDCNT mode 2 or 3) with a nonzero BLDY, alpha (mode 1) with a
    nonzero BLDALPHA, or a semi-transparent OBJ: the records do not hold OAM,
    so any line with OBJs on (DISPCNT bit 12), a 2nd target in BLDCNT and a
    nonzero BLDALPHA counts. Windows are not looked at. Both make this an
    over-approximation of the lines where the tolerance may apply."""
    if lines is None:
        return set()
    cols = header[2:]
    try:
        i_disp, i_cnt = cols.index("DISPCNT"), cols.index("BLDCNT")
        i_alpha, i_y = cols.index("BLDALPHA"), cols.index("BLDY")
    except ValueError:
        return set()
    out = set()
    for line, v in lines.items():
        disp, cnt = int(v[i_disp], 16), int(v[i_cnt], 16)
        alpha, y = int(v[i_alpha], 16) & 0x1F1F, int(v[i_y], 16) & 0x1F
        mode = (cnt >> 6) & 3
        if (mode == 1 and alpha) or (mode in (2, 3) and y) or \
                ((disp & 0x1000) and (cnt & 0x3F00) and alpha):
            out.add(line)
    return out


def read_raw(directory, f):
    if directory is None:
        return None
    path = os.path.join(directory, "f%06d.bgr555" % f)
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise CompareError("%s: %s" % (path, e.strerror or e)) from None
    if len(data) != RAW_SIZE:
        raise CompareError("%s: %d bytes, a raw frame has %d" % (path, len(data), RAW_SIZE))
    return data


def check_raw_crc(side, directory, f, data, fb):
    """A raw frame must be the frame that the capture's fb column hashes."""
    crc = "%08X" % zlib.crc32(data)
    if crc != fb.upper():
        raise CompareError("%s raw frame %s has CRC-32 %s, but the capture's fb for that frame is %s: "
                           "the raw frames are not from the captured run" % (
                               side, os.path.join(directory, "f%06d.bgr555" % f), crc, fb))


def words(row):
    a = array.array("H")
    a.frombytes(row)
    if sys.byteorder != "little":
        a.byteswap()
    return a


def pixel_diff(ref, test, effects=None):
    """Compare two raw frames at 5-bit precision.

    With `effects` None every difference counts (comparison 1). Otherwise a
    pixel on a line in `effects` may differ by one step per channel.
    Returns {beyond, within, max, first: (line, column, ref, test) or None}."""
    beyond = within = biggest = 0
    first = None
    row_bytes = WIDTH * 2
    for y in range(HEIGHT):
        ra = ref[y * row_bytes:(y + 1) * row_bytes]
        rb = test[y * row_bytes:(y + 1) * row_bytes]
        if ra == rb:
            continue
        a, b = words(ra), words(rb)
        tolerant = effects is not None and y in effects
        for x in range(WIDTH):
            pa, pb = a[x], b[x]
            if pa == pb:
                continue
            d = max(abs((pa & 31) - (pb & 31)), abs(((pa >> 5) & 31) - ((pb >> 5) & 31)),
                    abs(((pa >> 10) & 31) - ((pb >> 10) & 31)))
            biggest = max(biggest, d)
            if tolerant and d <= 1:
                within += 1
            else:
                beyond += 1
                if first is None:
                    first = (y, x, pa, pb)
    return {"beyond": beyond, "within": within, "max": biggest, "first": first}


def line_diff(header, ra, rb):
    """[(line, [column, ...])] of lines that differ, and the first divergence
    (line, column, ref value, test value) or None."""
    cols = header[2:]
    out = []
    first = None
    for line in sorted(set(ra) | set(rb)):
        va, vb = ra.get(line), rb.get(line)
        if va == vb:
            continue
        if va is None or vb is None:
            out.append((line, ["missing in %s" % ("REF" if va is None else "TEST")]))
            first = first or (line, "line", "-" if va is None else "present", "-" if vb is None else "present")
            continue
        d = [cols[i] for i in range(len(cols)) if va[i] != vb[i]]
        out.append((line, d))
        if first is None:
            i = cols.index(d[0])
            first = (line, d[0], va[i], vb[i])
    return out, first


# ---------------------------------------------------------------- comparison

class Check:
    """One gated check: frames that differ, and how each is accounted for."""

    def __init__(self, name):
        self.name = name
        self.compared = 0
        self.differ = []        # frames (REF numbering)
        self.allowed = {}       # entry id -> [frames]
        self.failing = []
        self.undetermined = []  # layer 2 frames without raw data (failing or allowed)
        self.passed_detail = []  # layer 2: fb differs, pixels within tolerance

    def to_json(self):
        return {"compared": self.compared, "differ": len(self.differ),
                "differ_frames": format_ranges(to_ranges(self.differ)),
                "allowed": {k: len(v) for k, v in self.allowed.items()},
                "failing": len(self.failing), "failing_frames": format_ranges(to_ranges(self.failing)),
                "undetermined": len(self.undetermined),
                "passed_in_detail": len(self.passed_detail)}


def write_frame_report(path, checks, pairs, layer1_detail, layer2_verdict, allow, against):
    """One TSV row per (frame, gated check) that differs."""
    rows = []
    for name, ch in checks.items():
        allowed = {f: e for e, fs in ch.allowed.items() for f in fs}
        for f in ch.differ:
            if f in ch.passed_detail:
                status = "passes"
            elif f in allowed:
                status = "allowed:" + allowed[f]
            else:
                status = "FAILS"
            lines = columns = pixels = "-"
            if name == "layer1" and f in layer1_detail:
                diff, _ = layer1_detail[f]
                lines = format_ranges(to_ranges([l for l, _ in diff]))
                columns = " ".join(sorted({c for _, cs in diff for c in cs}))
            if name in ("layer2", "fb"):
                v = layer2_verdict.get(f)
                if v is None:
                    pixels = "undetermined"
                else:
                    pixels = "beyond=%d within=%d max=%d effect_lines=%s%s" % (
                        v["beyond"], v["within"], v["max"],
                        "-" if v["effect_lines"] is None else
                        "unknown(no_line_records)" if v["no_line_records"] else v["effect_lines"],
                        " first=%d,%d" % v["first"][:2] if v["first"] else "")
            rows.append((f, name, pairs.get(f, f), status, lines, columns, pixels))
    rows.sort()
    try:
        with open(path, "w") as fh:
            fh.write("frame\tcheck\ttest_frame\tstatus\tlines\tcolumns\tpixels\n")
            for r in rows:
                fh.write("\t".join(str(x) for x in r) + "\n")
    except OSError as e:
        raise CompareError("%s: %s" % (path, e.strerror or e)) from None


def compare(args, out):
    against = args.against
    fmap = FrameMap(args.frame_map)
    window = parse_frame_list(args.frames, "--frames") if args.frames else None
    allow = Allowlist(args.allowlist)
    if args.route and allow.path and allow.route != args.route:
        raise CompareError("%s is the allowlist of route %s, not of %s" % (allow.path, allow.route, args.route))
    if against == "interp" and args.allowlist:
        raise CompareError("comparison 1 takes no allowlist: it is exact, apart from the regions "
                           "comparison1.toml excludes")
    excl = Exclusions(args.exclusions if args.exclusions else
                      (DEFAULT_EXCLUSIONS if against == "interp" else None))
    if against == "mgba" and args.exclusions:
        raise CompareError("--exclusions is for comparison 1 (--against interp)")

    ref, test = Capture(args.ref), Capture(args.test)
    only_ref = [c for c in ref.header[1:] if c not in test.index]
    only_test = [c for c in test.header[1:] if c not in ref.index]
    if only_ref or only_test:
        raise CompareError("the two captures do not have the same columns (only in REF: %s; only in TEST: %s); "
                           "both engines must read the same spec and memory fields" % (
                               ", ".join(only_ref) or "-", ", ".join(only_test) or "-"))
    cols = ref.header[1:]
    regions = [c[4:] for c in cols if c.startswith("ram_")]
    for name in excl.regions:
        if name not in regions:
            raise CompareError("%s: region %s is not in the captures" % (excl.path, name))
    allow.check_regions(regions)
    for need in ("fb",) + (("lines",) if against == "mgba" else ()):
        if need not in ref.index:
            raise CompareError("the captures have no %s column" % need)

    gated_ram = [r for r in regions if r not in excl.regions]
    if against == "interp":
        checks = {"fb": Check("fb")}
    else:
        checks = {"layer1": Check("layer1"), "layer2": Check("layer2")}
    for r in gated_ram:
        checks["ram:" + r] = Check("ram:" + r)
    gated_cols = ["fb"] + (["lines"] if against == "mgba" else []) + ["ram_" + r for r in gated_ram]
    info_cols = [c for c in cols if c not in gated_cols and c not in ENGINE_SPECIFIC
                 and not (c.startswith("ram_") and c[4:] in excl.regions)]
    excluded_cols = ["ram_" + r for r in excl.regions]
    info = {c: [] for c in info_cols + excluded_cols}
    cycles = {"n": 0, "differ": 0, "min": None, "max": None}
    ri = {c: ref.index[c] for c in cols}
    ti = {c: test.index[c] for c in cols}

    tw = Window(test, fmap.reach())
    missing_ref, missing_test = [], []
    pairs = {}          # REF frame -> TEST frame, for the frames compared
    resolved = []       # (REF frame, offset) chosen by searches
    need_detail = {}    # REF frame -> set of "lines", "raw"
    fb_values = {}      # REF frame -> (REF fb, TEST fb), for the frames whose fb differs
    divergences = []    # (frame, check, text, failing) of every gated difference
    compared = 0

    def note_first(f, check, text, failing):
        divergences.append((f, check, text, failing))

    ref_rows = ref.rows()
    wanted = window
    for f, rp in ref_rows:
        if wanted is not None and not in_ranges(wanted, f):
            if f > wanted[-1][1]:
                break
            continue
        kind, value = fmap.rule(f)
        tw.fill(f + fmap.reach())
        tw.drop_below(f + fmap.lowest())
        if kind == "fixed":
            g = f + value
            tp = tw.get(g)
        else:
            best = None
            for k in range(-value, value + 1):
                cand = tw.get(f + k)
                if cand is None:
                    continue
                score = sum(rp[ri[c]] == cand[ti[c]] for c in gated_cols)
                key = (-score, abs(k), k)
                if best is None or key < best[0]:
                    best = (key, k, cand)
            if best is None:
                g, tp = f, None
            else:
                g, tp = f + best[1], best[2]
                resolved.append((f, best[1]))
        if tp is None:
            missing_test.append(f)
            continue
        compared += 1
        pairs[f] = g
        for c in info:
            if rp[ri[c]] != tp[ti[c]]:
                info[c].append(f)
        if "cycles" in ri:
            try:
                d = int(tp[ti["cycles"]]) - int(rp[ri["cycles"]])
                cycles["n"] += 1
                if d:
                    cycles["differ"] += 1
                cycles["min"] = d if cycles["min"] is None else min(cycles["min"], d)
                cycles["max"] = d if cycles["max"] is None else max(cycles["max"], d)
            except ValueError:
                pass
        for r in gated_ram:
            ch = checks["ram:" + r]
            ch.compared += 1
            if rp[ri["ram_" + r]] != tp[ti["ram_" + r]]:
                ch.differ.append(f)
        if against == "interp":
            ch = checks["fb"]
            ch.compared += 1
            if rp[ri["fb"]] != tp[ti["fb"]]:
                ch.differ.append(f)
                need_detail.setdefault(f, set()).add("raw")
                fb_values[f] = (rp[ri["fb"]], tp[ti["fb"]])
        else:
            l1, l2 = checks["layer1"], checks["layer2"]
            l1.compared += 1
            l2.compared += 1
            if rp[ri["lines"]] == "-" or tp[ti["lines"]] == "-":
                raise CompareError("frame %d: the line state was not captured (lines is '-'); comparison 2 "
                                   "needs it (GBARECOMP_CAPTURE_LINE_STATE unset)" % f)
            if rp[ri["lines"]] != tp[ti["lines"]]:
                l1.differ.append(f)
                need_detail.setdefault(f, set()).add("lines")
            if rp[ri["fb"]] != tp[ti["fb"]]:
                l2.differ.append(f)
                need_detail.setdefault(f, set()).update(("raw", "lines"))
                fb_values[f] = (rp[ri["fb"]], tp[ti["fb"]])

    # Read the rest of both files: the frame counts in the report, and the
    # check that every row parses and frames increase.
    for _ in ref_rows:
        pass
    for _ in tw.it:
        pass
    ref.close()
    test.close()

    # REF frames of the window that REF lacks: a run that stopped early.
    have = set(ref.frames)
    if wanted is not None:
        for lo, hi in wanted:
            for f in range(lo, hi + 1):
                if f not in have:
                    missing_ref.append(f)
                if len(missing_ref) > 100000:
                    break
    if compared == 0:
        raise CompareError("no frame compared (REF %d frames, TEST %d frames%s)" % (
            len(ref.frames), len(test.frames), ", --frames " + args.frames if args.frames else ""))

    # ---- detail
    ref_lines = LineRecords(args.ref_lines) if args.ref_lines else None
    test_lines = LineRecords(args.test_lines) if args.test_lines else None
    if ref_lines and test_lines and ref_lines.header != test_lines.header:
        raise CompareError("the two line-record files have different columns")
    detail = {"frames": 0, "lines": [], "pixels": []}
    layer1_detail = {}   # frame -> (lines differing, first)
    layer2_verdict = {}  # frame -> pixel_diff result, or None (undetermined)
    for f in sorted(need_detail):
        g = pairs[f]
        la = ref_lines.frame(f) if ref_lines else None
        lb = test_lines.frame(g) if test_lines else None
        got = False
        if "lines" in need_detail[f] and la is not None and lb is not None:
            diff, first = line_diff(ref_lines.header, la, lb)
            layer1_detail[f] = (diff, first)
            got = True
        if "raw" in need_detail[f]:
            ra, rb = read_raw(args.ref_raw, f), read_raw(args.test_raw, g)
            if ra is not None and rb is not None:
                check_raw_crc("REF", args.ref_raw, f, ra, fb_values[f][0])
                check_raw_crc("TEST", args.test_raw, g, rb, fb_values[f][1])
                if against == "interp":
                    eff = None
                else:
                    eff = effect_lines(ref_lines.header, la) | effect_lines(test_lines.header, lb) \
                        if la is not None and lb is not None else set()
                layer2_verdict[f] = pixel_diff(ra, rb, eff)
                layer2_verdict[f]["effect_lines"] = None if eff is None else len(eff)
                # Without line records no line has an effect: no tolerance.
                layer2_verdict[f]["no_line_records"] = against == "mgba" and (la is None or lb is None)
                got = True
            else:
                layer2_verdict[f] = None
        if got:
            detail["frames"] += 1

    for records in (ref_lines, test_lines):
        if records:
            records.f.close()

    # ---- verdicts and allowlist
    def account(ch, f):
        """Record a failed check on frame f; True when no allowlist entry covers it."""
        entry = allow.covers(ch.name, f) if against == "mgba" else None
        if entry:
            ch.allowed.setdefault(entry, []).append(f)
            return False
        ch.failing.append(f)
        return True

    for name, ch in checks.items():
        for f in ch.differ:
            if name in ("layer2", "fb"):
                v = layer2_verdict.get(f)
                if v is None:
                    ch.undetermined.append(f)
                    failing = account(ch, f)
                    note_first(f, name, "fb CRC differs (no raw frames: undetermined)", failing)
                elif v["beyond"] or name == "fb":
                    # Comparison 1 is exact: its fb differences fail whatever
                    # the pixels show (with the CRCs checked, the raw frames
                    # of such a frame differ anyway).
                    failing = account(ch, f)
                    if v["first"] is None:
                        note_first(f, name, "fb CRC differs", failing)
                    else:
                        y, x, pa, pb = v["first"]
                        note_first(f, name, "line %d column %d: REF %04X TEST %04X (%d pixels %s, max %d steps)" % (
                            y, x, pa, pb, v["beyond"], "differ" if against == "interp" else "beyond tolerance",
                            v["max"]), failing)
                else:
                    ch.passed_detail.append(f)
            elif name == "layer1":
                failing = account(ch, f)
                d = layer1_detail.get(f)
                if d and d[1]:
                    line, col, va, vb = d[1]
                    note_first(f, name, "line %d %s: REF %s TEST %s (%d lines differ)" % (
                        line, col, va, vb, len(d[0])), failing)
                else:
                    note_first(f, name, "lines CRC differs (no line records)", failing)
            else:
                failing = account(ch, f)
                note_first(f, name, "%s hash differs" % name[4:], failing)
    first_div = min(divergences) if divergences else None
    first_fail = min((d for d in divergences if d[3]), default=None)

    # ---- allowlist coverage: per entry and check, the compared frames the
    # entry would account for (where it is the first entry that covers the
    # check), and those it did not need.
    coverage = {}  # entry id -> {check: [frames]}
    unused = {}    # entry id -> {check: [frames]}
    if against == "mgba" and allow.entries:
        for f in pairs:
            for name in checks:
                e = allow.covers(name, f)
                if e:
                    coverage.setdefault(e, {}).setdefault(name, []).append(f)
        for e, by_check in coverage.items():
            for name, fs in by_check.items():
                hit = set(checks[name].allowed.get(e, []))
                left = [f for f in fs if f not in hit]
                if left:
                    unused.setdefault(e, {})[name] = left

    failing_total = sorted(set(f for ch in checks.values() for f in ch.failing))
    result_ok = not failing_total and not missing_test and not missing_ref

    # ---- detail requests
    if args.detail_out:
        rows = []
        for f in sorted(need_detail):
            covered = all(allow.covers(c, f) for c in ("layer1", "layer2")) if against == "mgba" else False
            rows.append((covered, f))
        rows.sort()
        rows = rows[:args.max_detail]
        try:
            with open(args.detail_out, "w") as fh:
                for _, f in sorted(rows, key=lambda r: r[1]):
                    fh.write("%d\t%d\t%s\n" % (f, pairs[f], ",".join(sorted(need_detail[f]))))
        except OSError as e:
            raise CompareError("%s: %s" % (args.detail_out, e.strerror or e)) from None

    if args.frame_report:
        write_frame_report(args.frame_report, checks, pairs, layer1_detail, layer2_verdict, allow, against)

    # ---- report
    lim = args.list
    title = "comparison 1 (recompiled build against the interpreter reference)" if against == "interp" \
        else "comparison 2 (gbarecomp against mGBA)"
    print("%s" % title, file=out)
    print("REF  %s (%d frames)" % (args.ref, len(ref.frames)), file=out)
    print("TEST %s (%d frames)" % (args.test, len(test.frames)), file=out)
    print("frames compared: %d%s" % (compared, " (" + format_ranges(window, lim) + ")" if window else ""),
          file=out)
    print("frame map: %s" % (fmap.spec or "none (TEST frame = REF frame)"), file=out)
    if resolved:
        runs = []
        for f, k in resolved:
            if runs and runs[-1][2] == k and runs[-1][1] == f - 1:
                runs[-1][1] = f
            else:
                runs.append([f, f, k])
        print("  offsets chosen by the search: %s" % ",".join(
            ("%d" % a if a == b else "%d-%d" % (a, b)) + ":%+d" % k for a, b, k in runs), file=out)
    if against == "interp":
        print("excluded regions (%s): %s" % (os.path.relpath(excl.path) if excl.path else "-",
                                             ", ".join(sorted(excl.regions)) or "none"), file=out)
    else:
        print("allowlist: %s" % ("%s (%d entries)" % (os.path.relpath(allow.path), len(allow.entries))
                                 if allow.path else "none"), file=out)
    if missing_test:
        print("MISSING from TEST: %d frames: %s" % (len(missing_test), format_ranges(to_ranges(missing_test), lim)),
              file=out)
    if missing_ref:
        print("MISSING from REF: %d frames: %s" % (len(missing_ref), format_ranges(to_ranges(missing_ref), lim)),
              file=out)
    print("", file=out)
    print("%-22s %7s %7s %7s %7s  %s" % ("gated check", "frames", "differ", "allowed", "FAILING", "failing frames"),
          file=out)
    for name, ch in checks.items():
        print("%-22s %7d %7d %7d %7d  %s" % (
            name, ch.compared, len(ch.differ), sum(len(v) for v in ch.allowed.values()), len(ch.failing),
            format_ranges(to_ranges(ch.failing), lim)), file=out)
    print("", file=out)
    print("%-22s %7s %7s  %s" % ("reported only", "frames", "differ", "frames that differ"), file=out)
    for c in info:
        tag = c + (" (excluded)" if c in excluded_cols else "")
        print("%-22s %7d %7d  %s" % (tag, compared, len(info[c]), format_ranges(to_ranges(info[c]), lim)), file=out)
    if cycles["n"]:
        print("%-22s %7d %7d  TEST - REF from %+d to %+d cycles" % (
            "cycles", cycles["n"], cycles["differ"], cycles["min"], cycles["max"]), file=out)
    print("", file=out)
    print("frames that differ, by gated check:", file=out)
    for name, ch in checks.items():
        if ch.differ:
            print("  %s: %s" % (name, format_ranges(to_ranges(ch.differ), lim)), file=out)
    if need_detail:
        undet = sorted(set(f for ch in checks.values() for f in ch.undetermined))
        print("detail: %d of %d frames that need it were detailed%s" % (
            detail["frames"], len(need_detail),
            "; no raw frames for %d whose fb differs (%s undetermined): %s" % (
                len(undet), "layer 2" if against == "mgba" else "fb", format_ranges(to_ranges(undet), lim))
            if undet else ""), file=out)
        l2 = checks.get("layer2") or checks.get("fb")
        if l2 is not None and l2.passed_detail:
            print("  %s: %d frames whose fb differs pass in detail (pixels within tolerance): %s" % (
                l2.name, len(l2.passed_detail), format_ranges(to_ranges(l2.passed_detail), lim)), file=out)
        l1_frames = [f for f in sorted(layer1_detail) if layer1_detail[f][0]]
        for f in l1_frames[:5]:
            diff, first = layer1_detail[f]
            cols_seen = sorted({c for _, cs in diff for c in cs})
            print("  layer 1, frame %d: %d lines (%s), columns %s" % (
                f, len(diff), format_ranges(to_ranges([l for l, _ in diff]), 6), " ".join(cols_seen)), file=out)
        if len(l1_frames) > 5:
            print("  ... %d more frames whose line records differ" % (len(l1_frames) - 5), file=out)
    if first_div:
        print("first divergence: frame %d, %s: %s%s" % (
            first_div[0], first_div[1], first_div[2], "" if first_div[3] else " (allowlisted)"), file=out)
    if first_fail and first_fail != first_div:
        print("first failing divergence: frame %d, %s: %s" % first_fail[:3], file=out)
    if against == "mgba" and allow.entries:
        print("", file=out)
        print("allowlist entries (per check: compared frames hit/covered):", file=out)
        for e in allow.entries:
            cov = coverage.get(e["id"], {})
            hits = {name: len(ch.allowed.get(e["id"], [])) for name, ch in checks.items()}
            text = ", ".join("%s %d/%d" % (name, hits[name], len(fs)) for name, fs in cov.items())
            if not any(hits.values()):
                text = "UNUSED" + (" (covers %s)" % text if text else " (covers no compared frame)")
            elif unused.get(e["id"]):
                text += "  PARTLY USED"
            print("  %-34s %s%s" % (e["id"], text,
                                   "  (fixed by %s)" % e["fixed_by"] if e["fixed_by"] else ""), file=out)
            if any(hits.values()):
                for name, fs in unused.get(e["id"], {}).items():
                    print("  %-34s   unused on %s: %s" % ("", name, format_ranges(to_ranges(fs), lim)), file=out)
    print("", file=out)
    if result_ok:
        print("RESULT: PASS (%d frames compared)" % compared, file=out)
    else:
        why = []
        if failing_total:
            why.append("%d frames fail a gated check: %s" % (len(failing_total),
                                                          format_ranges(to_ranges(failing_total), lim)))
        if missing_test or missing_ref:
            why.append("%d frames missing" % (len(missing_test) + len(missing_ref)))
        print("RESULT: FAIL (%s)" % "; ".join(why), file=out)

    if args.json:
        summary = {
            "against": against, "ref": args.ref, "test": args.test, "compared": compared,
            "frames": format_ranges(window) if window else None,
            "frame_map": fmap.spec, "map_resolved": [[f, k] for f, k in resolved],
            "excluded_regions": sorted(excl.regions), "allowlist": allow.path,
            "missing_test": format_ranges(to_ranges(missing_test)),
            "missing_ref": format_ranges(to_ranges(missing_ref)),
            "checks": {name: ch.to_json() for name, ch in checks.items()},
            "reported": {c: {"differ": len(v), "frames": format_ranges(to_ranges(v))} for c, v in info.items()},
            "cycles": cycles,
            "first_divergence": None if not first_div else
            {"frame": first_div[0], "check": first_div[1], "text": first_div[2], "failing": first_div[3]},
            "first_failing_divergence": None if not first_fail else
            {"frame": first_fail[0], "check": first_fail[1], "text": first_fail[2]},
            "allowlist_hits": {e["id"]: {name: len(ch.allowed.get(e["id"], [])) for name, ch in checks.items()}
                               for e in allow.entries},
            "allowlist_covered": {e: {name: len(fs) for name, fs in by_check.items()}
                                  for e, by_check in coverage.items()},
            "allowlist_unused": {e: {name: format_ranges(to_ranges(fs)) for name, fs in by_check.items()}
                                 for e, by_check in unused.items()},
            "detail_frames": detail["frames"], "need_detail": len(need_detail),
            "result": "PASS" if result_ok else "FAIL",
        }
        try:
            with open(args.json, "w") as fh:
                json.dump(summary, fh, indent=1, sort_keys=True)
                fh.write("\n")
        except OSError as e:
            raise CompareError("%s: %s" % (args.json, e.strerror or e)) from None
    return 0 if result_ok else 1


def main(argv=None, out=None):
    out = out or sys.stdout
    ap = argparse.ArgumentParser(prog="compare.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("ref")
    ap.add_argument("test")
    ap.add_argument("--against", required=True, choices=("interp", "mgba"))
    ap.add_argument("--frames")
    ap.add_argument("--frame-map")
    ap.add_argument("--allowlist")
    ap.add_argument("--route")
    ap.add_argument("--exclusions")
    ap.add_argument("--ref-lines")
    ap.add_argument("--test-lines")
    ap.add_argument("--ref-raw")
    ap.add_argument("--test-raw")
    ap.add_argument("--detail-out")
    ap.add_argument("--max-detail", type=int, default=1200)
    ap.add_argument("--json")
    ap.add_argument("--frame-report")
    ap.add_argument("--list", type=int, default=20)
    args = ap.parse_args(argv)
    if args.max_detail < 0 or args.list < 1:
        ap.error("--max-detail must be 0 or more and --list 1 or more")
    try:
        return compare(args, out)
    except CompareError as e:
        print("compare.py: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
