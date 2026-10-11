"""Unit tests for tools/capture/capture.py on synthetic files (no game data).

Run with: python3 -I -m unittest discover tools/capture/tests
"""
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import capture  # noqa: E402

HEADER = "frame\tfb\tlines\tDISPCNT\tmem_03000000\tram_ewram\tcycles\tbridge_insns\n"


def row(frame, fb="AAAAAAAA", lines="BBBBBBBB", dispcnt="0080", image="E92D4FF3", ewram="CCCCCCCC",
        cycles=None, bridge="0"):
    cycles = cycles if cycles is not None else 280896 * frame
    return "%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n" % (frame, fb, lines, dispcnt, image, ewram, cycles, bridge)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, text):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def run_cmd(self, *argv):
        out = io.StringIO()
        err = io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            status = capture.main(list(argv), out=out)
        finally:
            sys.stderr = old
        return status, out.getvalue(), err.getvalue()


class JoinTest(Base):
    def test_equal_files(self):
        a = self.write("a.tsv", HEADER + row(1) + row(2) + row(3))
        b = self.write("b.tsv", HEADER + row(1, cycles=5) + row(2, bridge="-") + row(3))
        status, out, _ = self.run_cmd("join", a, b)
        self.assertEqual(status, 0, out)
        self.assertIn("compared 3 (1-3)", out)
        # cycles and bridge_insns differ, but are engine-specific: not compared.
        self.assertNotIn("cycles", out)
        self.assertRegex(out, r"fb\s+equal\s+3\s+differ\s+0")

    def test_differences_are_listed_as_ranges(self):
        a = self.write("a.tsv", HEADER + "".join(row(f) for f in range(1, 11)))
        b = self.write("b.tsv", HEADER + "".join(row(f, fb="DDDDDDDD" if f in (3, 4, 5, 9) else "AAAAAAAA")
                                                  for f in range(1, 11)))
        status, out, _ = self.run_cmd("join", a, b)
        self.assertEqual(status, 1)
        self.assertRegex(out, r"fb\s+equal\s+6\s+differ\s+4\s+3-5,9")

    def test_frames_option_and_partial_overlap(self):
        a = self.write("a.tsv", HEADER + "".join(row(f) for f in range(1, 6)))
        b = self.write("b.tsv", HEADER + "".join(row(f, fb="DDDDDDDD" if f == 5 else "AAAAAAAA")
                                                  for f in range(2, 7)))
        # Frame 1 is requested and missing from B: a failure, unless allowed.
        status, out, _ = self.run_cmd("join", a, b, "--frames", "1-4")
        self.assertEqual(status, 1, out)
        self.assertIn("A 5 (1-5), B 5 (2-6), compared 3 (2-4)", out)
        self.assertIn("frames missing from B: 1: 1\n", out)
        self.assertNotIn("missing from A", out)
        self.assertRegex(out, r"fb\s+equal\s+3\s+differ\s+0")
        status, out, _ = self.run_cmd("join", a, b, "--frames", "1-4", "--allow-missing")
        self.assertEqual(status, 0, out)
        self.assertIn("frames missing from B: 1: 1\n", out)
        status, out, _ = self.run_cmd("join", a, b, "--frames", "2-4")
        self.assertEqual(status, 0, out)
        # A requested frame in neither file is missing from both.
        status, out, _ = self.run_cmd("join", a, b, "--frames", "2-4;7-9")
        self.assertEqual(status, 1, out)
        self.assertIn("frames missing from A: 3: 7-9", out)
        self.assertIn("frames missing from B: 3: 7-9", out)

    def test_truncated_run_fails(self):
        a = self.write("a.tsv", HEADER + "".join(row(f) for f in range(1, 11)))
        b = self.write("b.tsv", HEADER + "".join(row(f) for f in range(1, 5)))
        status, out, _ = self.run_cmd("join", a, b)
        self.assertEqual(status, 1, out)
        self.assertIn("frames missing from B: 6: 5-10", out)
        self.assertIn("FAIL: frames or columns missing from one file", out)
        status, out, _ = self.run_cmd("join", b, a)
        self.assertEqual(status, 1, out)
        self.assertIn("frames missing from A: 6: 5-10", out)

    def test_one_frame_tail_is_allowed(self):
        # A --frames N run stops at N or N+1 depending on the backend.
        a = self.write("a.tsv", HEADER + "".join(row(f) for f in range(1, 6)))
        b = self.write("b.tsv", HEADER + "".join(row(f) for f in range(1, 7)))
        for x, y, only in ((a, b, "B"), (b, a, "A")):
            status, out, _ = self.run_cmd("join", x, y)
            self.assertEqual(status, 0, out)
            self.assertIn("frame 6: in %s only" % only, out)
            self.assertNotIn("missing", out)
        # Two frames more is not a tail.
        c = self.write("c.tsv", HEADER + "".join(row(f) for f in range(1, 8)))
        status, out, _ = self.run_cmd("join", a, c)
        self.assertEqual(status, 1, out)
        self.assertIn("frames missing from A: 2: 6-7", out)
        # Nor is a frame missing in the middle.
        d = self.write("d.tsv", HEADER + "".join(row(f) for f in (1, 2, 4, 5, 6)))
        status, out, _ = self.run_cmd("join", a, d)
        self.assertEqual(status, 1, out)
        self.assertIn("frames missing from B: 1: 3", out)

    def test_sparse_frame_lists(self):
        # Both engines captured the same sparse list: every frame is in both.
        a = self.write("a.tsv", HEADER + row(10) + row(20))
        b = self.write("b.tsv", HEADER + row(10) + row(20))
        status, out, _ = self.run_cmd("join", a, b)
        self.assertEqual(status, 0, out)
        full = self.write("full.tsv", HEADER + "".join(row(f) for f in range(1, 31)))
        status, out, _ = self.run_cmd("join", a, full)
        self.assertEqual(status, 1, out)
        status, out, _ = self.run_cmd("join", a, full, "--frames", "10,20")
        self.assertEqual(status, 0, out)

    def test_named_columns_include_engine_specific_ones(self):
        a = self.write("a.tsv", HEADER + row(1))
        b = self.write("b.tsv", HEADER + row(1, cycles=7))
        status, out, _ = self.run_cmd("join", a, b, "--columns", "cycles")
        self.assertEqual(status, 1)
        self.assertRegex(out, r"cycles\s+equal\s+0\s+differ\s+1\s+1")

    def test_columns_in_one_file_only(self):
        a = self.write("a.tsv", HEADER + row(1))
        hb = HEADER.replace("\tram_ewram", "\tram_iwram")
        b = self.write("b.tsv", hb + row(1))
        status, out, _ = self.run_cmd("join", a, b)
        self.assertEqual(status, 1, out)
        self.assertIn("columns in one file only: ram_ewram (A), ram_iwram (B)", out)
        status, out, _ = self.run_cmd("join", a, b, "--allow-missing")
        self.assertEqual(status, 0, out)
        # A run without the spec has no ram_* columns at all.
        hc = HEADER.replace("\tram_ewram", "")
        c = self.write("c.tsv", hc + "".join(r.replace("\tCCCCCCCC", "") for r in [row(1)]))
        status, out, _ = self.run_cmd("join", a, c)
        self.assertEqual(status, 1, out)
        self.assertIn("columns in one file only: ram_ewram (A)", out)
        # Columns named with --columns are the only ones that must be in both.
        status, out, _ = self.run_cmd("join", a, b, "--columns", "fb,DISPCNT")
        self.assertEqual(status, 0, out)
        self.assertIn("columns in one file only", out)

    def test_no_columns(self):
        a = self.write("a.tsv", HEADER + row(1))
        status, _, err = self.run_cmd("join", a, a, "--columns", ",")
        self.assertEqual(status, 2)
        self.assertIn("--columns names no column", err)
        only = self.write("only.tsv", "frame\tcycles\n1\t5\n")
        status, _, err = self.run_cmd("join", only, only)
        self.assertEqual(status, 2)
        self.assertIn("share no column", err)

    def test_bad_input(self):
        a = self.write("a.tsv", HEADER + row(1))
        bad = self.write("bad.tsv", HEADER + "1\tAAAAAAAA\n")
        status, _, err = self.run_cmd("join", a, bad)
        self.assertEqual(status, 2)
        self.assertIn("2 columns, header has 8", err)
        dup = self.write("dup.tsv", HEADER + row(1) + row(1))
        status, _, err = self.run_cmd("join", a, dup)
        self.assertEqual(status, 2)
        self.assertIn("appears twice", err)
        status, _, err = self.run_cmd("join", a, self.write("c.tsv", HEADER + row(2)))
        self.assertEqual(status, 2)
        self.assertIn("no common frames", err)


LHEADER = "frame\tline\tDISPCNT\tBLDALPHA\tVRAM_BG\n"


class LinesTest(Base):
    def test_lines(self):
        a = self.write("a.tsv", LHEADER + "1\t0\t0080\t0000\t11111111\n1\t1\t0080\t0000\t11111111\n"
                                          "2\t0\t0080\t1F11\t11111111\n")
        b = self.write("b.tsv", LHEADER + "1\t0\t0080\t0000\t22222222\n1\t1\t0080\t0000\t11111111\n"
                                          "2\t0\t0080\t1F11\t11111111\n")
        status, out, _ = self.run_cmd("lines", a, b)
        self.assertEqual(status, 1)
        self.assertIn("3 compared, 0 in one file only, 1 differ in 1 frames", out)
        self.assertIn("frame 1: 1 lines (0), columns VRAM_BG", out)
        self.assertIn("line 0: VRAM_BG 11111111/22222222", out)
        status, out, _ = self.run_cmd("lines", a, b, "--frames", "2")
        self.assertEqual(status, 0, out)


class ExtractTest(Base):
    def test_extract(self):
        log = self.write("console.log", "capture=ENABLED path=\"-\"\n[capture] " + HEADER + "noise\n[capture] "
                         + row(1))
        status, out, _ = self.run_cmd("extract", log)
        self.assertEqual(status, 0)
        self.assertEqual(out, HEADER + row(1))

    def test_console_limit(self):
        log = self.write("console.log", "[capture] " + HEADER + "[capture] " + "x" * 1990 + "\n")
        status, _, err = self.run_cmd("extract", log)
        self.assertEqual(status, 1)
        self.assertIn("2000 characters", err)

    def test_lines_before_the_header_are_skipped(self):
        # A build whose diagnostics carried the record prefix, with stderr and
        # stdout in one console (packaging/web/bootstrap.js).
        log = self.write("console.log", "[capture] full line, FIFO and raw records need a file sink; ignoring\n"
                         "capture=ENABLED path=\"-\"\n[capture] " + HEADER + "[capture] " + row(1))
        status, out, err = self.run_cmd("extract", log)
        self.assertEqual(status, 0, err)
        self.assertEqual(out, HEADER + row(1))
        self.assertIn("console.log:1: skipped, before the header row", err)

    def test_bad_records_are_left_out(self):
        log = self.write("console.log", "[capture] " + HEADER + "[capture] " + row(1) + "[capture] cut\tshort\n"
                         + "[capture] " + row(2))
        status, out, err = self.run_cmd("extract", log)
        self.assertEqual(status, 1)
        self.assertEqual(out, HEADER + row(1) + row(2))
        self.assertIn("console.log:3: 2 columns, header has 8", err)

    def test_header_missing_or_twice(self):
        status, _, err = self.run_cmd("extract", self.write("none.log", "[capture] " + row(1)))
        self.assertEqual(status, 2)
        self.assertIn("no header row", err)
        twice = self.write("twice.log", ("[capture] " + HEADER + "[capture] " + row(1)) * 2)
        status, _, err = self.run_cmd("extract", twice)
        self.assertEqual(status, 2)
        self.assertIn("twice.log:3: a second header row", err)


if __name__ == "__main__":
    unittest.main()
