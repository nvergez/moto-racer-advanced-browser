# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Python port of the cheat decryption routines in mGBA
# (Copyright (c) 2013-2016 Jeffrey Pfau, MPL-2.0), commit
# 143adf5aa2a60c6036810b0cd72445e13d74b0e6:
#   src/gba/cheats/codebreaker.c  _cbDecrypt, _cbRand, _cbSwapIndex, _cbReseed
#   src/gba/cheats/gameshark.c    GBACheatDecryptGameShark (TEA), GSA v1/v2 seeds (L13)
#   src/gba/cheats/parv3.c        Pro Action Replay v3 seeds (L12)
# Only the decryption is ported. Interpreting the decrypted lines is left to
# the reader (see GBATEK's cheat code chapters). The CodeBreaker game-ID
# checksum (cb_checksum) is not in mGBA; it is written from the formula on
# GBATEK's "GBA Cheat Codes - Codebreaker/Xploder" page.
"""Decrypt GBA CodeBreaker and GameShark Advance / Action Replay cheat codes.

Reproduces the decoded cheat codes in docs/research/game-facts.md section 6.
Standard library only, Python 3.9+. Contains no ROM data: the inputs are the
published cheat codes themselves. Only `cbcrc` reads a ROM, from a file you
supply; it writes nothing.

Usage:
  python3 tools/cheats/decrypt_gba_cheats.py check
      Decrypt the Moto Racer Advance (USA) codes quoted in game-facts.md and
      compare the output with copies of the decoded values, kept in this
      script (CB_EXPECTED, TEA_EXPECTED). Then check that each of those codes
      and decoded values still appears in game-facts.md, so an edit to either
      side is caught. Also self-tests cb_checksum. Exit status 1 on any
      mismatch.
  python3 tools/cheats/decrypt_gba_cheats.py cbcrc ROM [--expect HEX]
      CodeBreaker game-ID checksum of the first 64 KiB of ROM (GBATEK's
      formula). Compares it with HEX, by default 6A2F, the value in the
      decrypted USA master code. Exit status 1 if it differs.
  python3 tools/cheats/decrypt_gba_cheats.py cb MASTER [LINE ...]
      CodeBreaker: MASTER is the type-9 line that seeds the encryption
      (12 hex digits, spaces allowed, e.g. "91121668 5608"). Every LINE is
      decrypted with that seed.
  python3 tools/cheats/decrypt_gba_cheats.py tea {gsa,par3} LINE [LINE ...]
      TEA decryption of 8+8 hex digit lines with the GameShark Advance v1/v2
      seeds (gsa) or the Pro Action Replay v3 seeds (par3). No reseeding
      (master code) support.
"""

import argparse
import binascii
import os
import sys

M32 = 0xFFFFFFFF

DOC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        os.pardir, os.pardir, "docs", "research", "game-facts.md")

# gameshark.c L13 @ 143adf5
GSA_SEEDS = (0x09F4FBBD, 0x9681884A, 0x352027E9, 0xF3DEE5A7)
# parv3.c L12 @ 143adf5
PAR3_SEEDS = (0x7AA9648F, 0x7FAE6994, 0xC0EFAAD5, 0x42712C57)


def tea_encrypt(op1, op2, seeds):
    """GBACheatEncryptGameShark. Only used for the self-test round trip."""
    total = 0
    for _ in range(32):
        total = (total + 0x9E3779B9) & M32
        op1 = (op1 + ((((op2 << 4) + seeds[0]) ^ (op2 + total) ^ ((op2 >> 5) + seeds[1])))) & M32
        op2 = (op2 + ((((op1 << 4) + seeds[2]) ^ (op1 + total) ^ ((op1 >> 5) + seeds[3])))) & M32
    return op1, op2


def tea_decrypt(op1, op2, seeds):
    """GBACheatDecryptGameShark."""
    total = 0xC6EF3720
    for _ in range(32):
        op2 = (op2 - ((((op1 << 4) + seeds[2]) ^ (op1 + total) ^ ((op1 >> 5) + seeds[3])))) & M32
        op1 = (op1 - ((((op2 << 4) + seeds[0]) ^ (op2 + total) ^ ((op2 >> 5) + seeds[1])))) & M32
        total = (total - 0x9E3779B9) & M32
    return op1, op2


def _ror(value, amount):
    value &= M32
    return ((value >> amount) | (value << (32 - amount))) & M32


def _load(op1, op2):
    return [(op1 >> 24) & 0xFF, (op1 >> 16) & 0xFF, (op1 >> 8) & 0xFF, op1 & 0xFF,
            (op2 >> 8) & 0xFF, op2 & 0xFF]


def _store(buf):
    return (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3], (buf[4] << 8) | buf[5]


class CodeBreaker:
    """State of mGBA's CodeBreaker decryptor (cbRngState, cbTable, cbSeeds, cbMaster)."""

    TABLE_SIZE = 0x30  # sizeof(cbTable)

    def __init__(self):
        self.rng = 0
        self.master = 0
        self.table = list(range(self.TABLE_SIZE))
        self.seeds = [0, 0, 0, 0]

    def _rand(self):
        roll = (self.rng * 0x41C64E6D + 0x3039) & M32
        roll2 = (roll * 0x41C64E6D + 0x3039) & M32
        roll3 = (roll2 * 0x41C64E6D + 0x3039) & M32
        mix = (roll << 14) & 0xC0000000
        mix |= (roll2 >> 1) & 0x3FFF8000
        mix |= (roll3 >> 16) & 0x7FFF
        self.rng = roll3
        return mix

    def _swap_index(self):
        roll = self._rand()
        count = self.TABLE_SIZE
        if roll == count:
            roll = 0
        if roll < count:
            return roll
        bit = 1
        while count < 0x10000000 and count < roll:
            count = (count << 4) & M32
            bit = (bit << 4) & M32
        while count < 0x80000000 and count < roll:
            count = (count << 1) & M32
            bit = (bit << 1) & M32
        while True:
            mask = 0
            if roll >= count:
                roll -= count
            if roll >= count >> 1:
                roll -= count >> 1
                mask |= _ror(bit, 1)
            if roll >= count >> 2:
                roll -= count >> 2
                mask |= _ror(bit, 2)
            if roll >= count >> 3:
                roll -= count >> 3
                mask |= _ror(bit, 3)
            if not roll or not (bit >> 4):
                break
            bit >>= 4
            count >>= 4
        mask &= 0xE0000000
        if not mask or not (bit & 7):
            return roll
        if mask & _ror(bit, 3):
            roll += count >> 3
        if mask & _ror(bit, 2):
            roll += count >> 2
        if mask & _ror(bit, 1):
            roll += count >> 1
        return roll

    def reseed(self, op1, op2):
        """_cbReseed: called for a type-9 (CB_ENCRYPT) line."""
        self.rng = (op2 & 0xFF) ^ 0x1111
        self.table = list(range(self.TABLE_SIZE))
        for _ in range(0x50):
            x = self._swap_index()
            y = self._swap_index()
            self.table[x], self.table[y] = self.table[y], self.table[x]
        self.rng = 0x4EFAD1C3
        for _ in range((op1 >> 24) & 0xF):
            self.rng = self._rand()
        self.seeds[2] = self._rand()
        self.seeds[3] = self._rand()
        self.rng = (op2 >> 8) ^ 0xF254
        for _ in range(op2 >> 8):
            self.rng = self._rand()
        self.seeds[0] = self._rand()
        self.seeds[1] = self._rand()
        self.master = op1

    def decrypt(self, op1, op2):
        """_cbDecrypt: op1 is 32-bit, op2 is 16-bit."""
        buf = _load(op1, op2)
        for i in range(self.TABLE_SIZE - 1, -1, -1):
            off_x, off_y = i >> 3, self.table[i] >> 3
            bit_x, bit_y = i & 7, self.table[i] & 7
            x = (buf[off_x] >> bit_x) & 1
            y = (buf[off_y] >> bit_y) & 1
            x2 = buf[off_x] & ~(1 << bit_x) & 0xFF
            if y:
                x2 |= 1 << bit_x
            buf[off_x] = x2
            y2 = buf[off_y] & ~(1 << bit_y) & 0xFF
            if x:
                y2 |= 1 << bit_y
            buf[off_y] = y2
        op1, op2 = _store(buf)
        op1 ^= self.seeds[0]
        op2 = (op2 ^ self.seeds[1]) & 0xFFFF
        buf = _load(op1, op2)
        master = self.master
        for i in range(5):
            buf[i] = (buf[i] ^ (master >> 8) ^ buf[i + 1]) & 0xFF
        buf[5] = (buf[5] ^ (master >> 8)) & 0xFF
        for i in range(5, 0, -1):
            buf[i] = (buf[i] ^ master ^ buf[i - 1]) & 0xFF
        buf[0] = (buf[0] ^ master) & 0xFF
        op1, op2 = _store(buf)
        return (op1 ^ self.seeds[2]) & M32, (op2 ^ self.seeds[3]) & 0xFFFF


def parse_cb(text):
    digits = "".join(text.split())
    if len(digits) != 12:
        raise ValueError("CodeBreaker line must be 12 hex digits: %r" % text)
    return int(digits[:8], 16), int(digits[8:], 16)


def parse_tea(text):
    digits = "".join(text.split())
    if len(digits) != 16:
        raise ValueError("GameShark/Action Replay line must be 16 hex digits: %r" % text)
    return int(digits[:8], 16), int(digits[8:], 16)


def fmt_cb(op1, op2):
    return "%08X %04X" % (op1, op2)


def fmt_tea(op1, op2):
    return "%08X %08X" % (op1, op2)


def decrypt_cb(master, lines):
    op1, op2 = parse_cb(master)
    if op1 >> 28 != 0x9:
        raise ValueError("master line must be type 9 (CB_ENCRYPT): %r" % master)
    cb = CodeBreaker()
    cb.reseed(op1, op2)
    return [fmt_cb(*cb.decrypt(*parse_cb(line))) for line in lines]


CB_CHECKSUM_SIZE = 0x10000  # "first 64Kbytes of cartridge"


def _cb_crc(data):
    """The checksum loop from GBATEK, using unsigned 16-bit values."""
    crc = 0xFFFF
    for byte in data:
        x = (byte ^ (crc >> 8)) & 0xFFFF
        x ^= x >> 4
        crc = ((crc << 8) ^ (x * 0x1001) ^ (x * 0x20)) & 0xFFFF
    return crc


def cb_checksum(rom):
    """CodeBreaker game-ID checksum ('xxxx' in '0000xxxx 000y') of a ROM image.

    GBATEK: computed over the first 64 KiB; no$gba pads with FFh if the ROM is
    smaller.
    """
    head = bytes(rom[:CB_CHECKSUM_SIZE])
    return _cb_crc(head + b"\xFF" * (CB_CHECKSUM_SIZE - len(head)))


# Codes as listed by GameHacking.org game 5425 (Motoracer Advance (USA),
# CRC32 2FDBE7A8), Wayback snapshot 20260617202426, with the decoded values
# recorded in docs/research/game-facts.md section 6.
CB_MASTER = "91121668 5608"
CB_EXPECTED = [
    ("[M] Must Be On (line 2)", "CF8CF175 4BB4", "00006A2F 000A"),
    ("[M] Must Be On (line 3)", "6EEBE336 DF10", "1015BC76 0007"),
    ("Always 1st", "B3142C24 4498", "42032CBA 0000"),
    ("Always 1st", "0584FAF9 49B2", "00000007 0048"),
    ("Drive Thru Objects", "8C6F7C2E 545F", "32032C8D 0000"),
    ("End Race [Press Select+L]", "20805E08 26E7", "74000130 01FB"),
    ("End Race [Press Select+L]", "16F8EA3D CF12", "3201A55B 0007"),
    ("Infinite Nitro", "CD1C515A 318E", "320340F4 00F0"),
    ("Unlock Everything", "32A38E88 B2FE", "4203F024 FFFF"),
    ("Unlock Everything", "A1E4B8FD 4BD7", "00000009 0002"),
]
TEA_EXPECTED = [
    # (name, seeds, input, expected)
    ("Always in First Place (AR)", "par3", "1378A3AB 53645017", "0201A58E 00000001"),
    ("Bike Speed Boost (AR)", "par3", "2F98C0ED A2CFC904", "04000130 000003FE"),
    ("Bike Speed Boost (AR)", "par3", "CC9DC202 9922F449", "020340E5 000000C8"),
    ("Always in First Place (AR)", "gsa", "1378A3AB 53645017", "73D5936C 7EA50D88"),
]
SEEDS = {"gsa": GSA_SEEDS, "par3": PAR3_SEEDS}
# The checksum in the decrypted USA master code line "00006A2F 000A".
USA_CB_CHECKSUM = 0x6A2F


def _compact(text):
    return "".join(text.split()).upper()


def check_doc_mentions(path=DOC_PATH):
    """Count the expected codes and decodes that no longer appear in the doc.

    Whitespace is ignored, since the doc writes MadCatz's codes as one
    12-digit group and the decoded lines with a space.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            doc = _compact(handle.read())
    except OSError as err:
        print("FAIL cannot read %s: %s" % (path, err))
        return 1
    values = [CB_MASTER]
    values += [v for _, line, expected in CB_EXPECTED for v in (line, expected)]
    values += [v for _, _, line, expected in TEA_EXPECTED for v in (line, expected)]
    missing = [v for v in values if _compact(v) not in doc]
    print("%s: %d of %d codes and decoded values found"
          % (os.path.basename(path), len(values) - len(missing), len(values)))
    for value in missing:
        print("  FAIL not in %s: %s" % (os.path.normpath(path), value))
    return len(missing)


def check():
    failures = 0
    for seeds in SEEDS.values():
        for pair in ((0x0201A58E, 0x00000001), (0x12345678, 0x9ABCDEF0)):
            if tea_decrypt(*tea_encrypt(pair[0], pair[1], seeds), seeds) != pair:
                print("FAIL TEA round trip", pair)
                failures += 1
    # GBATEK's loop is CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF), which
    # binascii.crc_hqx computes independently; 0x29B1 is its check value.
    sample = bytes((i * 37 + 11) & 0xFF for i in range(4096))
    if _cb_crc(b"123456789") != 0x29B1 or _cb_crc(sample) != binascii.crc_hqx(sample, 0xFFFF):
        print("FAIL CodeBreaker checksum self-test")
        failures += 1
    decoded = decrypt_cb(CB_MASTER, [line for _, line, _ in CB_EXPECTED])
    print("CodeBreaker, master %s" % CB_MASTER)
    for (name, line, expected), got in zip(CB_EXPECTED, decoded):
        status = "ok" if got == expected else "FAIL (expected %s)" % expected
        failures += got != expected
        print("  %-28s %s -> %s  %s" % (name, line, got, status))
    print("TEA (GameShark Advance v1/v2 'gsa' or Pro Action Replay v3 'par3' seeds)")
    for name, seeds, line, expected in TEA_EXPECTED:
        got = fmt_tea(*tea_decrypt(*parse_tea(line), SEEDS[seeds]))
        status = "ok" if got == expected else "FAIL (expected %s)" % expected
        failures += got != expected
        print("  %-28s %-4s %s -> %s  %s" % (name, seeds, line, got, status))
    failures += check_doc_mentions()
    print("%d mismatch(es)" % failures)
    return 1 if failures else 0


def cbcrc(path, expect):
    with open(path, "rb") as handle:
        head = handle.read(CB_CHECKSUM_SIZE)
    got = cb_checksum(head)
    padded = "" if len(head) == CB_CHECKSUM_SIZE else " (file shorter than 64 KiB, padded with FFh)"
    print("CodeBreaker checksum of the first 64 KiB: %04X%s" % (got, padded))
    print("expected %04X: %s" % (expect, "match" if got == expect else "MISMATCH"))
    return 0 if got == expect else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("check", help="reproduce the decodes in game-facts.md")
    p_crc = sub.add_parser("cbcrc", help="CodeBreaker game-ID checksum of a ROM file")
    p_crc.add_argument("rom")
    p_crc.add_argument("--expect", type=lambda s: int(s, 16), default=USA_CB_CHECKSUM,
                       help="expected checksum in hex (default %04X)" % USA_CB_CHECKSUM)
    p_cb = sub.add_parser("cb", help="decrypt CodeBreaker lines")
    p_cb.add_argument("master")
    p_cb.add_argument("lines", nargs="*")
    p_tea = sub.add_parser("tea", help="decrypt GameShark Advance / Action Replay lines")
    p_tea.add_argument("seeds", choices=sorted(SEEDS))
    p_tea.add_argument("lines", nargs="+")
    args = parser.parse_args(argv)

    if args.command in (None, "check"):
        return check()
    if args.command == "cbcrc":
        try:
            return cbcrc(args.rom, args.expect)
        except OSError as err:
            parser.error("cannot read %s: %s" % (args.rom, err.strerror))
    if args.command == "cb":
        for line, got in zip(args.lines, decrypt_cb(args.master, args.lines)):
            print("%s -> %s" % (line, got))
        return 0
    for line in args.lines:
        print("%s -> %s" % (line, fmt_tea(*tea_decrypt(*parse_tea(line), SEEDS[args.seeds]))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
