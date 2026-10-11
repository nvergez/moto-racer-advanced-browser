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
        status, out, _ = self.run_cmd("join", a, b, "--frames", "1-4")
        self.assertEqual(status, 0, out)
        self.assertIn("A 5 (1-5), B 5 (2-6), compared 3 (2-4)", out)

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
        self.assertEqual(status, 0)
        self.assertIn("columns in one file only: ram_ewram, ram_iwram", out)

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
        log = self.write("console.log", "[capture] " + "x" * 1990 + "\n")
        status, _, err = self.run_cmd("extract", log)
        self.assertEqual(status, 1)
        self.assertIn("2000 characters", err)


if __name__ == "__main__":
    unittest.main()
