"""Unit tests for tools/difftest/probediff.py on synthetic probe logs (no game
data).

Run with: python3 -I -m unittest discover tools/difftest/tests
"""
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import probediff  # noqa: E402


def log(events, start=1000):
    """[(kind, context, cycles, pc)] -> clock-probe lines from clock start."""
    lines, clk = ["unrelated line\n"], start
    for kind, ctx, amt, pc in events:
        lines.append("[cycprobe] %-12s [%s] +%d  clk=%d->%d  pc=%08x cpsr=0000001f\n"
                     % (kind, ctx, amt, clk, clk + amt, pc))
        clk += amt
    return "".join(lines)


# Five instructions; the second writes a register whose cost differs (7 or 9).
BASE = [("tick", "finterp", 6, 0x080025D0), ("resync", "gen", 0, 0x080025D0),
        ("tick", "finterp", 7, 0x080025D4), ("tick", "finterp", 4, 0x080025D8),
        ("tick", "finterp", 3, 0x00000140), ("tick", "finterp", 1, 0x080025E0)]


class ProbeDiffTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, text):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def run_main(self, a_events, b_events, *extra):
        a = self.write("a.log", log(a_events))
        b = self.write("b.log", log(b_events))
        out = io.StringIO()
        rc = probediff.main([a, b] + list(extra), out)
        return rc, out.getvalue()

    def test_equal_logs(self):
        rc, text = self.run_main(BASE, BASE)
        self.assertEqual(rc, 0)
        self.assertIn("changes of the clock difference A - B: 0; at the last matched tick: +0", text)
        self.assertIn("ticks whose PC differs (labels only): 0", text)

    def test_cost_difference_is_found_at_the_next_tick(self):
        b_events = list(BASE)
        b_events[2] = ("tick", "gen", 9, 0x080025D4)
        rc, text = self.run_main(BASE, b_events)
        self.assertEqual(rc, 0)
        # The clocks part at the tick after the one that cost more.
        self.assertIn("tick 2: A - B +0 -> -2", text)
        self.assertIn("at the last matched tick: -2", text)
        self.assertIn("B  tick       [gen    ] +9", text)

    def test_events_between_ticks_shift_the_clock(self):
        a_events = list(BASE)
        a_events.insert(4, ("irq_entry", "finterp", 2, 0x080025D8))
        rc, text = self.run_main(a_events, BASE)
        self.assertIn("tick 3: A - B +0 -> +2", text)
        self.assertIn("A  irq_entry", text)

    def test_label_differences_do_not_stop_the_alignment(self):
        b_events = list(BASE)
        b_events[4] = ("tick", "gen", 3, 0x00000008)
        b_events[5] = ("tick", "gen", 2, 0x080025E0)
        rc, text = self.run_main(BASE, b_events)
        self.assertIn("ticks whose PC differs (labels only): 1 (first: tick 3)", text)
        self.assertIn("at the last matched tick: +0", text)
        self.assertEqual(rc, 0)

    def test_max_limits_the_changes_shown(self):
        # Every instruction costs one cycle more: the difference changes at each tick.
        b_events = [(kind, ctx, amt + 1 if kind == "tick" else amt, pc) for kind, ctx, amt, pc in BASE]
        rc, text = self.run_main(BASE, b_events, "--max", "1")
        self.assertEqual(text.count("\ntick "), 1)

    def test_a_log_without_ticks_is_an_error(self):
        a = self.write("a.log", "no probe here\n")
        b = self.write("b.log", log(BASE))
        err = io.StringIO()
        old, sys.stderr = sys.stderr, err
        try:
            rc = probediff.main([a, b], io.StringIO())
        finally:
            sys.stderr = old
        self.assertEqual(rc, 2)
        self.assertIn("no clock-probe tick lines", err.getvalue())


if __name__ == "__main__":
    unittest.main()
