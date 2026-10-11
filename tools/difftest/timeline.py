#!/usr/bin/env python3
"""Align mGBA's and gbarecomp's instruction timelines and say where they drift.

Stdlib only; run with python3 -I. Both inputs come from the same route and
frame window, on runs that are still in the same game state there (equal
per-frame captures before the window):

  mGBA       the harness's pctrace.tsv with the clock column:
             --trace-pc 0x00000000-0x0FFFFFFF --trace-pc-cycles --step-frames F
  gbarecomp  the standard error of a run with GBARECOMP_CYC_LO/GBARECOMP_CYC_HI
             set to the clocks of the same window (the capture's cycles column
             gives them), with GBARECOMP_FORCE_INTERP=1 and MRA_INTERP_BIOS=1,
             so that every instruction, the BIOS's included, is stepped by the
             interpreter and logged by gbarecomp's clock probe
             (src/runtime/runtime_bus_bridge.cpp, cyc_probe).

Both clocks count CPU cycles from reset and follow the video timing (the
capture's cycles column; tools/capture/README.md), so the same instruction
can be compared in absolute cycles. The probe logs, for each instruction, the
clock before it and the PC after it; the instruction's own PC is the PC the
previous line logged, except after an IRQ entry, which the probe does not log:
a line that branches to 0x128 when the PC before it was not 0x18 is the BIOS
IRQ vector's "b 0x128" (retail BIOS). Lines of other kinds (irq_wake,
dma_steal, resync) charge cycles between instructions.

Each stream is split into main-line code and IRQ segments (from the vector
0x18 to the instruction after the retail BIOS's return at 0x13C). The
main-line instructions are matched one to one (a busy-wait loop that runs a
different number of times is skipped over by looking ahead for the next 8
equal PCs), and every change of the clock difference (gbarecomp - mGBA) at a
matched instruction is attributed to:

  - the cost of the main-line instruction before it, when neither engine took
    an IRQ in between;
  - an IRQ taken in between (entry latency, entry cost, handler time);
  - a skipped loop iteration.

usage: timeline.py MGBA_PCTRACE GB_LOG [--line0 CLK] [--watch PC,...] [--top N]

  --line0 CLK   the clock of a VBlank start (a capture's cycles column) in or
                before the window: IRQ entries are then reported per kind of
                line (VBlank lines 160-227, visible lines 0-159), with their
                position in the line and their entry overhead, the cycles
                between the interrupted instruction's start and the vector
                beyond that instruction's usual cost
  --watch PCS   print the clock difference each time a matched main-line
                instruction is at one of these PCs (hex, comma-separated)
  --top N       instructions listed by cost difference (default 20)

Exit 0, or 2 on unreadable input. Evidence it produced: docs/research/
phase2-race-lockstep.md.
"""
import argparse
import re
import sys
from collections import Counter, defaultdict

IRQ_VECTOR = 0x18
BIOS_IRQ_BRANCH_TARGET = 0x128
BIOS_IRQ_RETURN = 0x13C
LINE_CYCLES = 1232
VISIBLE_LINES = 160
LINES_PER_FRAME = 228

PROBE = re.compile(r"\[cycprobe\]\s+(\S+)\s+\[(\S+)\]\s+\+(\d+)\s+clk=(\d+)->(\d+)\s+pc=([0-9a-fA-F]+)")


class InputError(Exception):
    pass


def read_mgba(path):
    """[(pc, clock)] from a harness pctrace.tsv with the cycles column."""
    out = []
    with open(path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        try:
            pc_i, clk_i = header.index("pc"), header.index("cycles")
        except ValueError:
            raise InputError("%s: no pc or cycles column (run the harness with --trace-pc-cycles)" % path)
        for n, line in enumerate(f, 2):
            cols = line.rstrip("\n").split("\t")
            try:
                out.append((int(cols[pc_i], 16), int(cols[clk_i])))
            except (IndexError, ValueError):
                raise InputError("%s:%d: malformed row" % (path, n))
    return out


def read_gbarecomp(path):
    """[(pc, clock)] reconstructed from gbarecomp's clock-probe lines, and the
    number of tick lines that did not come from the interpreter."""
    out = []
    other_ctx = 0
    prev_next = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = PROBE.search(line)
            if not m:
                continue
            kind, ctx, _, before, _, next_pc = m.groups()
            next_pc = int(next_pc, 16)
            if kind != "tick":
                continue
            if ctx != "finterp":
                other_ctx += 1
            if prev_next is not None:
                pc = prev_next
                if next_pc == BIOS_IRQ_BRANCH_TARGET and prev_next != IRQ_VECTOR:
                    pc = IRQ_VECTOR
                out.append((pc, int(before)))
            prev_next = next_pc
    return out, other_ctx


def split(stream):
    """Main-line instructions [(pc, clock)] and IRQs [(main index taken before, entry clock, instruction before)]."""
    main, irqs = [], []
    k, n = 0, len(stream)
    while k < n:
        if stream[k][0] == IRQ_VECTOR:
            before = stream[k - 1] if k else None
            irqs.append((len(main), stream[k][1], before))
            while k < n and stream[k][0] != BIOS_IRQ_RETURN:
                k += 1
            k += 1
            continue
        main.append(stream[k])
        k += 1
    return main, irqs


def resync(a, b, i, j, k=8, look=300):
    best = None
    for di in range(look):
        for dj in range(look):
            if di + dj == 0:
                continue
            if best is not None and di + dj >= best[0]:
                break
            ii, jj = i + di, j + dj
            if ii + k > len(a) or jj + k > len(b):
                continue
            if all(a[ii + t][0] == b[jj + t][0] for t in range(k)):
                best = (di + dj, ii, jj)
    return best


def usual_costs(stream):
    costs = defaultdict(Counter)
    for k in range(len(stream) - 1):
        if stream[k + 1][0] != IRQ_VECTOR:
            costs[stream[k][0]][stream[k + 1][1] - stream[k][1]] += 1
    return {pc: c.most_common(1)[0][0] for pc, c in costs.items()}


def irq_table(stream, irqs, line0):
    """Per kind of line: Counter of entry overhead and Counter of entry position in the line."""
    usual = usual_costs(stream)
    over = {"vblank": Counter(), "visible": Counter()}
    pos = {"vblank": Counter(), "visible": Counter()}
    for _, entry, before in irqs:
        rel = entry - line0
        line = (VISIBLE_LINES + rel // LINE_CYCLES) % LINES_PER_FRAME
        kind = "vblank" if line >= VISIBLE_LINES else "visible"
        pos[kind][rel % LINE_CYCLES] += 1
        if before is not None and before[0] in usual:
            over[kind][entry - before[1] - usual[before[0]]] += 1
    return over, pos


def align(m_stream, g_stream, watch=(), out=sys.stdout):
    m_main, m_irq = split(m_stream)
    g_main, g_irq = split(g_stream)
    m_at = Counter(x[0] for x in m_irq)
    g_at = Counter(x[0] for x in g_irq)
    result = {"cost": Counter(), "cost_n": Counter(), "irq": 0, "irq_n": 0, "skip": 0, "skip_n": 0,
              "final": None, "matched": 0, "unaligned": False,
              "m_main": len(m_main), "g_main": len(g_main), "m_irqs": m_irq, "g_irqs": g_irq}
    prev = None
    i = j = 0
    while i < len(m_main) and j < len(g_main):
        if m_main[i][0] != g_main[j][0]:
            r = resync(m_main, g_main, i, j)
            if r is None:
                print("cannot realign at mGBA main-line instruction %d (pc %08X) / gbarecomp %d (pc %08X)"
                      % (i, m_main[i][0], j, g_main[j][0]), file=out)
                result["unaligned"] = True
                break
            _, i, j = r
            d = g_main[j][1] - m_main[i][1]
            if prev is not None:
                result["skip"] += d - prev
                result["skip_n"] += 1
            prev = d
            continue
        d = g_main[j][1] - m_main[i][1]
        if m_main[i][0] in watch:
            print("at %08X (mGBA clock %d): gbarecomp %+d" % (m_main[i][0], m_main[i][1], d), file=out)
        if prev is not None and d != prev:
            if m_at[i] or g_at[j]:
                result["irq"] += d - prev
                result["irq_n"] += 1
            else:
                pc = m_main[i - 1][0]
                result["cost"][pc] += d - prev
                result["cost_n"][pc] += 1
        prev = d
        result["matched"] += 1
        i += 1
        j += 1
    result["final"] = prev
    return result


def main(argv, out=sys.stdout):
    ap = argparse.ArgumentParser(description="Align mGBA's and gbarecomp's instruction timelines.")
    ap.add_argument("mgba")
    ap.add_argument("gbarecomp")
    ap.add_argument("--line0", type=int)
    ap.add_argument("--watch", default="")
    ap.add_argument("--top", type=int, default=20)
    args = ap.parse_args(argv)
    try:
        watch = {int(x, 16) for x in args.watch.split(",") if x}
        m_stream = read_mgba(args.mgba)
        g_stream, other = read_gbarecomp(args.gbarecomp)
    except (OSError, InputError, ValueError) as e:
        print("timeline.py: %s" % e, file=sys.stderr)
        return 2
    if not m_stream or not g_stream:
        print("timeline.py: an input has no instructions", file=sys.stderr)
        return 2
    if other:
        print("warning: %d gbarecomp lines were not stepped by the interpreter; their PCs are unreliable "
              "(run with GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1)" % other, file=out)
    r = align(m_stream, g_stream, watch, out)
    print("instructions: mGBA %d (%d main-line, %d IRQs), gbarecomp %d (%d main-line, %d IRQs); matched %d"
          % (len(m_stream), r["m_main"], len(r["m_irqs"]), len(g_stream), r["g_main"], len(r["g_irqs"]),
             r["matched"]), file=out)
    print("clock difference gbarecomp - mGBA at the last matched instruction: %s" % (
        "%+d" % r["final"] if r["final"] is not None else "-"), file=out)
    print("  changed by instruction costs: %+d; next to IRQs: %+d (%d changes); by skipped loop iterations: %+d (%d)"
          % (sum(r["cost"].values()), r["irq"], r["irq_n"], r["skip"], r["skip_n"]), file=out)
    for pc, total in sorted(r["cost"].items(), key=lambda kv: (-abs(kv[1]), kv[0]))[:args.top]:
        print("  instruction %08X: %+d over %d changes" % (pc, total, r["cost_n"][pc]), file=out)
    if args.line0 is not None:
        for name, stream in (("mGBA", m_stream), ("gbarecomp", g_stream)):
            _, irqs = split(stream)
            over, pos = irq_table(stream, irqs, args.line0)
            for kind in ("vblank", "visible"):
                if not pos[kind]:
                    continue
                print("%s IRQ entries on %s lines: %d; entry overhead %s; position in line (most common) %s" % (
                    name, kind, sum(pos[kind].values()), sorted(over[kind].items()),
                    pos[kind].most_common(4)), file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
