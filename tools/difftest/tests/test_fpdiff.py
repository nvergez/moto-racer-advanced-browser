"""Unit tests for tools/difftest/fpdiff.py on synthetic fingerprint tails (no game data).

Run: python3 -I -m unittest discover tools/difftest/tests
"""
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import fpdiff  # noqa: E402


def stream(n, start_cycles=1000, cost=3):
    """n records of a toy loop: pc steps by 4, r0 counts, the clock by `cost`."""
    out = []
    c = start_cycles
    for i in range(n):
        out.append([c, 0x08000100 + 4 * (i % 8), 0x1F] + [i] + [0] * 14 + [0x08000100 + 4 * (i % 8)])
        c += cost
    return out


class FpDiffTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, recs):
        p = os.path.join(self.tmp.name, name)
        with open(p, "w") as f:
            f.write(",".join(fpdiff.HEADER) + "\n")
            for i, r in enumerate(recs):
                f.write("%d,%d,%s\n" % (i, r[0], ",".join("0x%08X" % v for v in r[1:])))
        return p

    def run_diff(self, a, b, *extra):
        out = io.StringIO()
        err = io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            code = fpdiff.main([a, b] + list(extra), out=out)
        finally:
            sys.stderr = old
        return code, out.getvalue(), err.getvalue()

    def test_identical(self):
        s = stream(50)
        code, out, _ = self.run_diff(self.write("a.csv", s), self.write("b.csv", s))
        self.assertEqual(code, 0, out)
        self.assertIn("identical over the overlap", out)

    def test_windows_offset(self):
        s = stream(50)
        code, out, _ = self.run_diff(self.write("a.csv", s[10:]), self.write("b.csv", s[:40]))
        self.assertEqual(code, 0, out)
        self.assertIn("anchor: A line 2, B line 12", out)
        code, out, _ = self.run_diff(self.write("a.csv", s[:40]), self.write("b.csv", s[10:]))
        self.assertEqual(code, 0, out)
        self.assertIn("anchor: A line 12, B line 2", out)

    def test_timing_divergence(self):
        a = stream(30)
        b = [list(r) for r in a]
        for r in b[20:]:
            r[0] += 2  # the instruction of record 19 costs 2 more in B
        code, out, _ = self.run_diff(self.write("a.csv", a), self.write("b.csv", b), "--costs", "5")
        self.assertEqual(code, 1)
        self.assertIn("TIMING DIVERGENCE at A line 22, B line 22 (state equal): clock B - A +2", out)
        self.assertIn("the instruction at 0800010C (ARM) cost 3 cycles in A and 5 in B", out)
        self.assertIn("0800010C A 3 5", out)

    def test_state_divergence(self):
        a = stream(30)
        b = [list(r) for r in a]
        b[25][4] = 0xDEAD  # r1
        code, out, _ = self.run_diff(self.write("a.csv", a), self.write("b.csv", b))
        self.assertEqual(code, 1)
        self.assertIn("STATE DIVERGENCE at A line 27, B line 27: r1 differ", out)

    def test_anchor_on_state_when_clocks_differ(self):
        a = stream(30)
        b = [list(r) for r in a]
        for r in b:
            r[0] += 7
        code, out, _ = self.run_diff(self.write("a.csv", a), self.write("b.csv", b))
        self.assertEqual(code, 0, out)
        self.assertIn("the clocks already differ at the anchor (B - A +7)", out)

    def test_no_overlap(self):
        a = stream(10)
        b = [list(r) for r in stream(10, start_cycles=10 ** 6)]
        for r in b:
            r[3] += 1000
        code, _, err = self.run_diff(self.write("a.csv", a), self.write("b.csv", b))
        self.assertEqual(code, 2)
        self.assertIn("the windows do not overlap", err)

    def test_bad_header(self):
        p = os.path.join(self.tmp.name, "x.csv")
        with open(p, "w") as f:
            f.write("a,b\n")
        code, _, err = self.run_diff(p, p)
        self.assertEqual(code, 2)
        self.assertIn("not a fingerprint tail", err)


if __name__ == "__main__":
    unittest.main()
