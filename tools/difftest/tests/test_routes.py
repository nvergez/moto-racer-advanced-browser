"""Unit tests for tools/difftest/routes.py on synthetic data (no game data).

Run: python3 -I -m unittest discover tools/difftest/tests
"""
import io
import os
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import routes  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

ROM_SHA1 = "1" * 40
BIOS_SHA1 = "2" * 40

MANIFEST = """\
schema = 1
rom_sha1 = "1111111111111111111111111111111111111111"
bios_sha1 = "2222222222222222222222222222222222222222"

[values]
ON = 0x1741
IMG_B = 0xB

[fields.DISPCNT]
io = "DISPCNT"
note = "test"

[fields.image]
addr = 0x03000000
size = 4
note = "test"

[fields.count]
addr = 0x0203FC50
size = 1
note = "test"

[routes.first]
script = "first.txt"
frames = 10
sram = "written"

[[routes.first.checkpoints]]
event = "image_b"
when = "image == IMG_B"
frame = 3
before = 6

[[routes.first.checkpoints]]
event = "display"
when = "DISPCNT == ON and image == IMG_B"
frame = 4
before = 6

[[routes.first.checkpoints]]
event = "counted"
when = "count >= 2"
frame = 8
expect = { count = 2 }

[routes.second]
script = "second.txt"
frames = 10
start_save = "first"
sram = "none"

[[routes.second.checkpoints]]
event = "image_b"
when = "image != 0"
frame = 3
"""

# frame, keys, DISPCNT, mem_03000000, mem_0203FC50
GOOD = [
    (1, "000", "0000", "0000000A", "00"),
    (2, "000", "0000", "0000000A", "00"),
    (3, "000", "0000", "0000000B", "00"),
    (4, "000", "1741", "0000000B", "00"),
    (5, "000", "1741", "0000000B", "01"),
    (6, "001", "1741", "0000000B", "01"),
    (7, "001", "1741", "0000000B", "01"),
    (8, "001", "0000", "0000000A", "02"),
    (9, "000", "0000", "0000000A", "02"),
    (10, "000", "0000", "0000000A", "02"),
]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, text):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def manifest(self, text=MANIFEST):
        return routes.Manifest(self.write("routes.toml", text))

    def trace(self, rows, header="frame\tkeys\tDISPCNT\tmem_03000000\tmem_0203FC50"):
        text = header + "\n" + "".join("\t".join(str(c) for c in r) + "\n" for r in rows)
        return self.write("trace.tsv", text)

    def run_check(self, rows, route="first", exact=False, text=MANIFEST):
        m = self.manifest(text)
        r = m.route(route)
        needed = set().union(*(cp.fields_used() for cp in r.checkpoints))
        data = routes.read_trace(self.trace(rows), m.fields, needed)
        out = io.StringIO()
        failures = routes.check(r, data, exact=exact, out=out)
        return failures, out.getvalue()


class ManifestTests(Base):
    def test_loads(self):
        m = self.manifest()
        self.assertEqual(list(m.routes), ["first", "second"])
        self.assertEqual(m.trace_mem(), "0x03000000:4,0x0203FC50:1")
        self.assertEqual(m.fields["count"].column, "mem_0203FC50")
        cp = m.routes["first"].checkpoints[1]
        self.assertEqual([c.text for c in cp.when], ["DISPCNT == ON", "image == IMG_B"])
        self.assertEqual(cp.when[0].value, 0x1741)

    def test_plan_adds_start_save_routes_in_order(self):
        m = self.manifest()
        self.assertEqual(m.plan(["second"]), ["first", "second"])
        self.assertEqual(m.plan([]), ["first", "second"])
        self.assertEqual(m.plan(["first"]), ["first"])

    def bad(self, old, new, message):
        self.assertIn(old, MANIFEST)
        with self.assertRaises(routes.ManifestError) as ctx:
            self.manifest(MANIFEST.replace(old, new, 1))
        self.assertIn(message, str(ctx.exception))

    def test_unknown_field(self):
        self.bad('when = "image == IMG_B"', 'when = "imge == IMG_B"', "unknown field")

    def test_unknown_value_name(self):
        self.bad('when = "image == IMG_B"', 'when = "image == IMG_C"', "neither a number")

    def test_bad_clause(self):
        self.bad('when = "image == IMG_B"', 'when = "image = IMG_B"', "cannot parse")

    def test_before_not_after_frame(self):
        self.bad("frame = 3\nbefore = 6", "frame = 3\nbefore = 3", "must be after frame")

    def test_frames_out_of_order(self):
        self.bad("frame = 8\n", "frame = 2\n", "before the previous checkpoint")

    def test_field_needs_note(self):
        self.bad('size = 1\nnote = "test"', "size = 1", "a note with its evidence")

    def test_start_save_must_write(self):
        self.bad('sram = "written"', 'sram = "none"', "writes no save")

    def test_start_save_unknown_route(self):
        self.bad('start_save = "first"', 'start_save = "third"', "unknown route")

    def test_unknown_route_key(self):
        self.bad('script = "first.txt"', 'script = "first.txt"\nscirpt = "x"', "unknown keys")

    def test_route_name_must_be_an_identifier(self):
        # mgba-routes.sh splits the route list on whitespace.
        self.bad("[routes.second]", '[routes."my route"]', "route name 'my route'")

    def test_field_and_value_names_must_be_identifiers(self):
        self.bad("[fields.count]", '[fields."count-1"]', "field name 'count-1'")
        self.bad("IMG_B = 0xB", '"IMG-B" = 0xB', "value name 'IMG-B'")

    def test_two_fields_on_one_column(self):
        self.bad("addr = 0x0203FC50\nsize = 1", "addr = 0x03000000\nsize = 1",
                 "fields image and count both read trace column mem_03000000")
        self.bad('io = "DISPCNT"\nnote', 'io = "DISPCNT"\nnote = "x"\n[fields.d2]\nio = "DISPCNT"\nnote',
                 "both read trace column DISPCNT")

    def test_field_types(self):
        self.bad("addr = 0x0203FC50", 'addr = "0x0203FC50"', "addr must be a 32-bit address")
        self.bad("addr = 0x0203FC50", "addr = 0x1_0000_0000", "addr must be a 32-bit address")
        self.bad("size = 1", "size = true", "size must be 1, 2 or 4")
        self.bad('io = "DISPCNT"', "io = 4", "io must be a string")
        self.bad('io = "DISPCNT"', 'io = "keys"', "io must name a register column")
        self.bad('io = "DISPCNT"', 'io = "DISPCNT"\nsize = 2', "not both")

    def test_checkpoint_and_route_types(self):
        self.bad("expect = { count = 2 }", "expect = { count = 2.0 }", "neither a number nor a name")
        self.bad("expect = { count = 2 }", "expect = 2", "expect: must be a table")
        self.bad('when = "image == IMG_B"', "when = 3", "when must be a string")
        self.bad('event = "image_b"\nwhen = "image == IMG_B"', 'event = 7\nwhen = "image == IMG_B"',
                 "event must be a string")
        self.bad('script = "first.txt"', "script = 1", "script must be a string")
        self.bad('sram = "none"', "sram = 0", "sram must be a string")
        self.bad("ON = 0x1741", "ON = true", "values.ON: must be an integer")

    def test_pins_are_required(self):
        self.bad('rom_sha1 = "' + ROM_SHA1 + '"\n', "", "rom_sha1 (40 lower-case hex digits) is required")
        self.bad('bios_sha1 = "' + BIOS_SHA1 + '"', 'bios_sha1 = "' + "A" * 40 + '"', "bios_sha1")

    def test_pins_compared_with_lib_sh(self):
        m = self.manifest()
        lib = self.write("lib.sh", "MRA_ROM_SHA1=%s\nMRA_BIOS_SHA1=%s\n" % (ROM_SHA1, BIOS_SHA1))
        m.check_pins(lib)
        lib = self.write("lib.sh", "MRA_ROM_SHA1=%s\nMRA_BIOS_SHA1=%s\n" % (ROM_SHA1, "3" * 40))
        with self.assertRaises(routes.ManifestError) as ctx:
            m.check_pins(lib)
        self.assertIn("bios_sha1", str(ctx.exception))
        lib = self.write("lib.sh", "MRA_BIOS_SHA1=%s\n" % BIOS_SHA1)
        with self.assertRaises(routes.ManifestError) as ctx:
            m.check_pins(lib)
        self.assertIn("no MRA_ROM_SHA1", str(ctx.exception))

    def test_check_scripts(self):
        m = self.manifest()
        with self.assertRaises(routes.ManifestError) as ctx:
            m.check_scripts(self.tmp.name)
        self.assertIn("script first.txt not found", str(ctx.exception))
        self.write("first.txt", "end\n")
        self.write("second.txt", "end\n")
        m.check_scripts(self.tmp.name)

    def test_real_manifest_is_valid(self):
        m = routes.Manifest(routes.DEFAULT_MANIFEST)
        self.assertGreater(len(m.routes), 0)
        m.check_pins()
        m.check_scripts()
        for r in m.routes.values():
            self.assertTrue(r.script.startswith("tools/analysis/input/"), r.script)
            self.assertTrue(os.path.isfile(os.path.join(REPO_ROOT, r.script)), r.script)


class CheckTests(Base):
    def test_follows(self):
        failures, out = self.run_check(GOOD)
        self.assertEqual(failures, 0, out)
        self.assertIn("frame      3 (mGBA      3, +0; slack 2)", out)

    def test_follows_exact(self):
        failures, out = self.run_check(GOOD, exact=True)
        self.assertEqual(failures, 0, out)

    def test_late_event_fails(self):
        rows = [list(r) for r in GOOD]
        for r in rows[2:5]:  # image B only from frame 6, the input frame
            r[3] = "0000000A"
        failures, out = self.run_check(rows)
        self.assertGreater(failures, 0)
        self.assertIn("the input that relies on it", out)

    def test_missing_event_fails_and_stops(self):
        rows = [list(r) for r in GOOD]
        for r in rows:
            r[2] = "0000"
        failures, out = self.run_check(rows)
        self.assertEqual(failures, 1)
        self.assertIn("display", out)
        self.assertIn("never occurs", out)
        self.assertNotIn("counted", out)

    def test_events_are_ordered(self):
        # "counted" holds on frame 2 only, before "display" (frame 4): it must
        # not be matched there, and never holds again, so the route fails.
        rows = [list(r) for r in GOOD]
        for r in rows:
            r[4] = "00"
        rows[1][4] = "02"
        failures, out = self.run_check(rows)
        self.assertEqual(failures, 1)
        self.assertIn("counted", out)

    def test_same_frame_events_allowed(self):
        rows = [list(r) for r in GOOD]
        rows[2][2] = "1741"  # display on frame 3, with image B
        failures, out = self.run_check(rows)
        self.assertEqual(failures, 0, out)

    def test_frame_offset_is_reported_not_failed(self):
        rows = [list(r) for r in GOOD]
        rows[2][3] = "0000000A"  # image B one frame later
        failures, out = self.run_check(rows)
        self.assertEqual(failures, 0, out)
        self.assertIn("+1", out)
        failures, out = self.run_check(rows, exact=True)
        self.assertEqual(failures, 1)
        self.assertIn("manifest says mGBA frame 3", out)

    def test_expect_is_a_result_not_route_following(self):
        rows = [list(r) for r in GOOD]
        for r in rows[7:]:
            r[4] = "03"  # 3 instead of mGBA's 2
        failures, out = self.run_check(rows)
        self.assertEqual(failures, 0, out)
        self.assertIn("count = 3, mGBA 2", out)
        failures, out = self.run_check(rows, exact=True)
        self.assertEqual(failures, 1)

    def test_exact_checks_that_keys_change_at_before(self):
        rows = [list(r) for r in GOOD]
        rows[5][1] = "000"  # keys now change at frame 7, not 6
        failures, out = self.run_check(rows, exact=True)
        self.assertEqual(failures, 2)
        self.assertIn("keys do not change at frame 6", out)

    def test_deadline_without_before_is_the_end_of_the_route(self):
        rows = [list(r) for r in GOOD]
        for r in rows:
            r[4] = "02" if r[0] == 10 else "00"
        failures, out = self.run_check(rows)
        self.assertEqual(failures, 0, out)  # frame 10 is the route's last frame
        text = MANIFEST.replace('frames = 10\nsram = "written"', 'frames = 9\nsram = "written"', 1)
        failures, out = self.run_check(rows, text=text)
        self.assertEqual(failures, 1)
        self.assertIn("the end of the route", out)
        text = MANIFEST.replace("frame = 8\nexpect", "frame = 8\nbefore = 10\nexpect", 1)
        failures, out = self.run_check(rows, text=text)
        self.assertEqual(failures, 1)
        self.assertIn("the input that relies on it", out)


class TraceTests(Base):
    def test_missing_column(self):
        m = self.manifest()
        path = self.trace([r[:4] for r in GOOD], header="frame\tkeys\tDISPCNT\tmem_03000000")
        with self.assertRaises(routes.ManifestError) as ctx:
            routes.read_trace(path, m.fields, {"count"})
        self.assertIn("mem_0203FC50", str(ctx.exception))

    def test_frames_must_be_consecutive(self):
        m = self.manifest()
        path = self.trace([GOOD[0], GOOD[2]])
        with self.assertRaises(routes.ManifestError):
            routes.read_trace(path, m.fields, {"image"})

    def read_error(self, path, needed=("image",)):
        m = self.manifest()
        with self.assertRaises(routes.ManifestError) as ctx:
            routes.read_trace(path, m.fields, set(needed))
        return str(ctx.exception)

    def test_missing_file(self):
        self.assertIn("No such file", self.read_error(os.path.join(self.tmp.name, "none.tsv")))

    def test_bad_cells(self):
        rows = [list(r) for r in GOOD]
        rows[3][3] = "zz"
        self.assertIn(":5: column mem_03000000: 'zz' is not a hex number", self.read_error(self.trace(rows)))
        rows = [list(r) for r in GOOD]
        rows[0][0] = "one"
        self.assertIn(":2: column frame: 'one' is not a decimal number", self.read_error(self.trace(rows)))

    def test_duplicate_column(self):
        path = self.trace([r + ("00",) for r in GOOD],
                          header="frame\tkeys\tDISPCNT\tmem_03000000\tmem_0203FC50\tmem_03000000")
        self.assertIn("column mem_03000000 appears 2 times", self.read_error(path))

    def test_binary_file(self):
        path = os.path.join(self.tmp.name, "bin.tsv")
        with open(path, "wb") as f:
            f.write(b"frame\tmem_03000000\n\xff\xfe\n")
        self.assertIn("not a text file", self.read_error(path))

    def test_cli_reports_errors_without_traceback(self):
        mpath = self.write("routes.toml", MANIFEST)
        err = io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            rc = routes.main(["--manifest", mpath, "check", "first", os.path.join(self.tmp.name, "none.tsv")])
        finally:
            sys.stderr = old
        self.assertEqual(rc, 1)
        self.assertTrue(err.getvalue().startswith("routes.py: "), err.getvalue())

    def test_cli_check(self):
        mpath = self.write("routes.toml", MANIFEST)
        tpath = self.trace(GOOD)
        out = io.StringIO()
        old = sys.stdout
        sys.stdout = out
        try:
            rc = routes.main(["--manifest", mpath, "check", "first", tpath, "--exact"])
        finally:
            sys.stdout = old
        self.assertEqual(rc, 0, out.getvalue())
        self.assertIn("route first: follows", out.getvalue())

    def test_cli_get_and_plan(self):
        mpath = self.write("routes.toml", textwrap.dedent(MANIFEST))
        for argv, want in ((["get", "second", "start_save"], "first"),
                           (["get", "first", "start_save"], ""),
                           (["plan", "second"], "first\nsecond")):
            out = io.StringIO()
            old = sys.stdout
            sys.stdout = out
            try:
                rc = routes.main(["--manifest", mpath] + argv)
            finally:
                sys.stdout = old
            self.assertEqual(rc, 0)
            self.assertEqual(out.getvalue().strip(), want)


if __name__ == "__main__":
    unittest.main()
