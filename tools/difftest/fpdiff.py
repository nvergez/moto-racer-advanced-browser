#!/usr/bin/env python3
"""Find where two gbarecomp runs part, instruction by instruction.

Stdlib only; run with python3 -I. Each input is the tail of gbarecomp's
per-instruction fingerprint ring, as CSV, which our executable writes when a
run ends with GBARECOMP_INSN_TRACE=1 and MRA_FP_TAIL=PATH (src/main.cpp;
gbarecomp's runtime_fp_save_tail_csv, src/armv4t/runtime_arm.cpp at the pin):
one record per instruction, before it executes, with the master clock, the
PC, the CPSR and r0-r15:

  idx,cycles,pc,cpsr,r0,r1,...,r12,sp,lr,r15

Generated code and the interpreter write the same records for the same
execution (gbarecomp fingerprints every instruction in the generated
prologue, in the interpreter bridge and in the force-interp step), so two
backends that agree give identical streams. This is how comparison 1
(ADR 0001, decision 5) localizes a frame whose capture differs:
scripts/replay-test.sh --fp-ring FRAME runs both sides up to that frame and
calls this tool.

usage: fpdiff.py A.csv B.csv [--context N] [--costs N]

The two tails cover different windows. The tool finds the first record of
one file in the other (all fields equal), then walks both files together:

  - the first record where the state (PC, CPSR or a register) differs is the
    state divergence;
  - before it, records whose clocks differ while the state is equal are a
    timing divergence: the instruction before the first such record cost a
    different number of cycles in the two runs. With --costs N, up to N
    instructions whose cost differs are listed (cost = the next record's
    clock minus this one's, so it includes any IRQ entry, DMA or halt in
    between).

--context N prints the N records before each divergence (default 4).

Exit 0 if the streams are identical over their overlap, 1 if they part, 2 on
unreadable input or windows that do not overlap.
"""
import argparse
import sys

FIELDS = ["cycles", "pc", "cpsr"] + ["r%d" % i for i in range(13)] + ["sp", "lr", "r15"]
HEADER = ["idx"] + FIELDS


class FpError(Exception):
    """Bad input: reported as "fpdiff.py: ..." without a traceback."""


def records(path):
    """(line number, tuple of ints in FIELDS order) for each record."""
    try:
        f = open(path, encoding="ascii", newline="")
    except OSError as e:
        raise FpError("%s: %s" % (path, e.strerror or e)) from None
    with f:
        header = f.readline().strip().split(",")
        if header != HEADER:
            raise FpError("%s: not a fingerprint tail (header %r)" % (path, ",".join(header)))
        for n, line in enumerate(f, 2):
            parts = line.strip().split(",")
            if len(parts) != len(HEADER):
                raise FpError("%s:%d: %d fields, expected %d" % (path, n, len(parts), len(HEADER)))
            try:
                yield n, tuple(int(p, 0) for p in parts[1:])
            except ValueError:
                raise FpError("%s:%d: not a number" % (path, n)) from None


def fmt(rec):
    regs = " ".join("%s=%08X" % (FIELDS[i], rec[i]) for i in range(3, len(FIELDS)))
    return "cycles=%d pc=%08X cpsr=%08X %s" % (rec[0], rec[1], rec[2], regs)


def differing(a, b, start=0):
    return [FIELDS[i] for i in range(start, len(FIELDS)) if a[i] != b[i]]


def seek(path, key, exact):
    """(iterator, (line, record)) on the first record of `path` equal to `key`
    (every field, or every field but the clock), or None."""
    it = records(path)
    for n, rec in it:
        if rec == key if exact else rec[1:] == key[1:]:
            return it, (n, rec)
    return None


def find_anchor(path_a, path_b):
    """Both files positioned on their first common record.

    The first record of the window that starts later (by clock) is looked up
    in the other file, with every field equal; failing that, with the state
    equal and any clock (the clocks then differed before both windows).
    Returns ((line, A record), A iterator, (line, B record), B iterator,
    whether the clock was ignored)."""
    it_a, it_b = records(path_a), records(path_b)
    first_a, first_b = next(it_a, None), next(it_b, None)
    if first_a is None or first_b is None:
        raise FpError("%s has no records" % (path_a if first_a is None else path_b))
    later_is_a = first_a[1][0] >= first_b[1][0]
    for exact in (True, False):
        for a_first in ((later_is_a, not later_is_a) if exact else (True, False)):
            if a_first:
                found = seek(path_b, first_a[1], exact)
                if found:
                    return first_a, it_a, found[1], found[0], not exact
            else:
                found = seek(path_a, first_b[1], exact)
                if found:
                    return found[1], found[0], first_b, it_b, not exact
    raise FpError("the windows do not overlap: neither file holds the other's first record "
                  "(A: %s; B: %s)" % (fmt(first_a[1]), fmt(first_b[1])))


def main(argv=None, out=None):
    out = out or sys.stdout
    ap = argparse.ArgumentParser(prog="fpdiff.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--context", type=int, default=4)
    ap.add_argument("--costs", type=int, default=0)
    args = ap.parse_args(argv)
    try:
        return run(args, out)
    except FpError as e:
        print("fpdiff.py: %s" % e, file=sys.stderr)
        return 2


def run(args, out):
    (na, ra), it_a, (nb, rb), it_b, clock_ignored = find_anchor(args.a, args.b)
    print("anchor: A line %d, B line %d: %s" % (na, nb, fmt(ra)), file=out)
    if clock_ignored:
        print("  the clocks already differ at the anchor (B - A %+d): it matches the state only, and the "
              "divergence is before both windows; run up to an earlier frame" % (rb[0] - ra[0]), file=out)
    history = [(ra, rb)]
    matched = 0
    timing = None      # (index, A record, B record, previous pair) of the first clock difference
    costs = []         # (pc, mode, cost A, cost B) of instructions whose cost differs
    prev = (ra, rb)
    for (na, ra), (nb, rb) in zip(it_a, it_b):
        matched += 1
        state_diff = differing(ra, rb, start=1)
        if state_diff:
            print("matched %d records after the anchor" % matched, file=out)
            report_timing(timing, costs, args, out)
            print("STATE DIVERGENCE at A line %d, B line %d: %s differ" % (na, nb, ", ".join(state_diff)),
                  file=out)
            print("  A: %s" % fmt(ra), file=out)
            print("  B: %s" % fmt(rb), file=out)
            print("  clock B - A at the previous record: %+d" % (prev[1][0] - prev[0][0]), file=out)
            print_context(history, args.context, out)
            return 1
        if ra[0] - prev[0][0] != rb[0] - prev[1][0]:
            cost = (prev[0][1], prev[0][2] & 0x20, ra[0] - prev[0][0], rb[0] - prev[1][0])
            if timing is None:
                timing = (na, nb, ra, rb, list(history))
            if len(costs) < max(args.costs, 1):
                costs.append(cost)
        history.append((ra, rb))
        if len(history) > args.context + 1:
            history.pop(0)
        prev = (ra, rb)
    print("matched %d records after the anchor; one file ends there" % matched, file=out)
    if timing is None:
        print("identical over the overlap", file=out)
        return 0
    report_timing(timing, costs, args, out)
    return 1


def report_timing(timing, costs, args, out):
    if timing is None:
        return
    na, nb, ra, rb, history = timing
    pc, thumb, ca, cb = costs[0]
    print("TIMING DIVERGENCE at A line %d, B line %d (state equal): clock B - A %+d" % (na, nb, rb[0] - ra[0]),
          file=out)
    print("  the instruction at %08X (%s) cost %d cycles in A and %d in B" % (
        pc, "Thumb" if thumb else "ARM", ca, cb), file=out)
    print_context(history, args.context, out)
    if args.costs:
        print("instructions whose cost differs (first %d): pc, cycles in A, in B" % len(costs), file=out)
        for pc, thumb, ca, cb in costs:
            print("  %08X %s %d %d" % (pc, "T" if thumb else "A", ca, cb), file=out)


def print_context(history, n, out):
    if n <= 0:
        return
    print("  records before it (A, with B's clock):", file=out)
    for ra, rb in history[-n:]:
        print("    %s | B cycles=%d" % (fmt(ra), rb[0]), file=out)


if __name__ == "__main__":
    sys.exit(main())
