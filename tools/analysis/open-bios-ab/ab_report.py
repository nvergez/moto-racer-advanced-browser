#!/usr/bin/env python3
"""Compare open-BIOS A/B runs written by run_ab.sh (stdlib only).

usage: ab_report.py OUTDIR [--pair A B ...] [--routes R ...]

OUTDIR is run_ab.sh's output directory (OUTDIR/VARIANT/ROUTE/...). Prints, per
route and per variant, the metrics of docs/research/open-bios-ab.md, then for
each pair (default: retail-skip/cult-skip and retail-boot/cult-boot) where the
two runs first differ. It prints numbers only: no frames, no RAM contents
beyond the race-time words and no screenshots, so its output can be quoted in
the docs.

Frames are reported as "retail-equivalent" frames: the harness frame minus the
variant's shift (handoff.tsv), so frame numbers line up with the retail-boot
timeline in ../input/*.txt (race display from 3303 on boot_to_race, etc.).

Metrics:
  swi        SWI calls by function (summary.json)
  divarm     DivArm calls (r0 = divisor, r1 = numerator at entry): total, divisor
             zero, divisor negative, divisor negative with a nonzero remainder
             (where Cult-of-GBA's remainder sign differs from retail's), numerator
             negative with a nonzero remainder
  vbiw       VBlankIntrWait calls per frame; frames with none inside the front-end
             stretch (first to last call); frames whose count differs in a pair
  race loop  iterations of the race main loop (start 0x03001CFC, end of work
             0x03001D6C): lag frames (no iteration starting in a frame inside the
             race), frames with two starts, work per iteration in scanlines
             (start to end, counted from VCOUNT 160)
  biosreads  game loads from 0x0-0x3FFF and the values they returned
  results    race display (DISPCNT 0x1741) stretches and, at the last frame of
             each, the lap words at 0x0201A370-0x0201A37F (lap 1-3, best lap, in
             frames)
  swi cycles cycles from each SWI to its return (swicycles.tsv; IRQs taken during
             the call are included, and VBlankIntrWait is a wait, not a cost), per
             function; in a pair, calls with the same caller and r0-r2 are matched
             in order and their cycle differences summarized
  calls      in a pair, the last frame up to which both runs made the same calls:
             equal multisets of (caller, function, r0, r1, r2), VBlankIntrWait
             aside (r3 is not an argument of the SWIs this game uses, and its
             value differs after CpuFastSet)
  save       SHA-1 of game.sav (options_save)
  divergence first frame where trace.tsv differs in a pair, per column group
"""
import argparse
import collections
import hashlib
import json
import os
import statistics
import sys
import zlib

LINES = 228
RACE_DISPCNT = "1741"
LOOP_START = "03001CFC"
LOOP_END = "03001D6C"
LAP_COLS = ["mem_0201A370", "mem_0201A374", "mem_0201A378", "mem_0201A37C"]
GROUPS = {
    "video": ["DISPCNT", "BG0CNT", "BG1CNT", "BG2CNT", "BG3CNT", "BLDCNT", "crc_vram_00000_09FFF",
              "crc_vram_0A000_13FFF", "crc_vram_10000_17FFF", "crc_pal", "crc_oam"],
    "iwram_0000_6FFF": ["crc_iwram_0000_6FFF"],
    "iwram_7000_7FFF": ["crc_iwram_7000_7FFF"],
    "ewram": ["crc_ewram"],
    "keys": ["keys"],
}


def s32(h):
    v = int(h, 16)
    return v - (1 << 32) if v & 0x80000000 else v


def read_tsv(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        head = None
        rows = []
        for line in f:
            if line.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if head is None:
                head = parts
                continue
            rows.append(dict(zip(head, parts)))
        return rows


class Run:
    def __init__(self, outdir, variant, route):
        self.variant = variant
        self.route = route
        self.dir = os.path.join(outdir, variant, route)
        self.ok = os.path.exists(os.path.join(self.dir, "summary.json"))
        if not self.ok:
            return
        with open(os.path.join(self.dir, "summary.json")) as f:
            self.summary = json.load(f)
        self.shift = 0
        hp = os.path.join(outdir, variant, "handoff.tsv")
        if os.path.exists(hp):
            with open(hp) as f:
                parts = f.read().split()
                self.handoff = int(parts[2])
                self.shift = int(parts[4])
        self.swi = read_tsv(os.path.join(self.dir, "swi.tsv"))
        self.trace = read_tsv(os.path.join(self.dir, "trace.tsv"))
        self.pc = read_tsv(os.path.join(self.dir, "pctrace.tsv"))
        self.reads = read_tsv(os.path.join(self.dir, "biosreads.tsv"))
        self.swic = read_tsv(os.path.join(self.dir, "swicycles.tsv"))

    def eq(self, frame):
        """Harness frame -> retail-equivalent frame."""
        return int(frame) - self.shift


def divarm(run):
    c = collections.Counter({"total": 0, "divisor_zero": 0, "divisor_negative": 0,
                             "divisor_negative_remainder_nonzero": 0, "numerator_negative_remainder_nonzero": 0})
    lo_d = lo_n = None
    for r in run.swi:
        if r["name"] != "DivArm":
            continue
        d, n = s32(r["r0"]), s32(r["r1"])
        c["total"] += 1
        lo_d = d if lo_d is None else min(lo_d, d)
        lo_n = n if lo_n is None else min(lo_n, n)
        if d == 0:
            c["divisor_zero"] += 1
            continue
        rem = abs(n) % abs(d)  # truncated remainder magnitude
        if d < 0:
            c["divisor_negative"] += 1
            if rem:
                c["divisor_negative_remainder_nonzero"] += 1
        if n < 0 and rem:
            c["numerator_negative_remainder_nonzero"] += 1
    out = dict(c)
    out["min_divisor"], out["min_numerator"] = lo_d, lo_n
    return out


def vbiw_per_frame(run):
    c = collections.Counter()
    for r in run.swi:
        if r["name"] == "VBlankIntrWait":
            c[run.eq(r["frame"])] += 1
    return c


def vbiw_stats(run):
    c = vbiw_per_frame(run)
    if not c:
        return {}
    lo, hi = min(c), max(c)
    none = [f for f in range(lo, hi + 1) if f not in c]
    return {"calls": sum(c.values()), "first": lo, "last": hi, "frames_with_call": len(c),
            "frames_without_call_inside": len(none), "frames_with_2plus": sum(1 for v in c.values() if v >= 2)}


def race_iterations(run):
    """[(start_eq_frame, start_vcount, work_lines or None)] in order."""
    its = []
    for r in run.pc:
        f, v = run.eq(r["frame"]), int(r["vcount"])
        if r["pc"] == LOOP_START:
            its.append([f, v, None])
        elif r["pc"] == LOOP_END and its and its[-1][2] is None:
            sf, sv = its[-1][0], its[-1][1]
            pos = lambda vv: (vv - 160) % LINES
            its[-1][2] = (f - sf) * LINES + pos(v) - pos(sv)
    return its


def segments(frames, gap=60):
    """Split sorted frames into stretches separated by more than gap frames."""
    segs = []
    for f in frames:
        if segs and f - segs[-1][-1] <= gap:
            segs[-1].append(f)
        else:
            segs.append([f])
    return segs


def race_stats(run):
    its = race_iterations(run)
    if not its:
        return {}
    starts = collections.Counter(i[0] for i in its)
    segs = segments(sorted(starts))
    lag = []
    for s in segs:
        lag += [f for f in range(s[0], s[-1] + 1) if f not in starts]
    work = [i[2] for i in its if i[2] is not None]
    return {"iterations": len(its), "stretches": [(s[0], s[-1]) for s in segs], "lag_frames": len(lag),
            "lag_frame_list": lag[:20], "frames_with_2_starts": sum(1 for v in starts.values() if v >= 2),
            "work_lines_min": min(work) if work else None, "work_lines_mean": round(statistics.mean(work), 2) if work else None,
            "work_lines_max": max(work) if work else None,
            "iterations_over_228_lines": sum(1 for w in work if w > LINES)}


def race_results(run):
    out = []
    rows = run.trace
    stretch = None
    for i, r in enumerate(rows):
        on = r.get("DISPCNT") == RACE_DISPCNT
        if on and stretch is None:
            stretch = i
        if stretch is not None and (not on or i == len(rows) - 1):
            last = rows[i - 1] if not on else r
            laps = [int(last[c], 16) for c in LAP_COLS if c in last]
            out.append({"race_display": (run.eq(rows[stretch]["frame"]), run.eq(last["frame"])),
                        "laps_frames": laps[:3], "best_lap_frames": laps[3] if len(laps) > 3 else None,
                        "race_frames": sum(laps[:3]) if len(laps) >= 3 else None})
            stretch = None
    return out


def bios_reads(run):
    vals = collections.Counter()
    pcs = collections.Counter()
    for r in run.reads:
        vals[(r["size"], r["value"])] += 1
        pcs[r["pc"]] += 1
    return {"loads": run.summary.get("bios_region_game_loads", len(run.reads)), "logged": len(run.reads),
            "by_size_value": dict(sorted(((f"{s}:{v}", n) for (s, v), n in vals.items()), key=lambda x: -x[1])),
            "by_pc": dict(sorted(pcs.items(), key=lambda x: -x[1]))}


def swi_cycles(run):
    by = collections.defaultdict(list)
    for r in run.swic:
        by[r["name"]].append(int(r["cycles"]))
    return {k: {"calls": len(v), "median": statistics.median(v), "mean": round(statistics.mean(v), 1), "max": max(v)}
            for k, v in sorted(by.items())}


def pair_swi_cycles(a, b):
    """Match calls with the same (caller, function, r0-r2) in order; summarize b - a cycles per function."""
    def keyed(run):
        q = collections.defaultdict(list)
        for r in run.swic:
            q[(r["pc"], r["name"], r["r0"], r["r1"], r["r2"])].append(int(r["cycles"]))
        return q
    qa, qb = keyed(a), keyed(b)
    diffs = collections.defaultdict(list)
    for k, va in qa.items():
        for x, y in zip(va, qb.get(k, [])):
            diffs[k[1]].append(y - x)
    out = {}
    for name, d in sorted(diffs.items()):
        out[name] = {"paired": len(d), "median_diff": statistics.median(d), "mean_diff": round(statistics.mean(d), 1),
                     "min_diff": min(d), "max_diff": max(d), "equal": sum(1 for x in d if x == 0)}
    return out


def save_sha1(run):
    p = os.path.join(run.dir, "game.sav")
    if not os.path.exists(p):
        return None
    with open(p, "rb") as f:
        b = f.read()
    return {"bytes": len(b), "sha1": hashlib.sha1(b).hexdigest(), "nonzero_bytes": sum(1 for x in b if x)}


def first_divergence(a, b):
    ta = {a.eq(r["frame"]): r for r in a.trace}
    tb = {b.eq(r["frame"]): r for r in b.trace}
    common = sorted(set(ta) & set(tb))
    res = {"compared_frames": len(common), "range": (common[0], common[-1]) if common else None}
    for g, cols in GROUPS.items():
        diff = [f for f in common if any(ta[f].get(c) != tb[f].get(c) for c in cols)]
        res[g] = {"first": diff[0] if diff else None, "frames_differing": len(diff), "ranges": ranges(diff)}
    return res


RANGE_LIMIT = 12


def ranges(frames, limit=None):
    """Compress sorted frames into "a-b" strings, at most limit (default RANGE_LIMIT) of them."""
    limit = limit or RANGE_LIMIT
    out = []
    for f in frames:
        if out and f == out[-1][1] + 1:
            out[-1][1] = f
        else:
            out.append([f, f])
    text = [f"{a}-{b}" if a != b else f"{a}" for a, b in out[:limit]]
    if len(out) > limit:
        text.append(f"... {len(out) - limit} more")
    return text


def handoff(outdir, variant):
    """The handoff dump of run_ab.sh's probe: frame, vcount, CPU and I/O state, RAM CRCs."""
    base = os.path.join(outdir, variant, "handoff", "dumps")
    if not os.path.isdir(base):
        return None
    d = [x for x in os.listdir(base) if x.endswith("_pc08000000")]
    if not d:
        return None
    d = os.path.join(base, d[0])
    with open(os.path.join(d, "io.json")) as f:
        io = json.load(f)
    with open(os.path.join(d, "cpu.json")) as f:
        cpu = json.load(f)
    crcs = {}
    for name in ("iwram.bin", "ewram.bin", "vram.bin", "palette.bin", "oam.bin"):
        with open(os.path.join(d, name), "rb") as f:
            b = f.read()
        crcs[name] = {"crc32": "%08X" % zlib.crc32(b), "nonzero_bytes": sum(1 for x in b if x)}
    return {"dir": os.path.basename(d), "regs": io["regs"], "cpu": cpu, "ram": crcs}


def pair_handoff(outdir, x, y):
    hx, hy = handoff(outdir, x), handoff(outdir, y)
    if not hx or not hy:
        return None
    regs = {k: (hx["regs"][k], hy["regs"].get(k)) for k in hx["regs"] if hx["regs"][k] != hy["regs"].get(k)}
    cpu = {k: (hx["cpu"][k], hy["cpu"][k]) for k in ("next_pc", "thumb", "cpsr", "gprs") if hx["cpu"][k] != hy["cpu"][k]}
    ram = {k: (hx["ram"][k], hy["ram"][k]) for k in hx["ram"] if hx["ram"][k] != hy["ram"][k]}
    return {"a": hx["dir"], "b": hy["dir"], "io_regs_differing": regs, "cpu_differing": cpu, "ram_differing": ram}


def pair_vbiw(a, b):
    ca, cb = vbiw_per_frame(a), vbiw_per_frame(b)
    frames = sorted(set(ca) | set(cb))
    diff = [f for f in frames if ca.get(f, 0) != cb.get(f, 0)]
    return {"frames_differing": len(diff), "first": diff[:10]}


def pair_swi_sequence(a, b):
    """First SWI call whose (eq frame, vcount, function, r0-r3) differs."""
    for i, (x, y) in enumerate(zip(a.swi, b.swi)):
        kx = (a.eq(x["frame"]), x["vcount"], x["name"], x["r0"], x["r1"], x["r2"], x["r3"])
        ky = (b.eq(y["frame"]), y["vcount"], y["name"], y["r0"], y["r1"], y["r2"], y["r3"])
        if kx != ky:
            return {"index": i, "a": kx, "b": ky,
                    "same_args_ignoring_vcount": (kx[0], kx[2:]) == (ky[0], ky[2:])}
    return {"index": None, "calls_a": len(a.swi), "calls_b": len(b.swi)}


def pair_calls(a, b):
    """Last frame at which the cumulative multisets of calls (VBlankIntrWait aside) are equal."""
    def per_frame(run):
        q = collections.defaultdict(collections.Counter)
        for r in run.swi:
            if r["name"] != "VBlankIntrWait":
                q[run.eq(r["frame"])][(r["pc"], r["name"], r["r0"], r["r1"], r["r2"])] += 1
        return q
    qa, qb = per_frame(a), per_frame(b)
    end = min(a.eq(a.summary["end_frame"]), b.eq(b.summary["end_frame"]))
    ca, cb = collections.Counter(), collections.Counter()
    last_equal, calls = None, 0
    for f in sorted(set(qa) | set(qb)):
        if f > end:
            break
        ca.update(qa.get(f, {}))
        cb.update(qb.get(f, {}))
        if ca == cb:
            last_equal, calls = f, sum(ca.values())
    return {"last_frame_equal": last_equal, "calls_up_to_it": calls, "run_end": end}


def pair_race(a, b):
    ia = {i[0]: i for i in race_iterations(a)}
    ib = {i[0]: i for i in race_iterations(b)}
    common = sorted(f for f in set(ia) & set(ib) if ia[f][2] is not None and ib[f][2] is not None)
    if not common:
        return {}
    d = [ib[f][2] - ia[f][2] for f in common]
    return {"paired_iterations": len(common), "work_diff_lines_min": min(d), "work_diff_lines_max": max(d),
            "work_diff_lines_mean": round(statistics.mean(d), 3),
            "iterations_with_diff": sum(1 for x in d if x),
            "start_vcount_differs": sum(1 for f in common if ia[f][1] != ib[f][1])}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("outdir")
    ap.add_argument("--pair", nargs=2, action="append")
    ap.add_argument("--routes", nargs="*")
    ap.add_argument("--range-limit", type=int, default=12, help="differing-frame ranges printed per group")
    a = ap.parse_args()
    global RANGE_LIMIT
    RANGE_LIMIT = a.range_limit
    pairs = a.pair or [["retail-skip", "cult-skip"], ["retail-boot", "cult-boot"]]
    variants = sorted({v for p in pairs for v in p} | {d for d in os.listdir(a.outdir) if os.path.isdir(os.path.join(a.outdir, d))})
    routes = a.routes or sorted({r for v in variants if os.path.isdir(os.path.join(a.outdir, v))
                                 for r in os.listdir(os.path.join(a.outdir, v))
                                 if os.path.exists(os.path.join(a.outdir, v, r, "script.txt"))})
    print("## handoff (first instruction at 0x08000000)")
    for x, y in pairs:
        ph = pair_handoff(a.outdir, x, y)
        if ph:
            print(f"### pair {x} vs {y}")
            print("handoff:", json.dumps(ph))
    print()
    for route in routes:
        print(f"## {route}")
        runs = {v: Run(a.outdir, v, route) for v in variants}
        for v, r in runs.items():
            if not r.ok:
                continue
            s = r.summary
            print(f"### {v} (shift {r.shift}, end frame {r.eq(s['end_frame'])})")
            print("swi:", json.dumps(s.get("swi_counts")))
            print("log_counts:", json.dumps(s.get("log_counts")))
            print("divarm:", json.dumps(divarm(r)))
            print("vblankintrwait:", json.dumps(vbiw_stats(r)))
            rs = race_stats(r)
            if rs:
                print("race_loop:", json.dumps(rs))
            for res in race_results(r):
                print("race_result:", json.dumps(res))
            if r.swic:
                print("swi_cycles:", json.dumps(swi_cycles(r)))
            br = bios_reads(r)
            print("bios_reads:", json.dumps(br))
            sv = save_sha1(r)
            if sv:
                print("save:", json.dumps(sv))
        for x, y in pairs:
            if runs.get(x) and runs.get(y) and runs[x].ok and runs[y].ok:
                print(f"### pair {x} vs {y}")
                print("divergence:", json.dumps(first_divergence(runs[x], runs[y])))
                print("swi_sequence:", json.dumps(pair_swi_sequence(runs[x], runs[y])))
                print("vblankintrwait_per_frame:", json.dumps(pair_vbiw(runs[x], runs[y])))
                print("calls:", json.dumps(pair_calls(runs[x], runs[y])))
                if runs[x].swic and runs[y].swic:
                    print("swi_cycles_pair:", json.dumps(pair_swi_cycles(runs[x], runs[y])))
                pr = pair_race(runs[x], runs[y])
                if pr:
                    print("race_loop_pair:", json.dumps(pr))
        print()


if __name__ == "__main__":
    sys.exit(main())
