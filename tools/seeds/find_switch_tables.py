#!/usr/bin/env python3
"""Find armcc switch tables in ARM code and print their case slots as
gbarecomp [[extra_func]] candidates (stdlib only; run with python3 -I).

usage:
  find_switch_tables.py ROM [--copy NAME=SOURCE,SIZE,RUNTIME]... [--no-default-copies]
  find_switch_tables.py ROM --toml [...]
  find_switch_tables.py ROM --check-config GAME_TOML [...]

  ROM             a GBA ROM file, loaded at 0x08000000
  (no mode)       a report: one line per dispatcher, then a summary
  --toml          the [[extra_func]] candidates for every table in ROM code
                  that passes the checks below, with a comment per table and
                  a note per entry, for a human to review and paste into
                  game.toml (no tool writes game.toml)
  --check-config GAME_TOML
                  check that GAME_TOML has an ARM [[extra_func]] at every
                  candidate slot, and that every [[extra_func]] whose note
                  calls it a case slot of an armcc switch is a candidate.
                  Exit 1 on any difference (needs Python 3.11, tomllib)
  --copy NAME=SOURCE,SIZE,RUNTIME
                  a ROM range that the game copies to RUNTIME and runs only
                  there (a [[code_copy]]). Tables inside it are reported with
                  their runtime addresses and never printed as ROM candidates.
                  Numbers in C notation (0x...). Repeatable
  --no-default-copies
                  forget the copies built in for the pinned ROM (below)

What it looks for
-----------------

armcc compiles a dense switch statement in ARM code as

    cmp   rM, #N                      (the bound; possibly a few
    ...                                instructions earlier, see below)
    addls pc, pc, rM, lsl #2          the dispatcher, at address D
    b     default                     D + 4: index > N
    b     case_0                      D + 8: the case slots, one b each
    ...
    b     case_N                      D + 8 + 4 * N

The addls reads PC as D + 8, so index i lands on slot D + 8 + 4 * i. gbarecomp's
finder cannot follow the addls (its PC-write evaluator needs an unshifted,
known register, gbarecomp src/recompile/function_finder.cpp:1030-1039 at the
pin 5e89943), and [[jump_table]] reads tables of data words, not of b
instructions, so every slot needs an [[extra_func]] of its own
(docs/research/phase2-diagnosis.md section 2.2). The default slot D + 4 needs
none: the finder already seeds the fall-through of a conditional indirect
branch (function_finder.cpp:1814-1820).

Every 4-byte aligned word that encodes add<cond> pc, pc, rM, lsl #2 is a
dispatcher candidate. A table becomes candidates only if all of these hold:

  - the condition is LS (index <= N: N + 1 slots) or CC (index < N: N slots);
  - the bound is a cmp rM, #imm with condition AL, found by walking back from
    the dispatcher over at most 16 instructions, each of which is
    unconditional, of a known ARMv4T class, writes neither rM nor the flags,
    and does not branch or write PC; the walk stops at anything else, and the
    table is then reported as unsized;
  - D + 4 and every slot is an unconditional b (not bl) whose target lies in
    the same region (ROM code or the same copy) as the dispatcher;
  - the whole table, from the cmp to the last slot, lies in one region.

Two more things are reported for review, without rejecting the table:

  - every word of the ROM that encodes a b or bl into the instructions after
    the cmp, up to and including the dispatcher: a branch there would enter
    the dispatcher with flags the cmp did not set. Data words that happen to
    encode a branch are counted too, and indirect branches cannot be checked
    this way;
  - an unconditional b right after the last slot: armcc puts the first case
    body there, which may itself start with a b, but it is also what a bound
    one too small would look like.

The output names addresses only; it copies no instruction bytes of the ROM.

Copies built in for the pinned ROM
----------------------------------

For the ROM with SHA-1 b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0 (Moto Racer
Advance, Europe, A9MP), the four ROM-to-RAM code copies of
docs/research/phase1-findings.md section 4 (verified there by rebuilding each
copy from mGBA write logs) are built in: the front end's IWRAM image, the race
program's IWRAM image and the two EWRAM save routines (game.toml). For any
other ROM there are no default copies, and a warning says so.
"""
import argparse
import hashlib
import os
import re
import struct
import sys

ROM_BASE = 0x08000000
PINNED_SHA1 = "b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0"
# (name, source, size, runtime) for the pinned ROM: phase1-findings.md
# section 4, and game.toml's [[code_copy]] entries and IWRAM comment.
PINNED_COPIES = (
    ("fe_iwram", 0x081596FC, 0x834, 0x03000000),
    ("race_iwram", 0x083F6820, 0x49C4, 0x03000000),
    ("sram_read_ewram", 0x0801192C, 0x34, 0x0203D7D4),
    ("sram_verify_ewram", 0x08011994, 0x3C, 0x0203D734),
)
MAX_LOOKBACK = 16
COND_AL, COND_LS, COND_CC, COND_NV = 0xE, 0x9, 0x3, 0xF
COND_NAMES = ("eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc",
              "hi", "ls", "ge", "lt", "gt", "le", "", "nv")
# How --toml's notes start after the SHA-1, and what --check-config looks for.
CASE_NOTE_RE = re.compile(r"Case slot \d+ of \d+ of the armcc switch at ")


class Error(Exception):
    pass


# --- ARM (ARMv4T) decoding: only what the checks need ----------------------

def is_dispatcher(w):
    """add<cond> pc, pc, rM, lsl #2 (S clear). Returns rM or None."""
    if (w & 0x0FFFFFF0) == 0x008FF100 and (w >> 28) != COND_NV:
        return w & 0xF
    return None


def decode_cmp_imm(w):
    """cmp<cond> rN, #imm: (cond, rN, imm) or None."""
    if (w & 0x0FF0F000) != 0x03500000:
        return None
    rot = ((w >> 8) & 0xF) * 2
    imm8 = w & 0xFF
    imm = ((imm8 >> rot) | (imm8 << (32 - rot))) & 0xFFFFFFFF if rot else imm8
    return (w >> 28, (w >> 16) & 0xF, imm)


def decode_branch(w, pc):
    """b/bl<cond> at pc: (cond, link, target) or None."""
    if (w & 0x0E000000) != 0x0A000000 or (w >> 28) == COND_NV:
        return None
    off = w & 0x00FFFFFF
    if off & 0x00800000:
        off -= 0x01000000
    return (w >> 28, bool(w & 0x01000000), (pc + 8 + off * 4) & 0xFFFFFFFF)


def effects(w):
    """What an ARM instruction does to the registers and the flags.

    Returns (known, writes, sets_flags, control): `writes` is the set of
    registers it may write, `control` whether it may change the flow (a
    branch, a write to PC, an exception). `known` is False for classes this
    decoder does not model (coprocessor, MSR, undefined); callers treat those
    as barriers.
    """
    kind = (w >> 25) & 7
    load = bool(w & (1 << 20))
    rn, rd = (w >> 16) & 0xF, (w >> 12) & 0xF
    if kind in (0, 1):
        if kind == 0 and (w & 0x0FFFFFF0) == 0x012FFF10:  # bx
            return True, set(), False, True
        if kind == 0 and (w & 0x0FC000F0) == 0x00000090:  # mul, mla
            rd_mul = (w >> 16) & 0xF
            return True, {rd_mul}, load, rd_mul == 15
        if kind == 0 and (w & 0x0F8000F0) == 0x00800090:  # umull and co.
            regs = {rn, rd}
            return True, regs, load, 15 in regs
        if kind == 0 and (w & 0x0FB00FF0) == 0x01000090:  # swp, swpb
            return True, {rd}, False, rd == 15
        if kind == 0 and (w & 0x90) == 0x90:  # ldrh, strh, ldrsb, ldrsh
            if (w & 0x60) == 0:
                return False, set(), False, False
            regs = {rd} if load else set()
            if not (w & (1 << 24)) or (w & (1 << 21)):  # post-index or writeback
                regs.add(rn)
            return True, regs, False, 15 in regs
        if (w & 0x0FBF0FFF) == 0x010F0000:  # mrs
            return True, {rd}, False, rd == 15
        opcode = (w >> 21) & 0xF
        if 8 <= opcode <= 11 and not (w & (1 << 20)):  # msr and the like
            return False, set(), False, False
        if 8 <= opcode <= 11:  # tst, teq, cmp, cmn
            return True, set(), True, False
        return True, {rd}, bool(w & (1 << 20)), rd == 15
    if kind in (2, 3):
        if kind == 3 and (w & 0x10):  # undefined
            return False, set(), False, False
        regs = {rd} if load else set()
        if not (w & (1 << 24)) or (w & (1 << 21)):
            regs.add(rn)
        return True, regs, False, 15 in regs
    if kind == 4:  # ldm, stm
        if w & (1 << 22):  # user bank or SPSR restore
            return False, set(), False, False
        regs = {r for r in range(16) if w & (1 << r)} if load else set()
        if w & (1 << 21):
            regs.add(rn)
        return True, regs, False, 15 in regs
    if kind == 5:  # b, bl
        return True, ({14} if w & (1 << 24) else set()), False, True
    return False, set(), False, False  # coprocessor, swi


# --- The scan ----------------------------------------------------------------

class Copy(object):
    def __init__(self, name, source, size, runtime):
        self.name, self.source, self.size, self.runtime = name, source, size, runtime

    def contains(self, addr):
        return self.source <= addr < self.source + self.size

    def to_runtime(self, addr):
        return self.runtime + (addr - self.source)


class Table(object):
    """One dispatcher and what the checks found."""

    def __init__(self, addr, rm, cond):
        self.addr, self.rm, self.cond = addr, rm, cond
        self.region = None      # None: ROM code; else the Copy
        self.cmp_addr = None
        self.bound = None       # the cmp immediate
        self.count = 0          # number of case slots
        self.default_target = None
        self.targets = []       # one per case slot
        self.problems = []      # reasons the table is not a candidate
        self.reviews = []       # things a reviewer should look at

    @property
    def ok(self):
        return not self.problems

    def slot(self, i):
        return self.addr + 8 + 4 * i

    def runtime(self, addr):
        return self.region.to_runtime(addr) if self.region else addr


def word_at(rom, addr):
    off = addr - ROM_BASE
    if off < 0 or off + 4 > len(rom) or off % 4:
        return None
    return struct.unpack_from("<I", rom, off)[0]


def region_of(addr, copies):
    for c in copies:
        if c.contains(addr):
            return c
    return None


def find_bound(rom, t):
    """Walk back from the dispatcher to its cmp (see the module docstring)."""
    for back in range(1, MAX_LOOKBACK + 1):
        addr = t.addr - 4 * back
        w = word_at(rom, addr)
        if w is None:
            return "no cmp before the dispatcher (start of the ROM)"
        cmp = decode_cmp_imm(w)
        if cmp is not None and cmp[1] == t.rm:
            if cmp[0] != COND_AL:
                return "the cmp of r%d at 0x%08X is conditional" % (t.rm, addr)
            t.cmp_addr, t.bound = addr, cmp[2]
            return None
        if (w >> 28) != COND_AL:
            return "conditional instruction at 0x%08X before any cmp of r%d" % (addr, t.rm)
        known, writes, sets_flags, control = effects(w)
        if not known:
            return "instruction of an unmodeled class at 0x%08X before any cmp of r%d" % (addr, t.rm)
        if control:
            return "branch or PC write at 0x%08X before any cmp of r%d" % (addr, t.rm)
        if sets_flags:
            return "flags set at 0x%08X before any cmp of r%d" % (addr, t.rm)
        if t.rm in writes:
            return "r%d written at 0x%08X before any cmp of it" % (t.rm, addr)
    return "no cmp of r%d within %d instructions" % (t.rm, MAX_LOOKBACK)


def check_table(rom, t, copies):
    t.region = region_of(t.addr, copies)
    if t.cond not in (COND_LS, COND_CC):
        t.problems.append("condition %s, not ls or cc" % (COND_NAMES[t.cond] or "al"))
        return
    problem = find_bound(rom, t)
    if problem:
        t.problems.append(problem)
        return
    t.count = t.bound + 1 if t.cond == COND_LS else t.bound
    if t.count == 0 or t.count > 1024:
        t.problems.append("implausible case count %d" % t.count)
        return
    last = t.slot(t.count - 1)
    if region_of(t.cmp_addr, copies) is not t.region or region_of(last, copies) is not t.region:
        t.problems.append("the table crosses a copy boundary")
        return

    def in_region(target):
        if t.region is not None:
            return t.region.contains(target)
        return (ROM_BASE <= target < ROM_BASE + len(rom)
                and region_of(target, copies) is None)

    for i, addr in enumerate([t.addr + 4] + [t.slot(i) for i in range(t.count)]):
        w = word_at(rom, addr)
        br = decode_branch(w, addr) if w is not None else None
        what = "default slot" if i == 0 else "case slot %d" % (i - 1)
        if br is None or br[0] != COND_AL or br[1]:
            t.problems.append("%s at 0x%08X is not an unconditional b" % (what, addr))
            continue
        if not in_region(br[2]):
            t.problems.append("%s at 0x%08X branches out of its region, to 0x%08X"
                              % (what, addr, br[2]))
            continue
        if i == 0:
            t.default_target = br[2]
        else:
            t.targets.append(br[2])
    after = t.slot(t.count)
    w = word_at(rom, after)
    br = decode_branch(w, after) if w is not None else None
    if br is not None and br[0] == COND_AL and not br[1]:
        t.reviews.append("the word after the last slot, at 0x%08X, is also a b (to 0x%08X): "
                         "check the bound" % (after, br[2]))


def branch_targets(rom):
    """target -> [source] for every aligned word that encodes b or bl."""
    found = {}
    for off in range(0, len(rom) - 3, 4):
        w = struct.unpack_from("<I", rom, off)[0]
        br = decode_branch(w, ROM_BASE + off)
        if br is not None:
            found.setdefault(br[2], []).append(ROM_BASE + off)
    return found


def scan(rom, copies=()):
    """All dispatchers of `rom` (bytes loaded at ROM_BASE), checked."""
    tables = []
    for off in range(0, len(rom) - 3, 4):
        w = struct.unpack_from("<I", rom, off)[0]
        rm = is_dispatcher(w)
        if rm is None:
            continue
        t = Table(ROM_BASE + off, rm, w >> 28)
        check_table(rom, t, copies)
        tables.append(t)
    if any(t.cmp_addr is not None for t in tables):
        targets = branch_targets(rom)
        for t in tables:
            if t.cmp_addr is None:
                continue
            for addr in range(t.cmp_addr + 4, t.addr + 4, 4):
                for src in targets.get(addr, ()):
                    t.reviews.append("a b/bl-shaped word at 0x%08X targets 0x%08X, between "
                                     "the cmp and the dispatcher" % (src, addr))
    return tables


# --- Output ------------------------------------------------------------------

def cmp_text(t):
    return "cmp r%d, %d at 0x%08X" % (t.rm, t.bound, t.cmp_addr)


def describe(t):
    where = "rom" if t.region is None else "%s 0x%08X" % (t.region.name, t.runtime(t.addr))
    head = "0x%08X  %-25s r%-2d " % (t.addr, where, t.rm)
    if not t.ok:
        text = head + "REJECTED: " + "; ".join(t.problems)
    else:
        text = head + "%s (%d before), %d cases, slots 0x%08X-0x%08X, default b 0x%08X, %d distinct targets" % (
            cmp_text(t), (t.addr - t.cmp_addr) // 4, t.count, t.slot(0), t.slot(t.count - 1),
            t.default_target, len(set(t.targets)))
    for r in t.reviews:
        text += "\n            REVIEW: " + r
    return text


def report(tables, out):
    rom_ok = [t for t in tables if t.ok and t.region is None]
    copy_ok = [t for t in tables if t.ok and t.region is not None]
    bad = [t for t in tables if not t.ok]
    for t in tables:
        out.write(describe(t) + "\n")
    out.write("\n%d dispatchers (add pc, pc, rM, lsl 2): %d tables in ROM code with %d case slots"
              % (len(tables), len(rom_ok), sum(t.count for t in rom_ok)))
    out.write(", %d in copied code with %d case slots" % (len(copy_ok), sum(t.count for t in copy_ok)))
    if copy_ok:
        out.write(" (%s)" % ", ".join(sorted(set(t.region.name for t in copy_ok))))
    out.write(", %d rejected, %d to review\n" % (len(bad), sum(1 for t in tables if t.reviews)))


def slot_note(sha1, t, i):
    """The note of case slot i; starts with CASE_NOTE_RE after the SHA-1."""
    return ("ROM SHA-1 %s. Case slot %d of %d of the armcc switch at 0x%08X (addls pc, pc, r%d, lsl 2, "
            "bounded by %s): the dispatcher jumps here for index %d, and the slot is b 0x%08X. "
            "The finder does not follow the addls. Found by tools/seeds/find_switch_tables.py, "
            "which checked that all %d slots are b instructions."
            % (sha1, i, t.count, t.addr, t.rm, cmp_text(t), i, t.targets[i], t.count))


def toml_entries(tables, sha1, out):
    rom_ok = [t for t in tables if t.ok and t.region is None]
    out.write("# Generated by tools/seeds/find_switch_tables.py from the ROM with SHA-1\n"
              "# %s: %d tables in ROM code, %d case slots.\n"
              % (sha1, len(rom_ok), sum(t.count for t in rom_ok)))
    for t in rom_ok:
        out.write("\n# Switch at 0x%08X: %s, %d case slots 0x%08X-0x%08X, all b;\n"
                  "# default b 0x%08X at 0x%08X, which the finder already roots.\n"
                  % (t.addr, cmp_text(t), t.count, t.slot(0), t.slot(t.count - 1),
                     t.default_target, t.addr + 4))
        for r in t.reviews:
            out.write("# REVIEW: %s\n" % r)
        for i in range(t.count):
            out.write('\n[[extra_func]]\naddr = 0x%08X\nmode = "arm"\nnote = "%s"\n'
                      % (t.slot(i), slot_note(sha1, t, i)))


def check_config(tables, path, out):
    """Compare GAME_TOML's [[extra_func]] entries with the candidates."""
    try:
        import tomllib
    except ModuleNotFoundError:
        raise Error("--check-config needs Python 3.11 or newer (tomllib); this is %s"
                    % sys.version.split()[0])
    try:
        with open(path, "rb") as f:
            config = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise Error("cannot read %s: %s" % (path, e))
    want = set()
    for t in tables:
        if t.ok and t.region is None:
            want.update(t.slot(i) for i in range(t.count))
    have, marked = {}, set()
    for e in config.get("extra_func", []):
        addr = e.get("addr")
        have.setdefault(addr, []).append(e.get("mode"))
        if CASE_NOTE_RE.search(e.get("note", "")):
            marked.add(addr)
    problems = []
    for a in sorted(want):
        modes = have.get(a, [])
        if not modes:
            problems.append("missing: no [[extra_func]] at case slot 0x%08X" % a)
        elif modes != ["arm"]:
            problems.append("case slot 0x%08X is declared %d time(s), as %s"
                            % (a, len(modes), ", ".join(map(str, modes))))
    for a in sorted(marked - want):
        problems.append("extra: the note of 0x%08X calls it a case slot, but it is not a candidate" % a)
    for p in problems:
        out.write(p + "\n")
    out.write("%s: %d candidate slots, %d entries noted as case slots, %d problem(s)\n"
              % ("MISMATCH" if problems else "ok", len(want), len(marked), len(problems)))
    return not problems


def parse_copy(text):
    try:
        name, rest = text.split("=", 1)
        source, size, runtime = [int(v, 0) for v in rest.split(",")]
    except ValueError:
        raise argparse.ArgumentTypeError("expected NAME=SOURCE,SIZE,RUNTIME, got %r" % text)
    if not name or size <= 0:
        raise argparse.ArgumentTypeError("bad copy %r" % text)
    return Copy(name, source, size, runtime)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Find armcc switch tables in ARM code (see the module docstring).")
    ap.add_argument("rom")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--toml", action="store_true")
    mode.add_argument("--check-config", metavar="GAME_TOML")
    ap.add_argument("--copy", type=parse_copy, action="append", default=[])
    ap.add_argument("--no-default-copies", action="store_true")
    args = ap.parse_args(argv)

    try:
        with open(args.rom, "rb") as f:
            rom = f.read()
    except OSError as e:
        sys.stderr.write("error: %s\n" % e)
        return 2
    if not rom or len(rom) > 0x02000000:
        sys.stderr.write("error: %s is not a GBA ROM (%d bytes)\n" % (args.rom, len(rom)))
        return 2
    sha1 = hashlib.sha1(rom).hexdigest()
    copies = list(args.copy)
    if not args.no_default_copies:
        if sha1 == PINNED_SHA1:
            copies += [Copy(*c) for c in PINNED_COPIES]
        else:
            sys.stderr.write("warning: ROM SHA-1 %s is not the pinned %s: no default copies; "
                             "pass --copy for each code copy\n" % (sha1, PINNED_SHA1))

    tables = scan(rom, copies)
    out = sys.stdout
    try:
        if args.toml:
            toml_entries(tables, sha1, out)
            return 0
        if args.check_config:
            return 0 if check_config(tables, args.check_config, out) else 1
        out.write("ROM %s: %d bytes, SHA-1 %s%s\n" % (
            os.path.basename(args.rom), len(rom), sha1, " (pinned)" if sha1 == PINNED_SHA1 else ""))
        for c in copies:
            out.write("copy %s: 0x%08X-0x%08X runs at 0x%08X\n"
                      % (c.name, c.source, c.source + c.size - 1, c.runtime))
        out.write("\n")
        report(tables, out)
    except Error as e:
        sys.stderr.write("error: %s\n" % e)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
