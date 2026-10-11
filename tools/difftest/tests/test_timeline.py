"""Unit tests for tools/difftest/timeline.py on synthetic traces (no game data).

Run with: python3 -I -m unittest discover tools/difftest/tests
"""
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import timeline  # noqa: E402

IRQ = [(0x18, 3), (0x128, 7), (0x12C, 1), (0x130, 1), (0x134, 5), (0x138, 7), (0x13C, 4)]


def run(program, start=1000):
    """Execution order [(pc, cost)] -> [(pc, clock at its start)]."""
    out, clk = [], start
    for pc, cost in program:
        out.append((pc, clk))
        clk += cost
    return out


def mgba_text(stream):
    rows = ["frame\tvcount\tpc\tmode\topcode\tcycles\n"]
    for pc, clk in stream:
        rows.append("2\t160\t%08X\tA\tE1A00000\t%d\n" % (pc, clk))
    return "".join(rows)


def gb_text(stream, end_cost=1):
    """gbarecomp clock-probe lines: one per instruction, with the PC after it. The
    probe never logs an IRQ entry, so the line before the vector shows the
    interrupted code's next PC; a leading line gives the first instruction's PC."""
    lines = ["[cycprobe] tick         [finterp] +1  clk=%d->%d  pc=%08x cpsr=0000001f\n"
             % (stream[0][1] - 1, stream[0][1], stream[0][0])]
    for k, (pc, clk) in enumerate(stream):
        nxt_clk = stream[k + 1][1] if k + 1 < len(stream) else clk + end_cost
        if k + 1 < len(stream):
            nxt = stream[k + 1][0]
            if nxt == 0x18:
                nxt = pc + 4  # interrupted: the probe shows the sequential PC
        else:
            nxt = pc + 4
        if pc == 0x18:
            nxt = 0x128
        lines.append("[cycprobe] tick         [finterp] +%d  clk=%d->%d  pc=%08x cpsr=0000001f\n"
                     % (nxt_clk - clk, clk, nxt_clk, nxt))
    return "".join(lines)


def loop(body, times):
    return [ins for _ in range(times) for ins in body]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, text):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def compare(self, m_prog, g_prog, *extra):
        m = self.write("pctrace.tsv", mgba_text(run(m_prog)))
        g = self.write("gb.log", gb_text(run(g_prog)))
        out = io.StringIO()
        status = timeline.main([m, g] + list(extra), out=out)
        return status, out.getvalue()


class TestReading(Base):
    def test_reconstructs_irq_entry(self):
        prog = [(0x08000000, 4), (0x08000004, 4)] + IRQ + [(0x08000008, 4)]
        path = self.write("gb.log", gb_text(run(prog)))
        stream, other = timeline.read_gbarecomp(path)
        self.assertEqual([pc for pc, _ in stream], [pc for pc, _ in prog])
        self.assertEqual(other, 0)

    def test_needs_cycles_column(self):
        m = self.write("pctrace.tsv", "frame\tvcount\tpc\tmode\topcode\n2\t160\t08000000\tA\tE1A00000\n")
        g = self.write("gb.log", gb_text(run([(0x08000000, 1)])))
        err = io.StringIO()
        old, sys.stderr = sys.stderr, err
        try:
            self.assertEqual(timeline.main([m, g], out=io.StringIO()), 2)
        finally:
            sys.stderr = old
        self.assertIn("--trace-pc-cycles", err.getvalue())


class TestAlign(Base):
    def test_identical(self):
        prog = loop([(0x08000000, 4), (0x08000004, 8), (0x08000008, 14)], 5)
        status, out = self.compare(prog, prog)
        self.assertEqual(status, 0)
        self.assertIn("at the last matched instruction: +0", out)
        self.assertIn("changed by instruction costs: +0", out)

    def test_instruction_cost(self):
        body_m = [(0x08000000, 4), (0x08000004, 4), (0x08000008, 14)]
        body_g = [(0x08000000, 4), (0x08000004, 8), (0x08000008, 14)]
        status, out = self.compare(loop(body_m, 10), loop(body_g, 10))
        self.assertIn("instruction 08000004: +40 over 10 changes", out)
        self.assertIn("at the last matched instruction: +40", out)

    def test_irq_entry_cost(self):
        body = [(0x03000000, 1), (0x03000004, 1), (0x03000008, 1), (0x0300000C, 3)]
        main = loop(body, 10)
        # mGBA: 2 cycles between the interrupted instruction and the vector;
        # gbarecomp: none, and it takes the IRQ one instruction later.
        m_prog = main[:20] + [(main[20][0], main[20][1] + 2)] + IRQ + main[21:]
        g_prog = main[:22] + IRQ + main[22:]
        status, out = self.compare(m_prog, g_prog, "--line0=-89000", "--watch", "0300000C")
        self.assertEqual(status, 0)
        self.assertIn("at the last matched instruction: -2", out)
        self.assertIn("changed by instruction costs: +0; next to IRQs: -2", out)
        self.assertIn("mGBA IRQ entries on visible lines: 1; entry overhead [(2, 1)]", out)
        self.assertIn("gbarecomp IRQ entries on visible lines: 1; entry overhead [(0, 1)]", out)

    def test_loop_count(self):
        wait = [(0x03001CEC, 3), (0x03001CF0, 1), (0x03001CF4, 1), (0x03001CF8, 3)]
        rest = [(0x03001CFC + 4 * k, 2) for k in range(12)]
        status, out = self.compare(loop(wait, 3) + rest, loop(wait, 5) + rest)
        self.assertEqual(status, 0)
        self.assertIn("by skipped loop iterations: +16 (1)", out)
        self.assertIn("changed by instruction costs: +0", out)


if __name__ == "__main__":
    unittest.main()
