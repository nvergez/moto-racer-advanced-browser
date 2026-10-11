"""Unit tests for tools/seeds/find_switch_tables.py (no game data).

Every ROM here is assembled from hand-encoded ARM words.
Run: python3 -I -m unittest discover tools/seeds/tests
"""
import io
import os
import struct
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import find_switch_tables as fst  # noqa: E402

BASE = fst.ROM_BASE
NOP = 0xE1A00000  # mov r0, r0


def cmp_imm(rn, imm, cond=0xE):
    assert imm < 256
    return (cond << 28) | 0x03500000 | (rn << 16) | imm


def add_pc(rm, cond=0x9):
    return (cond << 28) | 0x008FF100 | rm


def b(at, target, cond=0xE, link=False):
    off = ((target - (at + 8)) >> 2) & 0x00FFFFFF
    return (cond << 28) | 0x0A000000 | (0x01000000 if link else 0) | off


def mov_imm(rd, imm, s=False):
    return 0xE3A00000 | (0x00100000 if s else 0) | (rd << 12) | imm


def ldr_imm(rd, rn, off=0):
    return 0xE5900000 | (rn << 16) | (rd << 12) | off


class Rom(object):
    """A ROM image built word by word at BASE."""

    def __init__(self, words=0x400):
        self.words = [NOP] * words

    def put(self, addr, *ws):
        i = (addr - BASE) // 4
        for k, w in enumerate(ws):
            self.words[i + k] = w
        return addr + 4 * len(ws)

    def switch(self, at, rm, cases, between=(), targets=None, cond=0x9, bound=None):
        """cmp rm, #bound; between...; add<cond> pc, pc, rm, lsl #2; b default; slots.

        Returns the dispatcher's address. Targets default to the words after
        the table; the default case goes to the first of them.
        """
        if bound is None:
            bound = cases - 1 if cond == 0x9 else cases
        a = self.put(at, cmp_imm(rm, bound), *between)
        disp = a
        end = disp + 8 + 4 * cases
        targets = targets or [end + 4 * i for i in range(cases)]
        self.put(disp, add_pc(rm, cond), b(disp + 4, end))
        for i, t in enumerate(targets):
            self.put(disp + 8 + 4 * i, b(disp + 8 + 4 * i, t))
        return disp

    def bytes(self):
        return b"".join(struct.pack("<I", w) for w in self.words)


def scan(rom, copies=()):
    return fst.scan(rom.bytes(), list(copies))


class Decoding(unittest.TestCase):

    def test_dispatcher(self):
        self.assertEqual(fst.is_dispatcher(0x908FF101), 1)
        self.assertEqual(fst.is_dispatcher(0x908FF10E), 14)
        self.assertIsNone(fst.is_dispatcher(0x908FF181))  # lsl #3
        self.assertIsNone(fst.is_dispatcher(0x909FF101))  # adds
        self.assertIsNone(fst.is_dispatcher(0xF08FF101))  # nv

    def test_cmp_rotated_immediate(self):
        # cmp r2, #0x100: imm8 1 rotated right by 24.
        self.assertEqual(fst.decode_cmp_imm(0xE3520C01), (0xE, 2, 0x100))
        self.assertIsNone(fst.decode_cmp_imm(0xE1520003))  # cmp r2, r3

    def test_branch(self):
        self.assertEqual(fst.decode_branch(b(0x08000100, 0x08000040), 0x08000100),
                         (0xE, False, 0x08000040))
        self.assertEqual(fst.decode_branch(b(0x08000100, 0x08000200, link=True), 0x08000100),
                         (0xE, True, 0x08000200))

    def test_effects(self):
        self.assertEqual(fst.effects(mov_imm(3, 1)), (True, {3}, False, False))
        self.assertEqual(fst.effects(mov_imm(3, 1, s=True)), (True, {3}, True, False))
        self.assertEqual(fst.effects(ldr_imm(0, 4, 0xC)), (True, {0}, False, False))
        self.assertTrue(fst.effects(cmp_imm(5, 1))[2])
        self.assertTrue(fst.effects(0xE12FFF1E)[3])            # bx lr
        self.assertEqual(fst.effects(0xE92D4010)[1], {13})     # push {r4, lr}
        self.assertTrue(fst.effects(0xE8BD8010)[3])            # pop {r4, pc}
        self.assertFalse(fst.effects(0xEF000005)[0])           # swi
        self.assertFalse(fst.effects(0xE129F000)[0])           # msr cpsr_fc, r0
        self.assertEqual(fst.effects(0xE4931004)[1], {1, 3})   # ldr r1, [r3], #4

    def test_effects_halfword(self):
        self.assertEqual(fst.effects(0xE1C010B0), (True, set(), False, False))  # strh r1, [r0]
        self.assertEqual(fst.effects(0xE1D010B0), (True, {1}, False, False))    # ldrh r1, [r0]
        self.assertEqual(fst.effects(0xE1D010F0), (True, {1}, False, False))    # ldrsh r1, [r0]
        self.assertEqual(fst.effects(0xE0C010B2)[1], {0})                       # strh r1, [r0], #2
        # L clear with SH 10 or 11: ldrd/strd on ARMv5TE, unpredictable on
        # ARMv4T. Unknown, so the walk to the cmp stops there.
        self.assertFalse(fst.effects(0xE1C020D0)[0])  # ldrd r2, [r0]
        self.assertFalse(fst.effects(0xE1C020F0)[0])  # strd r2, [r0]


class Scan(unittest.TestCase):

    def test_adjacent_cmp(self):
        rom = Rom()
        disp = rom.switch(0x08000100, rm=1, cases=3)
        [t] = scan(rom)
        self.assertTrue(t.ok, t.problems)
        self.assertEqual((t.addr, t.rm, t.cmp_addr, t.bound, t.count),
                         (disp, 1, disp - 4, 2, 3))
        self.assertEqual([t.slot(i) for i in range(3)], [disp + 8, disp + 12, disp + 16])
        self.assertEqual(t.targets, [disp + 20, disp + 24, disp + 28])
        self.assertEqual(t.default_target, disp + 20)
        self.assertEqual(t.reviews, [])

    def test_cc_condition_has_bound_slots(self):
        rom = Rom()
        rom.switch(0x08000100, rm=2, cases=4, cond=0x3)
        [t] = scan(rom)
        self.assertTrue(t.ok, t.problems)
        self.assertEqual((t.bound, t.count), (4, 4))

    def test_lookback_over_harmless_instructions(self):
        # The prologue form: cmp, then loads and moves of other registers.
        rom = Rom()
        between = (mov_imm(14, 4), ldr_imm(3, 15), mov_imm(12, 1), ldr_imm(0, 0))
        disp = rom.switch(0x08000100, rm=4, cases=5, between=between)
        [t] = scan(rom)
        self.assertTrue(t.ok, t.problems)
        self.assertEqual((t.cmp_addr, t.count), (disp - 20, 5))

    def test_barriers_between_cmp_and_dispatcher(self):
        cases = {
            "flags": mov_imm(3, 1, s=True),
            "write": mov_imm(4, 1),
            "branch": 0xE12FFF1E,
            "conditional": 0x03A03001,  # moveq r3, #1
            "unmodeled": 0xEF000005,     # swi
            "ldrd": 0xE1C030D0,          # ldrd r3, [r0] on v5TE: writes r3 and r4
            "other cmp": cmp_imm(3, 1),
        }
        for name, w in cases.items():
            with self.subTest(name):
                rom = Rom()
                rom.switch(0x08000100, rm=4, cases=3, between=(w,))
                [t] = scan(rom)
                self.assertFalse(t.ok)
                self.assertIsNone(t.cmp_addr)
                self.assertEqual(t.count, 0)

    def test_no_cmp_in_reach(self):
        rom = Rom()
        rom.put(0x08000100, add_pc(1), b(0x08000104, 0x08000200))
        [t] = scan(rom)
        self.assertFalse(t.ok)
        self.assertIn("no cmp", t.problems[0])

    def test_conditional_cmp_rejected(self):
        rom = Rom()
        rom.put(0x08000100, cmp_imm(1, 2, cond=0x0), add_pc(1))
        [t] = scan(rom)
        self.assertIn("conditional", t.problems[0])

    def test_unconditional_add_pc_rejected(self):
        rom = Rom()
        rom.switch(0x08000100, rm=1, cases=3, cond=0xE)
        [t] = scan(rom)
        self.assertFalse(t.ok)
        self.assertIn("not ls or cc", t.problems[0])

    def test_slot_not_a_b(self):
        for name, w in (("bl", None), ("mov", NOP), ("conditional b", None)):
            with self.subTest(name):
                rom = Rom()
                disp = rom.switch(0x08000100, rm=1, cases=3)
                slot = disp + 12
                if name == "bl":
                    w = b(slot, 0x08000200, link=True)
                elif name == "conditional b":
                    w = b(slot, 0x08000200, cond=0x0)
                rom.put(slot, w)
                [t] = scan(rom)
                self.assertFalse(t.ok)
                self.assertIn("case slot 1", t.problems[0])

    def test_default_slot_must_be_a_b(self):
        rom = Rom()
        disp = rom.switch(0x08000100, rm=1, cases=3)
        rom.put(disp + 4, NOP)
        [t] = scan(rom)
        self.assertIn("default slot", t.problems[0])

    def test_target_out_of_rom(self):
        rom = Rom()
        rom.switch(0x08000100, rm=1, cases=2, targets=[0x08000200, 0x09000000])
        [t] = scan(rom)
        self.assertIn("out of its region", t.problems[0])

    def test_word_after_table_is_b_is_reviewed(self):
        rom = Rom()
        disp = rom.switch(0x08000100, rm=1, cases=3)
        rom.put(disp + 8 + 12, b(disp + 20, 0x08000300))
        [t] = scan(rom)
        self.assertTrue(t.ok, t.problems)
        self.assertEqual(len(t.reviews), 1)
        self.assertIn("check the bound", t.reviews[0])

    def test_branch_into_window_is_reviewed(self):
        rom = Rom()
        disp = rom.switch(0x08000100, rm=1, cases=3, between=(ldr_imm(0, 4),))
        rom.put(0x08000400, b(0x08000400, disp - 4))  # into the ldr
        rom.put(0x08000404, b(0x08000404, disp, link=True))  # onto the addls
        rom.put(0x08000408, b(0x08000408, disp - 8))  # onto the cmp: fine
        [t] = scan(rom)
        self.assertTrue(t.ok, t.problems)
        self.assertEqual(len(t.reviews), 2)
        self.assertIn("0x08000400", t.reviews[0])
        self.assertIn("0x08000404", t.reviews[1])

    def test_copies(self):
        # A table inside a copied range: runtime addresses, not a ROM candidate,
        # and its targets must stay inside the copy.
        rom = Rom()
        disp = rom.switch(0x08000800, rm=0, cases=2)
        copy = fst.Copy("img", 0x08000700, 0x200, 0x03000000)
        [t] = scan(rom, [copy])
        self.assertTrue(t.ok, t.problems)
        self.assertIs(t.region, copy)
        self.assertEqual(t.runtime(disp), 0x03000000 + disp - 0x08000700)
        rom.put(disp + 8, b(disp + 8, 0x08000100))  # out of the copy
        [t] = scan(rom, [copy])
        self.assertIn("out of its region", t.problems[0])

    def test_rom_target_inside_a_copy_rejected(self):
        rom = Rom()
        rom.switch(0x08000100, rm=0, cases=2, targets=[0x08000200, 0x08000800])
        [t] = scan(rom, [fst.Copy("img", 0x08000700, 0x200, 0x03000000)])
        self.assertIn("out of its region", t.problems[0])

    def test_table_across_copy_boundary(self):
        rom = Rom()
        rom.switch(0x08000100, rm=0, cases=4)
        [t] = scan(rom, [fst.Copy("img", 0x08000110, 0x100, 0x03000000)])
        self.assertIn("crosses a copy boundary", t.problems[0])

    def test_unaligned_words_ignored(self):
        rom = Rom()
        raw = bytearray(rom.bytes())
        raw[0x102:0x106] = struct.pack("<I", add_pc(1))
        self.assertEqual(fst.scan(bytes(raw)), [])


class Output(unittest.TestCase):
    SHA1 = "0" * 40
    COPY = ("img", 0x08000700, 0x200, 0x03000000)

    def tables(self, unsized=True):
        rom = Rom()
        rom.switch(0x08000100, rm=1, cases=3)
        rom.switch(0x08000200, rm=2, cases=2, between=(ldr_imm(0, 4),))
        rom.switch(0x08000800, rm=0, cases=2)  # in the copy below
        if unsized:
            rom.put(0x08000300, add_pc(3))     # rejected: no cmp
        return rom, scan(rom, [fst.Copy(*self.COPY)])

    def test_report(self):
        _, tables = self.tables()
        out = io.StringIO()
        fst.report(tables, out)
        text = out.getvalue()
        self.assertIn("4 dispatchers (add pc, pc, rM, lsl 2): 2 tables in ROM code with 5 case slots, "
                      "1 in copied code with 2 case slots (img), 1 rejected, 0 to review", text)
        self.assertIn("img 0x03000104", text)
        self.assertIn("REJECTED", text)

    def toml(self, tables):
        out = io.StringIO()
        fst.toml_entries(tables, self.SHA1, out)
        return out.getvalue()

    def test_toml_entries(self):
        if sys.version_info < (3, 11):
            self.skipTest("needs tomllib")
        import tomllib
        _, tables = self.tables()
        text = self.toml(tables)
        entries = tomllib.loads(text)["extra_func"]
        self.assertEqual([e["addr"] for e in entries],
                         [0x0800010C, 0x08000110, 0x08000114, 0x08000210, 0x08000214])
        self.assertEqual(set(e["mode"] for e in entries), {"arm"})
        for e in entries:
            self.assertTrue(e["note"].startswith("ROM SHA-1 %s. " % self.SHA1))
            self.assertRegex(e["note"], fst.CASE_NOTE_RE)
        self.assertIn("Case slot 1 of 2 of the armcc switch at 0x08000208", entries[4]["note"])
        self.assertIn("bounded by cmp r2, 1 at 0x08000200", entries[4]["note"])
        # gbarecomp's runtime reads game.toml line by line and drops
        # everything after '#', so no value may hold one.
        for line in text.splitlines():
            if not line.startswith("#"):
                self.assertNotIn("#", line)

    def test_toml_shows_rejected_rom_tables(self):
        _, tables = self.tables()
        text = self.toml(tables)
        self.assertIn("2 tables in ROM code, 5 case slots;\n"
                      "# 1 dispatchers in ROM code rejected, 0 tables flagged for review.", text)
        self.assertIn("\n# REJECTED: the addls pc, pc, r3, lsl 2 at 0x08000300, no entries: no cmp", text)
        # In address order, between the two tables.
        self.assertLess(text.index("0x08000208"), text.index("REJECTED"))
        self.assertNotIn("0x08000800", text)  # the table in the copy

    def check(self, tables, body, copies=None):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "game.toml")
            with open(path, "w") as f:
                f.write(body)
            out = io.StringIO()
            copies = [fst.Copy(*self.COPY)] if copies is None else copies
            return fst.check_config(tables, copies, self.SHA1, path, out), out.getvalue()

    def test_check_config(self):
        if sys.version_info < (3, 11):
            self.skipTest("needs tomllib")
        _, tables = self.tables(unsized=False)
        text = "# A hand-written comment above the section.\n\n" + self.toml(tables) + "\n# After.\n"

        ok, msg = self.check(tables, text)
        self.assertTrue(ok, msg)
        self.assertIn("ok: 5 candidate slots, 5 entries noted as case slots, "
                      "0 rejected and 0 to review in ROM code, 0 problem(s)", msg)

        # One slot left out.
        cut = text.index("[[extra_func]]\naddr = 0x08000110")
        nxt = text.index("[[extra_func]]", cut + 1)
        ok, msg = self.check(tables, text[:cut] + text[nxt:])
        self.assertFalse(ok)
        self.assertIn("missing: no [[extra_func]] at case slot 0x08000110", msg)
        self.assertIn("FAIL: ", msg)

        # A slot declared in Thumb.
        ok, msg = self.check(tables, text.replace('addr = 0x08000114\nmode = "arm"',
                                                  'addr = 0x08000114\nmode = "thumb"'))
        self.assertFalse(ok)
        self.assertIn("0x08000114 is declared 1 time(s), as thumb", msg)

        # An entry noted as a case slot that the scan does not find.
        extra = ('\n[[extra_func]]\naddr = 0x08000400\nmode = "arm"\n'
                 'note = "Case slot 0 of 1 of the armcc switch at 0x080003F8"\n')
        ok, msg = self.check(tables, text + extra)
        self.assertFalse(ok)
        self.assertIn("extra: the note of 0x08000400", msg)

    def test_check_config_notes_and_text(self):
        if sys.version_info < (3, 11):
            self.skipTest("needs tomllib")
        _, tables = self.tables(unsized=False)
        text = self.toml(tables)
        # A wrong b target, slot index or ROM SHA-1 in a note.
        for old, new in (("the slot is b 0x0800021C", "the slot is b 0x08000220"),
                         ("for index 0, and the slot is b 0x08000218",
                          "for index 1, and the slot is b 0x08000218"),
                         ("ROM SHA-1 %s. Case slot 0 of 2" % self.SHA1,
                          "ROM SHA-1 %s. Case slot 0 of 2" % ("1" * 40))):
            with self.subTest(old):
                self.assertIn(old, text)
                ok, msg = self.check(tables, text.replace(old, new, 1))
                self.assertFalse(ok)
                self.assertRegex(msg, r"note: the note of case slot 0x080002\d\w is not the one --toml writes")
        # Entries right, a generated comment edited.
        self.assertIn("# Switch at 0x08000104", text)
        ok, msg = self.check(tables, text.replace("# Switch at 0x08000104", "# switch at 0x08000104"))
        self.assertFalse(ok)
        self.assertIn("verbatim: ", msg)
        self.assertNotIn("note: ", msg)

    def test_check_config_malformed_entries(self):
        if sys.version_info < (3, 11):
            self.skipTest("needs tomllib")
        _, tables = self.tables(unsized=False)
        text = self.toml(tables)
        for extra, want in (('addr = 0x08000400\nnote = 5\n', "number 6 (addr 0x08000400)"),
                            ('addr = "0x08000400"\n', "number 6 (addr '0x08000400') has an addr of type str")):
            with self.subTest(extra):
                ok, msg = self.check(tables, text + "\n[[extra_func]]\n" + extra)
                self.assertFalse(ok)
                self.assertIn("malformed: [[extra_func]] " + want, msg)

    def test_check_config_code_copies(self):
        if sys.version_info < (3, 11):
            self.skipTest("needs tomllib")
        _, tables = self.tables(unsized=False)
        text = self.toml(tables)

        def copy(name, source, size, runtime):
            return ('\n[[code_copy]]\nname = "%s"\nsource_start = 0x%X\nsize = 0x%X\n'
                    'runtime_start = 0x%X\n' % (name, source, size, runtime))

        ok, msg = self.check(tables, text + copy(*self.COPY))
        self.assertTrue(ok, msg)
        # The same range under another name is the same copy.
        ok, msg = self.check(tables, text + copy("other", *self.COPY[1:]))
        self.assertTrue(ok, msg)
        ok, msg = self.check(tables, text + copy("img", 0x08000700, 0x180, 0x03000000))
        self.assertFalse(ok)
        self.assertIn("copy: [[code_copy]] img is source 0x08000700, size 0x180, runtime 0x03000000 "
                      "in ", msg)
        self.assertIn("but source 0x08000700, size 0x200, runtime 0x03000000 in the scan", msg)
        ok, msg = self.check(tables, text + copy("new", 0x08000900, 0x10, 0x02000000))
        self.assertFalse(ok)
        self.assertIn("'new' (source 0x08000900, size 0x10, runtime 0x02000000) is not one of "
                      "the scan's copies: pass --copy NAME=0x08000900,0x10,0x02000000", msg)

    def test_check_config_rejected_and_review(self):
        if sys.version_info < (3, 11):
            self.skipTest("needs tomllib")
        _, tables = self.tables()
        ok, msg = self.check(tables, self.toml(tables))
        self.assertFalse(ok)
        self.assertIn("rejected: the addls pc, pc, r3, lsl 2 at 0x08000300: no cmp", msg)
        self.assertIn("FAIL: 5 candidate slots, 5 entries noted as case slots, "
                      "1 rejected and 0 to review in ROM code, 1 problem(s)", msg)

        rom = Rom()
        disp = rom.switch(0x08000100, rm=1, cases=3)
        rom.put(disp + 8 + 12, b(disp + 20, 0x08000300))  # a b after the last slot
        tables = scan(rom)
        ok, msg = self.check(tables, self.toml(tables), copies=[])
        self.assertFalse(ok)
        self.assertIn("review: the switch at 0x%08X: the word after the last slot" % disp, msg)
        self.assertIn("0 rejected and 1 to review in ROM code", msg)


class Command(unittest.TestCase):

    def run_main(self, rom_bytes, *args, config=None):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rom.gba")
            with open(path, "wb") as f:
                f.write(rom_bytes)
            if config is not None:
                cfg = os.path.join(d, "game.toml")
                with open(cfg, "w") as f:
                    f.write(config)
                args = args + ("--check-config", cfg)
            out, err = io.StringIO(), io.StringIO()
            old = sys.stdout, sys.stderr
            sys.stdout, sys.stderr = out, err
            try:
                rc = fst.main([path] + list(args))
            finally:
                sys.stdout, sys.stderr = old
            return rc, out.getvalue(), err.getvalue()

    def test_check_config_exit_codes(self):
        if sys.version_info < (3, 11):
            self.skipTest("needs tomllib")
        rom = Rom()
        rom.switch(0x08000100, rm=1, cases=2)
        rc, toml, _ = self.run_main(rom.bytes(), "--toml")
        self.assertEqual(rc, 0)
        rc, out, _ = self.run_main(rom.bytes(), config=toml)
        self.assertEqual(rc, 0, out)
        # A finding is 1, also for an entry of the wrong type.
        rc, out, err = self.run_main(rom.bytes(), config=toml + "\n[[extra_func]]\naddr = 1\nnote = 5\n")
        self.assertEqual(rc, 1, out + err)
        self.assertIn("malformed", out)
        self.assertNotIn("Traceback", err)
        # A file the check cannot use is 2.
        rc, _, err = self.run_main(rom.bytes(), config="extra_func = [")
        self.assertEqual(rc, 2)
        self.assertIn("cannot read", err)

    def test_unexpected_error_is_exit_2(self):
        rom = Rom()
        old = fst.scan

        def broken(*args):
            raise RuntimeError("boom")

        fst.scan = broken
        try:
            rc, _, err = self.run_main(rom.bytes())
        finally:
            fst.scan = old
        self.assertEqual(rc, 2)
        self.assertIn("RuntimeError: boom", err)

    def test_unpinned_rom_warns_and_takes_copies(self):
        rom = Rom()
        rom.switch(0x08000800, rm=0, cases=2)
        rc, out, err = self.run_main(rom.bytes(), "--copy", "img=0x08000700,0x200,0x03000000")
        self.assertEqual(rc, 0)
        self.assertIn("is not the pinned", err)
        self.assertIn("copy img: 0x08000700-0x080008FF runs at 0x03000000", out)
        self.assertIn("1 in copied code with 2 case slots (img)", out)

    def test_bad_copy_option(self):
        old, sys.stderr = sys.stderr, io.StringIO()
        try:
            with self.assertRaises(SystemExit):
                fst.main(["x.gba", "--copy", "img=1,2"])
            self.assertIn("expected NAME=SOURCE,SIZE,RUNTIME", sys.stderr.getvalue())
        finally:
            sys.stderr = old

    def test_empty_rom(self):
        rc, _, err = self.run_main(b"")
        self.assertEqual(rc, 2)
        self.assertIn("not a GBA ROM", err)


if __name__ == "__main__":
    unittest.main()
