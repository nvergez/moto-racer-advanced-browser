#!/usr/bin/env python3
"""Find which parts of a RAM dump are verbatim copies of ROM bytes.

usage: ram_sources.py ROM.gba DUMP.bin --base 0x03000000 [--min 64] [--coverage coverage.tsv]

Prints maximal runs "RAM start-end <- ROM start (length)" where the dump equals
ROM bytes exactly, using the anchor-and-extend method: every 64-byte aligned
window that is not mostly zero/0xFF is looked up in the ROM, and each hit is
extended byte by byte in both directions. Runs shorter than --min are dropped.
With --coverage (from gbaharness --coverage), also prints how many executed
RAM instruction addresses fall inside each run.

Use the output to create Ghidra byte-mapped blocks/overlays
(MapRomCopy.java) instead of importing RAM dumps. Stdlib only.
"""
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("dump")
    ap.add_argument("--base", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--min", type=int, default=64)
    ap.add_argument("--coverage")
    a = ap.parse_args()
    rom = open(a.rom, "rb").read()
    ram = open(a.dump, "rb").read()
    win = 64
    runs = []
    covered_until = 0
    for off in range(0, len(ram) - win + 1, win):
        if off < covered_until:
            continue
        chunk = ram[off:off + win]
        if chunk.count(0) > win * 3 // 4 or chunk.count(0xFF) > win * 3 // 4:
            continue
        best = None
        p = rom.find(chunk)
        tries = 0
        while p >= 0 and tries < 64:
            s, r = off, p
            while s > 0 and r > 0 and ram[s - 1] == rom[r - 1]:
                s -= 1
                r -= 1
            e, q = off + win, p + win
            while e < len(ram) and q < len(rom) and ram[e] == rom[q]:
                e += 1
                q += 1
            if best is None or e - s > best[1] - best[0]:
                best = (s, e, r)
            p = rom.find(chunk, p + 1)
            tries += 1
        if best and best[1] - best[0] >= a.min:
            runs.append(best)
            covered_until = best[1]
    executed = []
    if a.coverage:
        for line in open(a.coverage):
            f = line.split("\t")
            if f[0] == "addr":
                continue
            addr = int(f[0], 16)
            if a.base <= addr < a.base + len(ram):
                executed.append(addr - a.base)
    print("ram_start\tram_end_incl\trom_start\tlength\texecuted_addrs_inside")
    for s, e, r in runs:
        n = sum(1 for x in executed if s <= x < e)
        print("0x%08X\t0x%08X\t0x%08X\t0x%X\t%s" % (a.base + s, a.base + e - 1, 0x08000000 + r, e - s,
                                                    n if a.coverage else "-"))
    if a.coverage:
        inside = sum(1 for x in executed if any(s <= x < e for s, e, _ in runs))
        print("# executed RAM addresses: %d, inside ROM-copied runs: %d" % (len(executed), inside))


if __name__ == "__main__":
    main()
