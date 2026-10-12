"""Unit tests for tools/difftest/detail_lists.py (no game data).

Run: python3 -I -m unittest discover tools/difftest/tests
"""
import io
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import detail_lists  # noqa: E402


class CaptureListTest(unittest.TestCase):
    def test_few_ranges_unchanged(self):
        self.assertEqual(detail_lists.capture_list([5, 1, 2, 3, 9], cap=10), ([(1, 3), (5, 5), (9, 9)], 0))

    def test_merges_smallest_gaps_first(self):
        # 4 ranges, at most 2: the gaps are 1 (3|5), 5 (5|11) and 2 (11|14).
        rs, left = detail_lists.capture_list([1, 2, 3, 5, 11, 14], cap=100, max_ranges=2)
        self.assertEqual((rs, left), ([(1, 5), (11, 14)], 0))

    def test_cap_bounds_the_frames_captured(self):
        # Every 50th frame up to 60,050 (1,200 frames): merging them into 32
        # ranges would capture about 58,000 frames. With a cap of 2,400 the
        # list stops growing and the later frames get no detail.
        frames = list(range(50, 60051, 50))
        rs, left = detail_lists.capture_list(frames, cap=2400)
        captured = sum(b - a + 1 for a, b in rs)
        self.assertLessEqual(len(rs), 32)
        self.assertLessEqual(captured, 2400)
        kept = sum(1 for f in frames if any(a <= f <= b for a, b in rs))
        self.assertEqual(kept + left, len(frames))
        self.assertGreater(left, 0)
        self.assertEqual(rs[0][0], 50)

    def test_cap_reached_keeps_the_earliest_ranges(self):
        rs, left = detail_lists.capture_list([10, 20, 30, 40], cap=4, max_ranges=2)
        self.assertEqual((rs, left), ([(10, 10), (20, 20)], 2))


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, text, *args):
        path = os.path.join(self.tmp.name, "detail.tsv")
        with open(path, "w") as f:
            f.write(text)
        out, err = io.StringIO(), io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            code = detail_lists.main([path] + list(args), out=out)
        finally:
            sys.stderr = old
        return code, out.getvalue(), err.getvalue()

    def test_two_sides(self):
        # The TEST side is one frame later (a frame map).
        code, out, _ = self.run_main("4\t5\tlines\n6\t7\traw,lines\n7\t8\traw\n", "--cap", "10")
        self.assertEqual(code, 0)
        self.assertEqual(out, "4-4,6-7 7 3 0\n5-5,7-8 8 3 0\n")

    def test_bad_input(self):
        self.assertEqual(self.run_main("", "--cap", "10")[0], 2)
        self.assertEqual(self.run_main("x\ty\n", "--cap", "10")[0], 2)
        self.assertEqual(self.run_main("1\t1\n2\t2\n", "--cap", "1")[0], 2)


if __name__ == "__main__":
    unittest.main()
