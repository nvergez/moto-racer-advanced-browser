#!/usr/bin/env python3
"""Harness input scripts to gbarecomp input replays (stdlib only; run with python3 -I).

usage:
  script2replay.py SCRIPT [--frames N] [--offset K] [-o FILE]
  script2replay.py --route NAME [--manifest FILE] [--offset K] [-o FILE]
  script2replay.py --embed FILE [--manifest FILE] [--route NAME]...
  script2replay.py --embed FILE --script NAME=SCRIPT...
  script2replay.py --check REPLAY TRACE

  SCRIPT          a harness input script (tools/analysis/input/*.txt); the
                  replay goes to standard output, or to FILE with -o
  --frames N      the harness's --frames N: stop at frame N, and run on to
                  frame N with the held keys if the script ends before it
  --route NAME    the script and frame count of a route of the manifest
                  (tools/difftest/routes.toml); with --embed, the routes to
                  embed (default: all)
  --offset K      write every event K frames later (earlier if K < 0) than
                  the harness applies it. Only for measuring how a comparison
                  reacts to a wrong convention; comparisons use 0
  --embed FILE    write a C++ source with the replays of the manifest's routes
                  (or of the --script pairs), for test builds that cannot read
                  a file: the browser (docs/phase2-plan.md, P2-02, P2-12)
  --check REPLAY TRACE
                  check a replay against the keys column of a harness
                  trace.tsv (run with --trace over the frames to check):
                  exit 1 if any traced frame reads other keys in the replay

Reading the manifest needs Python 3.11 or newer (tomllib), as routes.py does.

The replay format, mra-keyinput-v1
----------------------------------

The first line is exactly "mra-keyinput-v1". Then one event per line,
"FRAME,0xKEYS": from harness frame FRAME on, until the next event, KEYINPUT
reads KEYS (active low: 0x03FF is no key, bit 0 is A). Lines that start with
"#" and empty lines are comments. Frames are decimal, at least 2 and strictly
increasing; KEYS is 1 to 4 hex digits, at most 0x03FF. Before the first event
no key is pressed.

FRAME is the harness's frame number (tools/analysis/README.md, "Frame
numbering"): the frame whose completion moves mGBA's frame counter from
FRAME-1 to FRAME. The harness sets the keys of frame FRAME before it emulates
that frame, that is right after the VBlank start that ends frame FRAME-1, and
trace.tsv shows them in its row FRAME: "until 2714" then "tap A" puts A in
frames 2715-2720, and the replay holds "2715,0x03FE" and "2721,0x03FF".
Frame 1 runs from reset to the first VBlank start, so its keys cannot be
replayed at a VBlank start; a script that presses a key on frame 1 is refused.

gbarecomp applies the replay at the same point. Our src/main.cpp installs
RunOptions::input_frame when MRA_REPLAY names a replay; gbarecomp calls it
once per VBlank start, before the VBlank IRQ, with the PPU frame_count k.
That VBlank start ends harness frame k+1 (diagnosis section 7.3: a VBlank-start
capture taken at frame_count k is harness frame k+1), so the callback returns
the keys of frame k+2, the frame that starts there.

The header is not a "#" comment on purpose. gbarecomp's own
GBARECOMP_INPUT_REPLAY reads "gbarecomp-keyinput-v1" files with the same
"FRAME,0xKEYS" lines, but numbers frames by its PPU frame_count and applies
them from its run loop, not at VBlank start. Its loader skips only lines that
start with "#" and rejects any other line it cannot parse, so it refuses a
file in this format instead of replaying it on other frames.

The harness's script commands are mirrored exactly (gbaharness.c, runScript
and runFrames): wait, until, press, tap, taptiming, hold, release, end; dump,
shot, mark and savestate run no frame. The converter is stricter than the
harness on malformed scripts: a count that is not a non-negative decimal
number is an error here, where the harness reads it with atol().
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
DIFFTEST_DIR = os.path.join(REPO_ROOT, "tools", "difftest")
DEFAULT_MANIFEST = os.path.join(DIFFTEST_DIR, "routes.toml")

HEADER = "mra-keyinput-v1"
KEY_NAMES = ("A", "B", "SELECT", "START", "RIGHT", "LEFT", "UP", "DOWN", "R", "L")
NO_KEYS = 0x03FF
FIRST_FRAME = 2  # the first frame whose keys a VBlank-start hook can set
MAX_FRAME = 0xFFFFFFFF
EVENT_RE = re.compile(r"^([0-9]{1,10}),0x([0-9A-Fa-f]{1,4})$")
COUNT_RE = re.compile(r"^[0-9]+$")
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class Error(Exception):
    """A bad script, replay, trace or argument: reported without a traceback."""


# ---------------------------------------------------------------- scripts

def parse_keys(text, where):
    """Active-high key mask of a harness key list (A+B, case-insensitive, NONE)."""
    mask = 0
    for tok in re.split(r"[+,|]", text):
        if not tok:
            continue  # strtok() skips empty tokens
        name = tok.upper()
        if name == "NONE":
            continue
        if name not in KEY_NAMES:
            raise Error("%s: unknown key '%s'" % (where, tok))
        mask |= 1 << KEY_NAMES.index(name)
    return mask


def parse_count(text, where):
    if not COUNT_RE.match(text):
        raise Error("%s: '%s' is not a non-negative decimal number" % (where, text))
    return int(text)


def simulate(lines, source="script", frames=None):
    """Keys the harness applies on each frame of a run of this script.

    Returns (keys, warnings): keys[f] is the active-high key mask of harness
    frame f, for f = 1 .. the last frame the run emulates (keys[0] is unused).
    frames is the harness's --frames N, or None.
    """
    keys = [0]
    held = 0
    tap_on = tap_off = 6
    stop = False
    warnings = []

    def cur():
        return len(keys) - 1  # mGBA's frame counter: frames emulated so far

    def run(n, mask):
        nonlocal stop
        for _ in range(n):
            if stop:
                return
            if frames is not None and cur() >= frames:
                stop = True
                return
            keys.append(mask)

    for lineno, raw in enumerate(lines, 1):
        if stop:
            break
        argv = raw.split("#", 1)[0].split()[:8]
        if not argv:
            continue
        where = "%s:%d" % (source, lineno)
        cmd, args = argv[0], argv[1:]
        if cmd == "wait":
            if not args:
                raise Error("%s: wait N" % where)
            run(parse_count(args[0], where), held)
        elif cmd == "until":
            if not args:
                raise Error("%s: until FRAME" % where)
            target = parse_count(args[0], where)
            if cur() > target:
                warnings.append("%s: already past frame %d (at %d)" % (where, target, cur()))
            while cur() < target and not stop:
                run(1, held)
        elif cmd == "press":
            if not args:
                raise Error("%s: press KEYS [N]" % where)
            n = parse_count(args[1], where) if len(args) > 1 else tap_on
            run(n, held | parse_keys(args[0], where))
        elif cmd == "tap":
            if not args:
                raise Error("%s: tap KEYS [COUNT]" % where)
            count = parse_count(args[1], where) if len(args) > 1 else 1
            k = parse_keys(args[0], where)
            for _ in range(count):
                if stop:
                    break
                run(tap_on, held | k)
                run(tap_off, held)
        elif cmd == "taptiming":
            if len(args) < 2:
                raise Error("%s: taptiming ON OFF" % where)
            tap_on, tap_off = parse_count(args[0], where), parse_count(args[1], where)
        elif cmd == "hold":
            if not args:
                raise Error("%s: hold KEYS" % where)
            held |= parse_keys(args[0], where)
        elif cmd == "release":
            held = held & ~parse_keys(args[0], where) if args else 0
        elif cmd == "savestate":
            if not args:
                raise Error("%s: savestate PATH" % where)
        elif cmd in ("dump", "shot", "mark"):
            pass
        elif cmd == "end":
            stop = True
        else:
            raise Error("%s: unknown command '%s'" % (where, cmd))
    # The harness runs on to --frames with the held keys unless the script
    # stopped the run (end, or the frame limit).
    if frames is not None and not stop:
        while cur() < frames:
            keys.append(held)
    return keys, warnings


def events_of(keys, offset=0, source="script"):
    """The replay's events: (frame, active-low KEYINPUT) where the keys change."""
    if len(keys) > 1 and keys[1]:
        raise Error("%s: keys are pressed on frame 1, which runs before the first VBlank "
                    "start; a VBlank-start replay cannot apply them" % source)
    events = []
    last = 0
    for f in range(1, len(keys)):
        if keys[f] != last:
            frame = f + offset
            if frame < FIRST_FRAME or frame > MAX_FRAME:
                raise Error("%s: with offset %d, the event of frame %d lands on frame %d, "
                            "outside %d-%d" % (source, offset, f, frame, FIRST_FRAME, MAX_FRAME))
            events.append((frame, NO_KEYS & ~keys[f]))
            last = keys[f]
    return events


def replay_text(events, source, offset=0, last_frame=None):
    out = [HEADER,
           "# Converted by tools/replay/script2replay.py from %s, offset %d%s." % (
               source, offset, ", %d frames" % last_frame if last_frame is not None else ""),
           "# FRAME,0xKEYS: from harness frame FRAME on, KEYINPUT reads KEYS (active low,",
           "# 0x03FF = no key), applied at the VBlank start that begins frame FRAME."]
    out += ["%d,0x%04X" % e for e in events]
    return "\n".join(out) + "\n"


def convert_script(path, frames=None, offset=0, label=None):
    """(replay text, warnings) for one harness script."""
    label = label or os.path.basename(path)
    try:
        with open(path) as f:
            lines = f.read().split("\n")
    except OSError as e:
        raise Error("%s: %s" % (path, e.strerror or e))
    keys, warnings = simulate(lines, label, frames)
    events = events_of(keys, offset, label)
    return replay_text(events, label, offset, len(keys) - 1), warnings


# ---------------------------------------------------------------- replays

def parse_replay(text, source="replay"):
    """Events of an mra-keyinput-v1 replay, with the rules src/main.cpp applies."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    lines = [line[:-1] if line.endswith("\r") else line for line in lines]
    if not lines or lines[0] != HEADER:
        raise Error("%s:1: the first line must be '%s'" % (source, HEADER))
    events = []
    for n, line in enumerate(lines[1:], 2):
        if not line or line.startswith("#"):
            continue
        m = EVENT_RE.match(line)
        if not m:
            raise Error("%s:%d: expected FRAME,0xKEYS, got '%s'" % (source, n, line))
        frame, keys = int(m.group(1)), int(m.group(2), 16)
        if frame < FIRST_FRAME or frame > MAX_FRAME:
            raise Error("%s:%d: frame %d is outside %d-%d" % (source, n, frame, FIRST_FRAME, MAX_FRAME))
        if keys > NO_KEYS:
            raise Error("%s:%d: keys 0x%X are more than 0x%04X" % (source, n, keys, NO_KEYS))
        if events and frame <= events[-1][0]:
            raise Error("%s:%d: frame %d does not come after frame %d" % (source, n, frame, events[-1][0]))
        events.append((frame, keys))
    return events


def keys_at(events, frame):
    """Active-low KEYINPUT the replay gives harness frame `frame`."""
    keys = NO_KEYS
    for f, k in events:
        if f > frame:
            break
        keys = k
    return keys


def check_trace(events, trace_path, out=sys.stdout):
    """Compare a replay with trace.tsv's keys column; returns the number of frames that differ."""
    try:
        with open(trace_path) as f:
            header = f.readline().rstrip("\r\n").split("\t")
            if "frame" not in header or "keys" not in header:
                raise Error("%s: no frame and keys columns" % trace_path)
            fi, ki = header.index("frame"), header.index("keys")
            checked = differ = 0
            first = None
            for n, line in enumerate(f, 2):
                parts = line.rstrip("\r\n").split("\t")
                if len(parts) != len(header):
                    raise Error("%s:%d: %d columns, header has %d" % (trace_path, n, len(parts), len(header)))
                try:
                    frame, active_high = int(parts[fi]), int(parts[ki], 16)
                except ValueError:
                    raise Error("%s:%d: bad frame or keys value" % (trace_path, n)) from None
                want = NO_KEYS & ~active_high
                got = keys_at(events, frame)
                checked += 1
                if got != want:
                    differ += 1
                    if first is None:
                        first = (frame, got, want)
    except OSError as e:
        raise Error("%s: %s" % (trace_path, e.strerror or e))
    if not checked:
        raise Error("%s: no rows" % trace_path)
    print("%d frames checked, %d differ%s" % (
        checked, differ,
        "; first at frame %d: replay 0x%04X, trace 0x%04X" % first if first else ""), file=out)
    return differ


# ---------------------------------------------------------------- embedding

def cpp_string(text):
    """C++ string literal lines for text (ASCII; escapes what needs escaping)."""
    pieces = []
    for line in text.splitlines(keepends=True):
        s = ""
        for ch in line:
            if ch == "\\":
                s += "\\\\"
            elif ch == '"':
                s += '\\"'
            elif ch == "\n":
                s += "\\n"
            elif " " <= ch <= "~":
                s += ch
            else:
                s += "\\%03o" % (ord(ch) & 0xFF)
        pieces.append('    "%s"' % s)
    return "\n".join(pieces) if pieces else '    ""'


def cpp_source(routes, origin):
    """The routes table: routes is a list of (name, replay text)."""
    out = ["// Generated by tools/replay/script2replay.py --embed from %s." % origin,
           "// Input replays for test builds only (docs/phase2-plan.md, P2-02). Do not edit",
           "// or commit: regenerate it. A build that embeds it is a test build.",
           '#include "replay_routes.h"',
           "",
           "namespace {"]
    for i, (name, text) in enumerate(routes):
        out.append("const char kReplay%d[] =  // %s" % (i, name))
        out.append(cpp_string(text) + ";")
    out.append("const MraReplayRoute kRoutes[] = {")
    for i, (name, _) in enumerate(routes):
        out.append('    {"%s", kReplay%d},' % (name, i))
    out += ["};",
            "}  // namespace",
            "",
            "extern \"C\" const MraReplayRoute* mra_replay_route_table(unsigned* count) {",
            "    *count = static_cast<unsigned>(sizeof(kRoutes) / sizeof(kRoutes[0]));",
            "    return kRoutes;",
            "}",
            ""]
    return "\n".join(out)


def load_manifest(path):
    if sys.version_info < (3, 11):
        raise Error("reading the route manifest needs Python 3.11 or newer (tomllib); this is %s"
                    % sys.version.split()[0])
    if DIFFTEST_DIR not in sys.path:
        sys.path.insert(0, DIFFTEST_DIR)
    import routes  # noqa: E402  (tools/difftest/routes.py)
    try:
        return routes.Manifest(path)
    except routes.ManifestError as e:
        raise Error("%s: %s" % (path, e)) from None


def manifest_route(manifest, name):
    if name not in manifest.routes:
        raise Error("unknown route %r (known: %s)" % (name, ", ".join(manifest.routes)))
    r = manifest.routes[name]
    return os.path.join(REPO_ROOT, r.script), r.frames


def write_if_changed(path, text):
    """Write text to path unless it already holds it (keeps build timestamps)."""
    try:
        with open(path) as f:
            if f.read() == text:
                return
    except OSError:
        pass
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


# ---------------------------------------------------------------- main

def main(argv=None, out=sys.stdout, err=sys.stderr):
    ap = argparse.ArgumentParser(
        prog="script2replay.py",
        description="Harness input scripts to gbarecomp input replays (mra-keyinput-v1).",
        epilog="See the top of this file for the replay format and its frame convention.")
    ap.add_argument("script", nargs="?", help="harness input script")
    ap.add_argument("--frames", type=int, help="the harness's --frames N")
    ap.add_argument("--offset", type=int, default=0, help="shift every event by K frames")
    ap.add_argument("-o", "--output", help="write the replay here instead of standard output")
    ap.add_argument("--route", action="append", default=[], help="a route of the manifest")
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST, help="route manifest (routes.toml)")
    ap.add_argument("--embed", metavar="FILE", help="write the routes table (C++) to FILE")
    ap.add_argument("--script", dest="pairs", action="append", default=[], metavar="NAME=SCRIPT",
                    help="with --embed, a replay to embed without the manifest")
    ap.add_argument("--check", nargs=2, metavar=("REPLAY", "TRACE"),
                    help="check a replay against a harness trace.tsv")
    args = ap.parse_args(argv)
    try:
        if args.check:
            if (args.script or args.route or args.embed or args.pairs or args.output or args.offset
                    or args.frames is not None):
                raise Error("--check takes no other option")
            replay, trace = args.check
            try:
                with open(replay) as f:
                    events = parse_replay(f.read(), replay)
            except OSError as e:
                raise Error("%s: %s" % (replay, e.strerror or e))
            return 1 if check_trace(events, trace, out) else 0

        if args.embed:
            if args.script or args.frames is not None or args.offset or args.output:
                raise Error("--embed takes --route, --manifest or --script only")
            if args.pairs and args.route:
                raise Error("--embed takes --route (from the manifest) or --script, not both")
            routes = []
            if args.pairs:
                for pair in args.pairs:
                    name, sep, path = pair.partition("=")
                    if not sep or not NAME_RE.match(name) or not path:
                        raise Error("--script %r: expected NAME=SCRIPT, NAME made of letters, "
                                    "digits and _" % pair)
                    if name in (n for n, _ in routes):
                        raise Error("--script: %s given twice" % name)
                    text, warnings = convert_script(path, label=os.path.basename(path))
                    for w in warnings:
                        print("warning: %s" % w, file=err)
                    routes.append((name, text))
                origin = "--script arguments"
            else:
                manifest = load_manifest(args.manifest)
                for name in args.route or list(manifest.routes):
                    if name in (n for n, _ in routes):
                        raise Error("--route: %s given twice" % name)
                    path, frames = manifest_route(manifest, name)
                    text, warnings = convert_script(path, frames, label=os.path.basename(path))
                    for w in warnings:
                        print("warning: %s" % w, file=err)
                    routes.append((name, text))
                origin = os.path.relpath(os.path.abspath(args.manifest), REPO_ROOT)
            write_if_changed(args.embed, cpp_source(routes, origin))
            print("%s: %d replays (%s)" % (args.embed, len(routes), ", ".join(n for n, _ in routes)),
                  file=err)
            return 0

        if args.pairs:
            raise Error("--script goes with --embed")
        if args.route:
            if args.script or len(args.route) != 1 or args.frames is not None:
                raise Error("give one SCRIPT, or one --route (which sets the script and --frames)")
            path, frames = manifest_route(load_manifest(args.manifest), args.route[0])
        elif args.script:
            path, frames = args.script, args.frames
            if frames is not None and frames < 0:
                raise Error("--frames must not be negative")
        else:
            raise Error("give a SCRIPT, --route, --embed or --check (see --help)")
        text, warnings = convert_script(path, frames, args.offset)
        for w in warnings:
            print("warning: %s" % w, file=err)
        if args.output:
            write_if_changed(args.output, text)
        else:
            out.write(text)
        return 0
    except Error as e:
        print("script2replay.py: %s" % e, file=err)
        return 1


if __name__ == "__main__":
    sys.exit(main())
