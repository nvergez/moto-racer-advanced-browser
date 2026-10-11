"""Unit tests for tools/difftest/compare.py on synthetic captures (no game data).

Run: python3 -I -m unittest discover tools/difftest/tests
"""
import array
import io
import json
import os
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import compare  # noqa: E402

COLUMNS = ["frame", "fb", "lines", "DISPCNT", "mem_03000000", "ram_ewram", "ram_stacks",
           "fifo_a_n", "fifo_a", "io_writes", "halt_writes", "cycles", "bridge_insns"]
LINE_COLS = ["frame", "line", "DISPCNT", "BLDCNT", "BLDALPHA", "BLDY", "PAL0", "OAM"]


def row(frame, **over):
    base = {"frame": str(frame), "fb": "F%07X" % frame, "lines": "L%07X" % frame, "DISPCNT": "0080",
            "mem_03000000": "E92D4FF3", "ram_ewram": "E%07X" % frame, "ram_stacks": "5%07X" % frame,
            "fifo_a_n": "0", "fifo_a": "00000000", "io_writes": "10", "halt_writes": "1",
            "cycles": str(280896 * frame), "bridge_insns": "0"}
    base.update({k: str(v) for k, v in over.items()})
    return base


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, name):
        return os.path.join(self.dir, name)

    def capture(self, name, rows, columns=COLUMNS):
        p = self.path(name)
        with open(p, "w") as f:
            f.write("\t".join(columns) + "\n")
            for r in rows:
                f.write("\t".join(r[c] for c in columns) + "\n")
        return p

    def text(self, name, body):
        p = self.path(name)
        with open(p, "w") as f:
            f.write(textwrap.dedent(body))
        return p

    def run_compare(self, *args):
        out = io.StringIO()
        err = io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            code = compare.main(list(args), out=out)
        finally:
            sys.stderr = old
        return code, out.getvalue(), err.getvalue()

    def exclusions(self, body="schema = 1\n"):
        return self.text("comparison1.toml", body)


class FrameListTest(unittest.TestCase):
    def test_parse_merge(self):
        self.assertEqual(compare.parse_frame_list("5, 1-3;4 10"), [(1, 5), (10, 10)])

    def test_bad(self):
        for bad in ("", "a", "5-3", "0"):
            with self.assertRaises(compare.CompareError):
                compare.parse_frame_list(bad)

    def test_format(self):
        self.assertEqual(compare.format_ranges(compare.to_ranges([1, 2, 3, 7])), "1-3,7")
        self.assertIn("more ranges", compare.format_ranges([(1, 1), (3, 3), (5, 5)], limit=2))

    def test_frame_map(self):
        m = compare.FrameMap("10-20:+1,30-40:~2,50:-3")
        self.assertEqual(m.rule(15), ("fixed", 1))
        self.assertEqual(m.rule(35), ("search", 2))
        self.assertEqual(m.rule(50), ("fixed", -3))
        self.assertEqual(m.rule(1), ("fixed", 0))
        self.assertEqual(m.reach(), 3)
        self.assertEqual(m.lowest(), -3)
        for bad in ("10-20", "10-20:x", "20-10:+1", "1-10:+1,5-15:+2", "1-10:~0"):
            with self.assertRaises(compare.CompareError):
                compare.FrameMap(bad)


class Comparison1Test(Base):
    def test_identical_passes(self):
        a = self.capture("a.tsv", [row(f) for f in range(1, 11)])
        b = self.capture("b.tsv", [row(f, cycles=280896 * f + 2, bridge_insns=99) for f in range(1, 11)])
        code, out, _ = self.run_compare(a, b, "--against", "interp", "--exclusions", self.exclusions())
        self.assertEqual(code, 0, out)
        self.assertIn("RESULT: PASS (10 frames compared)", out)
        self.assertIn("TEST - REF from +2 to +2 cycles", out)

    def test_fb_and_ram_gate_lines_do_not(self):
        rows_b = [row(f) for f in range(1, 11)]
        rows_b[3]["fb"] = "DEADBEEF"        # frame 4
        rows_b[6]["ram_ewram"] = "DEADBEEF"  # frame 7
        rows_b[8]["lines"] = "DEADBEEF"      # frame 9: reported only
        a = self.capture("a.tsv", [row(f) for f in range(1, 11)])
        b = self.capture("b.tsv", rows_b)
        code, out, _ = self.run_compare(a, b, "--against", "interp", "--exclusions", self.exclusions())
        self.assertEqual(code, 1)
        self.assertIn("RESULT: FAIL (2 frames fail a gated check: 4,7)", out)
        self.assertRegex(out, r"lines\s+10\s+1\s+9")

    def test_excluded_region(self):
        rows_b = [row(f) for f in range(1, 6)]
        rows_b[2]["ram_stacks"] = "DEADBEEF"
        a = self.capture("a.tsv", [row(f) for f in range(1, 6)])
        b = self.capture("b.tsv", rows_b)
        excl = self.exclusions('schema = 1\n[[exclude]]\nregion = "stacks"\ncause = "c"\nref = "r"\n')
        code, out, _ = self.run_compare(a, b, "--against", "interp", "--exclusions", excl)
        self.assertEqual(code, 0, out)
        self.assertIn("excluded regions", out)
        self.assertRegex(out, r"ram_stacks \(excluded\)\s+5\s+1")

    def test_exclusion_must_name_a_region(self):
        a = self.capture("a.tsv", [row(1)])
        excl = self.exclusions('schema = 1\n[[exclude]]\nregion = "nope"\ncause = "c"\nref = "r"\n')
        code, _, err = self.run_compare(a, a, "--against", "interp", "--exclusions", excl)
        self.assertEqual(code, 2)
        self.assertIn("region nope is not in the captures", err)

    def test_exclusion_needs_a_cause(self):
        a = self.capture("a.tsv", [row(1)])
        excl = self.exclusions('schema = 1\n[[exclude]]\nregion = "stacks"\nref = "r"\n')
        code, _, err = self.run_compare(a, a, "--against", "interp", "--exclusions", excl)
        self.assertEqual(code, 2)
        self.assertIn("cause must be a non-empty string", err)

    def test_no_allowlist(self):
        a = self.capture("a.tsv", [row(1)])
        allow = self.text("allow.toml", 'schema = 1\nroute = "r"\nagainst = "mgba"\n')
        code, _, err = self.run_compare(a, a, "--against", "interp", "--allowlist", allow)
        self.assertEqual(code, 2)
        self.assertIn("comparison 1 takes no allowlist", err)

    def test_committed_exclusions_parse(self):
        excl = compare.Exclusions(compare.DEFAULT_EXCLUSIONS)
        for name, e in excl.regions.items():
            self.assertTrue(e["cause"] and e["ref"], name)

    def test_raw_detail_first_pixel(self):
        rows_b = [row(f) for f in range(1, 4)]
        rows_b[1]["fb"] = "DEADBEEF"
        a = self.capture("a.tsv", [row(f) for f in range(1, 4)])
        b = self.capture("b.tsv", rows_b)
        ra, rb = self.raw_dirs()
        write_raw(ra, 2, {})
        write_raw(rb, 2, {(5, 7): 0x0001})
        code, out, _ = self.run_compare(a, b, "--against", "interp", "--exclusions", self.exclusions(),
                                        "--ref-raw", ra, "--test-raw", rb)
        self.assertEqual(code, 1)
        self.assertIn("first divergence: frame 2, fb: line 5 column 7: REF 0000 TEST 0001 (1 pixels differ", out)

    def raw_dirs(self):
        ra, rb = self.path("a.raw"), self.path("b.raw")
        os.mkdir(ra)
        os.mkdir(rb)
        return ra, rb


def write_raw(directory, frame, pixels):
    a = array.array("H", [0] * (compare.WIDTH * compare.HEIGHT))
    for (y, x), v in pixels.items():
        a[y * compare.WIDTH + x] = v
    if sys.byteorder != "little":
        a.byteswap()
    with open(os.path.join(directory, "f%06d.bgr555" % frame), "wb") as f:
        f.write(a.tobytes())


def write_lines(path, frames, override=None):
    """Line records for frames: no effect, except override {(frame, line): {col: value}}."""
    override = override or {}
    with open(path, "w") as f:
        f.write("\t".join(LINE_COLS) + "\n")
        for fr in frames:
            for line in range(160):
                v = {"DISPCNT": "0080", "BLDCNT": "0000", "BLDALPHA": "0000", "BLDY": "0000",
                     "PAL0": "0000", "OAM": "00000000"}
                v.update(override.get((fr, line), {}))
                f.write("\t".join([str(fr), str(line)] + [v[c] for c in LINE_COLS[2:]]) + "\n")


class Comparison2Test(Base):
    def allowlist(self, entries):
        body = 'schema = 1\nroute = "r"\nagainst = "mgba"\n' + entries
        return self.text("allow.toml", body)

    def test_layer1_fails_then_allowlisted(self):
        rows_b = [row(f) for f in range(1, 11)]
        rows_b[4]["lines"] = "DEADBEEF"  # frame 5
        a = self.capture("a.tsv", [row(f) for f in range(1, 11)])
        b = self.capture("b.tsv", rows_b)
        code, out, _ = self.run_compare(a, b, "--against", "mgba")
        self.assertEqual(code, 1)
        self.assertRegex(out, r"layer1\s+10\s+1\s+0\s+1\s+5")
        allow = self.allowlist('[[allow]]\nid = "t"\nframes = "5"\nchecks = ["layer1"]\ncause = "c"\nref = "r"\n'
                               '[[allow]]\nid = "spare"\nframes = "1-10"\nchecks = ["ram:stacks"]\ncause = "c"\n'
                               'ref = "r"\nfixed_by = "P2-99"\n')
        code, out, _ = self.run_compare(a, b, "--against", "mgba", "--allowlist", allow)
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r"t\s+layer1 1")
        self.assertRegex(out, r"spare\s+UNUSED\s+\(fixed by P2-99\)")

    def test_ram_star_and_region(self):
        rows_b = [row(f) for f in range(1, 6)]
        rows_b[1]["ram_ewram"] = "X"
        rows_b[2]["ram_stacks"] = "X"
        a = self.capture("a.tsv", [row(f) for f in range(1, 6)])
        b = self.capture("b.tsv", rows_b)
        allow = self.allowlist('[[allow]]\nid = "all"\nframes = "2-3"\nchecks = ["ram:*"]\ncause = "c"\nref = "r"\n')
        code, out, _ = self.run_compare(a, b, "--against", "mgba", "--allowlist", allow)
        self.assertEqual(code, 0, out)
        allow = self.allowlist('[[allow]]\nid = "one"\nframes = "2-3"\nchecks = ["ram:ewram"]\ncause = "c"\n'
                               'ref = "r"\n')
        code, out, _ = self.run_compare(a, b, "--against", "mgba", "--allowlist", allow)
        self.assertEqual(code, 1)
        self.assertRegex(out, r"ram:stacks\s+5\s+1\s+0\s+1\s+3")

    def test_allowlist_validation(self):
        a = self.capture("a.tsv", [row(1)])
        bad = [
            ('[[allow]]\nid = "x"\nframes = "1"\nchecks = ["layer3"]\ncause = "c"\nref = "r"\n', "layer1, layer2"),
            ('[[allow]]\nid = "x"\nframes = "1"\nchecks = ["layer1"]\nref = "r"\n', "cause"),
            ('[[allow]]\nid = "x"\nframes = "2-1"\nchecks = ["layer1"]\ncause = "c"\nref = "r"\n', "frame range"),
            ('[[allow]]\nid = "x"\nframes = "1"\nchecks = ["ram:nope"]\ncause = "c"\nref = "r"\n', "nope"),
            ('[[allow]]\nid = "x"\nframes = "1"\nchecks = ["layer1"]\ncause = "c"\nref = "r"\n'
             '[[allow]]\nid = "x"\nframes = "1"\nchecks = ["layer1"]\ncause = "c"\nref = "r"\n', "used twice"),
            ('[[allow]]\nid = "x"\nframes = "1"\nchecks = ["layer1"]\ncause = "c"\nref = "r"\nwhy = 1\n',
             "unknown keys"),
        ]
        for body, text in bad:
            code, _, err = self.run_compare(a, a, "--against", "mgba", "--allowlist", self.allowlist(body))
            self.assertEqual(code, 2, body)
            self.assertIn(text, err)

    def test_fb_without_raw_is_undetermined(self):
        rows_b = [row(f) for f in range(1, 4)]
        rows_b[1]["fb"] = "DEADBEEF"
        a = self.capture("a.tsv", [row(f) for f in range(1, 4)])
        b = self.capture("b.tsv", rows_b)
        code, out, _ = self.run_compare(a, b, "--against", "mgba")
        self.assertEqual(code, 1)
        self.assertIn("no raw frames for 1 whose fb differs (layer 2 undetermined): 2", out)

    def layer2_case(self, line_override, pixels):
        rows_b = [row(f) for f in range(1, 4)]
        rows_b[1]["fb"] = "DEADBEEF"
        a = self.capture("a.tsv", [row(f) for f in range(1, 4)])
        b = self.capture("b.tsv", rows_b)
        ra, rb = self.path("a.raw"), self.path("b.raw")
        os.makedirs(ra, exist_ok=True)
        os.makedirs(rb, exist_ok=True)
        write_raw(ra, 2, {(10, 0): 0x0421})  # r=g=b=1
        write_raw(rb, 2, pixels)
        la, lb = self.path("a.lines.tsv"), self.path("b.lines.tsv")
        write_lines(la, [2], line_override)
        write_lines(lb, [2], line_override)
        return self.run_compare(a, b, "--against", "mgba", "--ref-lines", la, "--test-lines", lb,
                                "--ref-raw", ra, "--test-raw", rb)

    def test_layer2_exact_without_effect(self):
        code, out, _ = self.layer2_case({}, {(10, 0): 0x0422})
        self.assertEqual(code, 1)
        self.assertIn("frame 2, layer2: line 10 column 0: REF 0421 TEST 0422", out)

    def test_layer2_one_step_on_brightness_line(self):
        brighten = {(2, 10): {"BLDCNT": "0081", "BLDY": "0004"}}
        code, out, _ = self.layer2_case(brighten, {(10, 0): 0x0842})  # each channel +1
        self.assertEqual(code, 0, out)
        self.assertIn("1 frames whose fb differs pass in detail", out)
        code, out, _ = self.layer2_case(brighten, {(10, 0): 0x0423})  # red +2
        self.assertEqual(code, 1)

    def test_layer2_brightness_needs_bldy(self):
        code, out, _ = self.layer2_case({(2, 10): {"BLDCNT": "0081", "BLDY": "0000"}}, {(10, 0): 0x0422})
        self.assertEqual(code, 1)

    def test_layer2_alpha_and_semi_transparent_obj(self):
        alpha = {(2, 10): {"BLDCNT": "0041", "BLDALPHA": "0808"}}
        self.assertEqual(self.layer2_case(alpha, {(10, 0): 0x0422})[0], 0)
        obj = {(2, 10): {"DISPCNT": "1080", "BLDCNT": "0200", "BLDALPHA": "0808"}}
        self.assertEqual(self.layer2_case(obj, {(10, 0): 0x0422})[0], 0)
        no_obj = {(2, 10): {"DISPCNT": "0080", "BLDCNT": "0200", "BLDALPHA": "0808"}}
        self.assertEqual(self.layer2_case(no_obj, {(10, 0): 0x0422})[0], 1)

    def test_layer1_detail(self):
        rows_b = [row(f) for f in range(1, 4)]
        rows_b[1]["lines"] = "DEADBEEF"
        a = self.capture("a.tsv", [row(f) for f in range(1, 4)])
        b = self.capture("b.tsv", rows_b)
        la, lb = self.path("a.lines.tsv"), self.path("b.lines.tsv")
        write_lines(la, [2])
        write_lines(lb, [2], {(2, 40): {"PAL0": "7FFF"}, (2, 41): {"PAL0": "7FFF"}})
        code, out, _ = self.run_compare(a, b, "--against", "mgba", "--ref-lines", la, "--test-lines", lb)
        self.assertEqual(code, 1)
        self.assertIn("first divergence: frame 2, layer1: line 40 PAL0: REF 0000 TEST 7FFF (2 lines differ)", out)
        self.assertIn("layer 1, frame 2: 2 lines (40-41), columns PAL0", out)

    def test_missing_frames_fail(self):
        a = self.capture("a.tsv", [row(f) for f in range(1, 11)])
        b = self.capture("b.tsv", [row(f) for f in range(1, 8)])
        code, out, _ = self.run_compare(a, b, "--against", "mgba")
        self.assertEqual(code, 1)
        self.assertIn("MISSING from TEST: 3 frames: 8-10", out)
        code, out, _ = self.run_compare(a, b, "--against", "mgba", "--frames", "1-7")
        self.assertEqual(code, 0, out)
        code, out, _ = self.run_compare(b, a, "--against", "mgba", "--frames", "1-10")
        self.assertEqual(code, 1)
        self.assertIn("MISSING from REF: 3 frames: 8-10", out)

    def test_fixed_frame_map(self):
        a = self.capture("a.tsv", [row(f) for f in range(1, 21)])
        # TEST is one frame late from frame 11 on.
        b_rows = [row(f) for f in range(1, 11)] + [dict(row(f - 1), frame=str(f)) for f in range(11, 22)]
        b = self.capture("b.tsv", b_rows)
        code, out, _ = self.run_compare(a, b, "--against", "mgba", "--frames", "1-20")
        self.assertEqual(code, 1)
        code, out, _ = self.run_compare(a, b, "--against", "mgba", "--frames", "1-20", "--frame-map", "11-20:+1")
        self.assertEqual(code, 0, out)

    def test_search_frame_map(self):
        a = self.capture("a.tsv", [row(f) for f in range(1, 21)])
        b_rows = [row(f) for f in range(1, 11)] + [dict(row(f - 1), frame=str(f)) for f in range(11, 22)]
        b = self.capture("b.tsv", b_rows)
        code, out, _ = self.run_compare(a, b, "--against", "mgba", "--frames", "1-20", "--frame-map", "5-20:~2")
        self.assertEqual(code, 0, out)
        self.assertIn("offsets chosen by the search: 5-10:+0,11-20:+1", out)

    def test_detail_out_priorities_and_cap(self):
        rows_b = [row(f) for f in range(1, 11)]
        for i in (1, 3, 5):
            rows_b[i]["lines"] = "X"
        a = self.capture("a.tsv", [row(f) for f in range(1, 11)])
        b = self.capture("b.tsv", rows_b)
        allow = self.allowlist('[[allow]]\nid = "t"\nframes = "2"\nchecks = ["layer1", "layer2"]\ncause = "c"\n'
                               'ref = "r"\n')
        detail = self.path("detail.tsv")
        self.run_compare(a, b, "--against", "mgba", "--allowlist", allow, "--detail-out", detail, "--max-detail", "2")
        with open(detail) as f:
            self.assertEqual(f.read(), "4\t4\tlines\n6\t6\tlines\n")

    def test_json_and_frame_report(self):
        rows_b = [row(f) for f in range(1, 4)]
        rows_b[2]["ram_ewram"] = "X"
        a = self.capture("a.tsv", [row(f) for f in range(1, 4)])
        b = self.capture("b.tsv", rows_b)
        js, fr = self.path("s.json"), self.path("frames.tsv")
        code, _, _ = self.run_compare(a, b, "--against", "mgba", "--json", js, "--frame-report", fr)
        self.assertEqual(code, 1)
        with open(js) as f:
            s = json.load(f)
        self.assertEqual(s["result"], "FAIL")
        self.assertEqual(s["checks"]["ram:ewram"]["failing_frames"], "3")
        with open(fr) as f:
            self.assertEqual(f.read().splitlines()[1], "3\tram:ewram\t3\tFAILS\t-\t-\t-")

    def test_columns_must_match(self):
        a = self.capture("a.tsv", [row(1)])
        b = self.capture("b.tsv", [row(1)], columns=[c for c in COLUMNS if c != "ram_stacks"])
        code, _, err = self.run_compare(a, b, "--against", "mgba")
        self.assertEqual(code, 2)
        self.assertIn("only in REF: ram_stacks", err)

    def test_frames_must_increase(self):
        a = self.capture("a.tsv", [row(2), row(1)])
        code, _, err = self.run_compare(a, a, "--against", "mgba")
        self.assertEqual(code, 2)
        self.assertIn("frames must increase", err)

    def test_line_state_off_refused(self):
        a = self.capture("a.tsv", [row(1, lines="-")])
        code, _, err = self.run_compare(a, a, "--against", "mgba")
        self.assertEqual(code, 2)
        self.assertIn("line state was not captured", err)

    def test_committed_allowlists_parse(self):
        d = os.path.join(HERE, "allowlists")
        names = sorted(n for n in os.listdir(d) if n.endswith(".toml"))
        self.assertTrue(names)
        routes_toml = open(os.path.join(HERE, "routes.toml")).read()
        for n in names:
            al = compare.Allowlist(os.path.join(d, n))
            self.assertEqual(al.route + ".toml", n)
            self.assertIn("[routes.%s]" % al.route, routes_toml)
            for e in al.entries:
                self.assertTrue(e["cause"].strip() and e["ref"].strip(), e["id"])


if __name__ == "__main__":
    unittest.main()
