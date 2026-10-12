#!/usr/bin/env python3
"""Align two gbarecomp clock-probe logs of one window and say where their
clocks part: comparison 1 (the recompiled build against the BIOS-interpreting
reference, ADR 0001) at the instruction level.

Stdlib only; run with python3 -I. Both inputs are the standard error of runs
of the same route with GBARECOMP_CYC_LO and GBARECOMP_CYC_HI set to the same
clocks (the capture's cycles column of two records gives them), one per
backend or per patch series. The probe (src/runtime/runtime_bus_bridge.cpp,
cyc_probe) logs every event that advances the clock: "tick" for an
instruction's cost, and irq_wake, irq_entry (patch 0012), dma_steal and
resync between instructions. Its pc field is g_cpu.R[15] at that point, the
next instruction's PC for a tick on both backends.

The tick lines of the two logs are matched one to one, in order. While the
clocks agree, both backends run the same instructions; a tick whose PC
differs is reported as a label difference and the alignment goes on, since a
SWI's tick names the vector on one backend and the handler on the other.
Every change of the clock difference (A - B) at a tick is printed with the
events just before it on both sides, the first --max of them.

usage: probediff.py A_LOG B_LOG [--context N] [--max N]

  --context N   events shown before each change, per side (default 6)
  --max N       changes shown (default 10; the count of all is printed)

Exit 0; 2 on unreadable input or a log without ticks. Evidence it produced:
docs/research/phase2-timing-fixes.md, section 6.
"""
import argparse
import re
import sys

PROBE = re.compile(r"\[cycprobe\]\s+(\S+)\s+\[(\S+)\]\s+\+(\d+)\s+clk=(\d+)->(\d+)\s+pc=([0-9a-fA-F]+)")


class InputError(Exception):
    pass


def read_probe(path):
    """[(kind, context, cycles, clock before, clock after, pc)] in log order."""
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = PROBE.search(line)
            if m:
                kind, ctx, amt, before, after, pc = m.groups()
                out.append((kind, ctx, int(amt), int(before), int(after), int(pc, 16)))
    if not any(e[0] == "tick" for e in out):
        raise InputError("%s: no clock-probe tick lines (set GBARECOMP_CYC_LO and GBARECOMP_CYC_HI)" % path)
    return out


def compare(a, b):
    """Match the tick events of a and b in order. Returns (changes, labels,
    final): changes are (tick number, index in a, index in b, old difference,
    new difference) for every change of the clock difference a - b at a tick;
    labels are the tick numbers whose PCs differ; final is the difference at
    the last matched tick."""
    ta = [i for i, e in enumerate(a) if e[0] == "tick"]
    tb = [i for i, e in enumerate(b) if e[0] == "tick"]
    changes, labels, diff = [], [], 0
    for k in range(min(len(ta), len(tb))):
        ea, eb = a[ta[k]], b[tb[k]]
        if ea[5] != eb[5]:
            labels.append(k)
        d = ea[3] - eb[3]
        if d != diff:
            changes.append((k, ta[k], tb[k], diff, d))
            diff = d
    return changes, labels, diff


def show(name, events, index, context, out):
    for j in range(max(0, index - context), min(len(events), index + 2)):
        kind, ctx, amt, before, after, pc = events[j]
        print("  %s%s %-10s [%-7s] +%-5d %d->%d pc=%08x" % (
            name, "*" if j == index else " ", kind, ctx, amt, before, after, pc), file=out)


def main(argv, out=sys.stdout):
    ap = argparse.ArgumentParser(description="Align two gbarecomp clock-probe logs of one window.")
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--context", type=int, default=6)
    ap.add_argument("--max", type=int, default=10)
    args = ap.parse_args(argv)
    try:
        a, b = read_probe(args.a), read_probe(args.b)
    except (OSError, InputError) as e:
        print("probediff.py: %s" % e, file=sys.stderr)
        return 2
    changes, labels, final = compare(a, b)
    ticks_a = sum(1 for e in a if e[0] == "tick")
    ticks_b = sum(1 for e in b if e[0] == "tick")
    print("events: A %d, B %d; ticks: A %d, B %d" % (len(a), len(b), ticks_a, ticks_b), file=out)
    print("ticks whose PC differs (labels only): %d%s" % (
        len(labels), " (first: tick %d)" % labels[0] if labels else ""), file=out)
    print("changes of the clock difference A - B: %d; at the last matched tick: %+d" % (len(changes), final),
          file=out)
    for k, ia, ib, old, new in changes[:args.max]:
        print("\ntick %d: A - B %+d -> %+d" % (k, old, new), file=out)
        show("A", a, ia, args.context, out)
        show("B", b, ib, args.context, out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
