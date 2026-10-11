#!/usr/bin/env python3
"""Route manifest tools (stdlib only; run with python3 -I).

usage: routes.py [--manifest FILE] COMMAND ...

  list                         route names, in manifest order
  plan [ROUTE...]              the routes to run for ROUTE... (default: all),
                               with the routes whose saves they start from,
                               in manifest order
  validate                     check the manifest; exit 1 on the first error
  get ROUTE KEY                print one route setting (script, frames,
                               start_save, sram, save_sha1); empty if unset
  trace-mem                    the harness --trace-mem list for every memory
                               field (ADDR:SIZE,...)
  check ROUTE TRACE [--exact]  check the route's checkpoints on a per-frame
                               trace (TSV); exit 1 if the run does not follow
                               the route

The manifest (default: routes.toml next to this file) is described at its top.
A trace is a TSV file with a header row, a "frame" column, and one column per
field: an I/O field under its register name (DISPCNT), a memory field as
mem_AAAAAAAA (the address in 8 upper-case hex digits), values in hex without
"0x". That is what the harness writes to trace.tsv with --trace-mem; capture
files of other engines use the same column names. Each row holds the state
at the start of VBlank of that frame (tools/analysis/README.md, "Frame
numbering").

A run follows a route when every checkpoint event occurs, in manifest order,
before the input that relies on it. Event i is the first frame, at or after
event i-1's frame, whose row satisfies the checkpoint's "when" predicate; it
must come before frame "before" (the frame of the first later input that
relies on it, or the end of the route when "before" is not set).

--exact is for the harness run the manifest was recorded from: each event
must also occur on its recorded mGBA frame, each "expect" value must match,
and each "before" frame must be a frame where the keys change (the "keys"
column). Without --exact, frame offsets and "expect" differences are
reported but do not fail the check: they are results to compare with mGBA,
not route following.
"""
import argparse
import os
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("routes.py needs Python 3.11 or newer (tomllib); this is %s" % sys.version.split()[0])

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MANIFEST = os.path.join(HERE, "routes.toml")

OPS = {
    "==": lambda a, b: a == b,
    "!=": lambda a, b: a != b,
    ">=": lambda a, b: a >= b,
    "<=": lambda a, b: a <= b,
    ">": lambda a, b: a > b,
    "<": lambda a, b: a < b,
}
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
INT_RE = re.compile(r"^(0[xX][0-9A-Fa-f]+|[0-9]+)$")
CLAUSE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(==|!=|>=|<=|>|<)\s*(\S+)\s*$")
ROUTE_KEYS = {"script", "frames", "start_save", "sram", "save_sha1", "note", "checkpoints"}
CHECKPOINT_KEYS = {"event", "when", "frame", "before", "expect", "note"}
FIELD_KEYS = {"io", "addr", "size", "note"}


class ManifestError(Exception):
    pass


class Field:
    def __init__(self, name, spec):
        unknown = set(spec) - FIELD_KEYS
        if unknown:
            raise ManifestError("field %s: unknown keys %s" % (name, sorted(unknown)))
        if not spec.get("note"):
            raise ManifestError("field %s: a note with its evidence is required" % name)
        self.name = name
        if "io" in spec:
            if "addr" in spec:
                raise ManifestError("field %s: set io or addr, not both" % name)
            self.column = spec["io"]
            self.addr = None
            self.size = None
        elif "addr" in spec:
            self.addr = spec["addr"]
            self.size = spec.get("size", 4)
            if self.size not in (1, 2, 4):
                raise ManifestError("field %s: size must be 1, 2 or 4" % name)
            self.column = "mem_%08X" % self.addr
        else:
            raise ManifestError("field %s: io or addr is required" % name)


class Clause:
    def __init__(self, field, op, value, text):
        self.field, self.op, self.value, self.text = field, op, value, text

    def holds(self, row):
        return OPS[self.op](row[self.field], self.value)


def parse_int(text, values, where):
    if INT_RE.match(text):
        return int(text, 0)
    if NAME_RE.match(text) and text in values:
        return values[text]
    raise ManifestError("%s: %r is neither a number nor a name in [values]" % (where, text))


def parse_when(text, fields, values, where):
    """'FIELD OP VALUE and FIELD OP VALUE ...' -> list of Clause."""
    clauses = []
    for part in re.split(r"\band\b", text):
        m = CLAUSE_RE.match(part)
        if not m:
            raise ManifestError("%s: cannot parse %r (expected FIELD OP VALUE, joined with 'and')"
                                % (where, part.strip()))
        name, op, value = m.groups()
        if name not in fields:
            raise ManifestError("%s: unknown field %r" % (where, name))
        clauses.append(Clause(name, op, parse_int(value, values, where), part.strip()))
    return clauses


class Checkpoint:
    def __init__(self, route, index, spec, fields, values):
        where = "route %s, checkpoint %d" % (route, index + 1)
        unknown = set(spec) - CHECKPOINT_KEYS
        if unknown:
            raise ManifestError("%s: unknown keys %s" % (where, sorted(unknown)))
        for key in ("event", "when", "frame"):
            if key not in spec:
                raise ManifestError("%s: %s is required" % (where, key))
        self.event = spec["event"]
        self.where = "%s (%s)" % (where, self.event)
        self.when_text = spec["when"]
        self.when = parse_when(spec["when"], fields, values, self.where)
        self.frame = spec["frame"]
        self.before = spec.get("before")
        for key in ("frame", "before"):
            value = getattr(self, key)
            if value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 1):
                raise ManifestError("%s: %s must be a frame number" % (self.where, key))
        self.expect = {}
        for name, value in spec.get("expect", {}).items():
            if name not in fields:
                raise ManifestError("%s: expect names unknown field %r" % (self.where, name))
            self.expect[name] = value if isinstance(value, int) else parse_int(value, values, self.where)
        if self.before is not None and self.before <= self.frame:
            raise ManifestError("%s: before (%d) must be after frame (%d)" % (self.where, self.before, self.frame))

    def holds(self, row):
        return all(c.holds(row) for c in self.when)

    def fields_used(self):
        return {c.field for c in self.when} | set(self.expect)


class Route:
    def __init__(self, name, spec, fields, values, route_names):
        unknown = set(spec) - ROUTE_KEYS
        if unknown:
            raise ManifestError("route %s: unknown keys %s" % (name, sorted(unknown)))
        for key in ("script", "frames"):
            if key not in spec:
                raise ManifestError("route %s: %s is required" % (name, key))
        self.name = name
        self.script = spec["script"]
        self.frames = spec["frames"]
        if not isinstance(self.frames, int) or isinstance(self.frames, bool) or self.frames < 1:
            raise ManifestError("route %s: frames must be a frame count" % name)
        self.start_save = spec.get("start_save", "")
        self.sram = spec.get("sram", "")
        self.save_sha1 = spec.get("save_sha1", "")
        if self.start_save and self.start_save not in route_names:
            raise ManifestError("route %s: start_save names unknown route %r" % (name, self.start_save))
        if self.start_save == name:
            raise ManifestError("route %s: start_save cannot name the route itself" % name)
        if self.sram not in ("", "none", "written"):
            raise ManifestError("route %s: sram must be 'none' or 'written'" % name)
        if self.save_sha1 and not re.match(r"^[0-9a-f]{40}$", self.save_sha1):
            raise ManifestError("route %s: save_sha1 must be 40 lower-case hex digits" % name)
        self.checkpoints = [Checkpoint(name, i, c, fields, values)
                            for i, c in enumerate(spec.get("checkpoints", []))]
        if not self.checkpoints:
            raise ManifestError("route %s: at least one checkpoint is required" % name)
        last = 0
        for cp in self.checkpoints:
            if cp.frame < last:
                raise ManifestError("%s: frame %d is before the previous checkpoint's %d"
                                    % (cp.where, cp.frame, last))
            if cp.frame > self.frames or (cp.before is not None and cp.before > self.frames):
                raise ManifestError("%s: past the end of the route (%d frames)" % (cp.where, self.frames))
            last = cp.frame

    def deadline(self, cp):
        """First frame by which the event is too late."""
        return cp.before if cp.before is not None else self.frames + 1


class Manifest:
    def __init__(self, path):
        self.path = path
        try:
            with open(path, "rb") as f:
                data = tomllib.load(f)
        except (OSError, tomllib.TOMLDecodeError) as e:
            raise ManifestError("%s: %s" % (path, e))
        if data.get("schema") != 1:
            raise ManifestError("%s: schema = 1 expected" % path)
        self.values = data.get("values", {})
        for name, value in self.values.items():
            if not isinstance(value, int):
                raise ManifestError("values.%s: must be an integer" % name)
        self.fields = {name: Field(name, spec) for name, spec in data.get("fields", {}).items()}
        routes = data.get("routes", {})
        self.routes = {name: Route(name, spec, self.fields, self.values, set(routes))
                       for name, spec in routes.items()}
        mem = [f for f in self.fields.values() if f.addr is not None]
        if len(mem) > 32:
            raise ManifestError("at most 32 memory fields (the harness's --trace-mem limit)")
        # A starting save must come from a route listed earlier, so a runner
        # that goes through the routes in order has it already.
        order = list(self.routes)
        for name, r in self.routes.items():
            if r.start_save and order.index(r.start_save) > order.index(name):
                raise ManifestError("route %s: start_save route %s must be listed before it"
                                    % (name, r.start_save))
            if r.start_save and self.routes[r.start_save].sram != "written":
                raise ManifestError("route %s: start_save route %s writes no save (sram = 'written')"
                                    % (name, r.start_save))

    def route(self, name):
        if name not in self.routes:
            raise ManifestError("unknown route %r (known: %s)" % (name, ", ".join(self.routes)))
        return self.routes[name]

    def plan(self, names):
        """names (default: all) plus their start_save routes, in manifest order."""
        wanted = set()
        for name in names or list(self.routes):
            r = self.route(name)
            wanted.add(r.name)
            while r.start_save:
                r = self.routes[r.start_save]
                wanted.add(r.name)
        return [n for n in self.routes if n in wanted]

    def trace_mem(self):
        return ",".join("0x%08X:%d" % (f.addr, f.size) for f in self.fields.values() if f.addr is not None)


def read_trace(path, fields, needed):
    """Rows as dicts {frame, keys, <field>: int}, in file order."""
    with open(path, newline="") as f:
        header = f.readline().rstrip("\r\n").split("\t")
        if "frame" not in header:
            raise ManifestError("%s: no 'frame' column" % path)
        cols = {}
        for name in sorted(needed):
            col = fields[name].column
            if col not in header:
                raise ManifestError("%s: no column %s for field %s" % (path, col, name))
            cols[name] = header.index(col)
        i_frame = header.index("frame")
        i_keys = header.index("keys") if "keys" in header else None
        rows = []
        for n, line in enumerate(f, 2):
            parts = line.rstrip("\r\n").split("\t")
            if len(parts) != len(header):
                raise ManifestError("%s:%d: %d columns, header has %d" % (path, n, len(parts), len(header)))
            row = {"frame": int(parts[i_frame]), "keys": parts[i_keys] if i_keys is not None else None}
            for name, i in cols.items():
                row[name] = int(parts[i], 16)
            rows.append(row)
    for a, b in zip(rows, rows[1:]):
        if b["frame"] != a["frame"] + 1:
            raise ManifestError("%s: frames are not consecutive (%d then %d)" % (path, a["frame"], b["frame"]))
    return rows


def check(route, rows, exact=False, out=None):
    """Check a route's checkpoints on trace rows. Returns the number of failures."""
    out = out or sys.stdout
    failures = 0
    by_frame = {r["frame"]: r for r in rows}
    start = rows[0]["frame"] if rows else 0
    print("route %s: %d checkpoints, trace frames %d-%d%s" % (
        route.name, len(route.checkpoints), start, rows[-1]["frame"] if rows else 0,
        " (exact)" if exact else ""), file=out)
    i = 0  # index of the previous event's row: events may share a frame
    for cp in route.checkpoints:
        deadline = route.deadline(cp)
        found = None
        while i < len(rows):
            if cp.holds(rows[i]):
                found = rows[i]
                break
            i += 1
        label = "%-28s" % cp.event
        if found is None:
            print("FAIL %s never occurs after frame %d (%s)" % (label, start, cp.when_text), file=out)
            return failures + 1  # later events are searched from this one: stop here
        f = found["frame"]
        delta = f - cp.frame
        status = "ok  "
        notes = []
        if f >= deadline:
            status = "FAIL"
            notes.append("at or after frame %d, %s" % (
                deadline, "the input that relies on it" if cp.before is not None else "the end of the route"))
        elif exact and delta != 0:
            status = "FAIL"
            notes.append("manifest says mGBA frame %d" % cp.frame)
        if exact and cp.before is not None:
            prev, cur = by_frame.get(cp.before - 1), by_frame.get(cp.before)
            if prev is None or cur is None or prev["keys"] is None:
                status = "FAIL"
                notes.append("cannot check that keys change at frame %d" % cp.before)
            elif prev["keys"] == cur["keys"]:
                status = "FAIL"
                notes.append("keys do not change at frame %d (before)" % cp.before)
        for name, want in sorted(cp.expect.items()):
            got = found[name]
            if got != want:
                notes.append("%s = %d, mGBA %d" % (name, got, want))
                if exact:
                    status = "FAIL"
        if status == "FAIL":
            failures += 1
        print("%s %s frame %6d (mGBA %6d, %+d; slack %d)%s" % (
            status, label, f, cp.frame, delta, deadline - 1 - f,
            ": " + "; ".join(notes) if notes else ""), file=out)
        start = f
    return failures


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    p = sub.add_parser("plan")
    p.add_argument("routes", nargs="*")
    sub.add_parser("validate")
    p = sub.add_parser("get")
    p.add_argument("route")
    p.add_argument("key", choices=["script", "frames", "start_save", "sram", "save_sha1"])
    sub.add_parser("trace-mem")
    p = sub.add_parser("check")
    p.add_argument("route")
    p.add_argument("trace")
    p.add_argument("--exact", action="store_true")
    args = ap.parse_args(argv)
    try:
        m = Manifest(args.manifest)
        if args.cmd == "list":
            print("\n".join(m.routes))
        elif args.cmd == "plan":
            print("\n".join(m.plan(args.routes)))
        elif args.cmd == "validate":
            print("%s: %d fields, %d routes, %d checkpoints" % (
                args.manifest, len(m.fields), len(m.routes),
                sum(len(r.checkpoints) for r in m.routes.values())))
        elif args.cmd == "get":
            print(getattr(m.route(args.route), args.key))
        elif args.cmd == "trace-mem":
            print(m.trace_mem())
        elif args.cmd == "check":
            route = m.route(args.route)
            needed = set().union(*(cp.fields_used() for cp in route.checkpoints))
            rows = read_trace(args.trace, m.fields, needed)
            failures = check(route, rows, exact=args.exact)
            print("route %s: %s" % (route.name, "follows" if not failures else "%d checkpoint(s) failed" % failures))
            return 1 if failures else 0
    except ManifestError as e:
        print("routes.py: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
