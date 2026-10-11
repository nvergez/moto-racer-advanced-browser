#!/usr/bin/env python3
"""A minimal 16 KiB stand-in BIOS for the repro ROMs, so that they need no BIOS
dump and can run in CI.

    make_bios.py OUT.bin            write the image, print its SHA-1
    make_bios.py --compare DUMP     compare the image with a 16 KiB BIOS dump

It is not a GBA BIOS. It holds only what the repro ROMs use once the runtime
has skipped the boot intro ([bios] skip_intro = true): the exception vectors,
an IRQ dispatcher that calls the user handler at 0x03007FFC, and
VBlankIntrWait (SWI 0x05). Any other SWI returns at once, and reset, which
skip_intro never runs, is a branch to itself. tests/repro/bios.toml is its
gba_recompile config, with this image's SHA-1.

Where it comes from. The behavior is GBATEK's: "BIOS Interrupt handling"
(the user handler's address at 0x03007FFC, called in IRQ mode; the IRQ flags
for IntrWait at 0x03007FF8), "BIOS Halt Functions" (VBlankIntrWait enables IME
and waits in Halt until the handler sets bit 0 of 0x03007FF8), "GBA System
Control" (HALTCNT, 0x04000301) and "ARM CPU Exceptions" (vectors, banked
registers, SPSR). No code is taken from a BIOS image. GBATEK's "BIOS Interrupt
handling" also prints the retail BIOS's own six-instruction IRQ dispatcher;
the first version of this file copied it, and its SWI entry and exit matched
the retail ones too (owner review of PR #11). The instructions below were
rewritten to avoid that: other registers, another order, and the
load-multiple form of exception return. `--compare` checks it against a dump:
no two consecutive words of this image equal two consecutive words of the
dump, at any offset. Single words still occur in the retail image, as any
common ARM instruction does; tests/repro/README.md lists them.

Each instruction is written out as its 32-bit ARM encoding with the assembly
in a comment; the encodings were checked with the Capstone 5.0.9 disassembler
(tests/repro/README.md).
"""
import hashlib
import struct
import sys

SIZE = 0x4000


def b(src, dst, cond=0xE):
    """ARM B from src to dst (cond 0xE = always, 0x0 = EQ, 0x1 = NE)."""
    return (cond << 28) | (0xA << 24) | (((dst - (src + 8)) >> 2) & 0xFFFFFF)


IRQ_HANDLER = 0x20
IRQ_RETURN = 0x38       # where the user handler returns: bios.toml seeds it
SWI_HANDLER = 0x40
SWI_WAIT = 0x74
SWI_RETURN = 0x9C

CODE = {
    # Exception vectors.
    0x00: b(0x00, 0x00),                  # reset: b .   (never run: skip_intro)
    0x04: b(0x04, 0x04),                  # undefined instruction: b .
    0x08: b(0x08, SWI_HANDLER),           # SWI
    0x0C: b(0x0C, 0x0C),                  # prefetch abort: b .
    0x10: b(0x10, 0x10),                  # data abort: b .
    0x14: b(0x14, 0x14),                  # reserved: b .
    0x18: b(0x18, IRQ_HANDLER),           # IRQ
    0x1C: b(0x1C, 0x1C),                  # FIQ: b .

    # IRQ dispatcher (IRQ mode, IRQs masked, lr = interrupted PC + 4). Saves
    # the caller-saved registers, calls the user handler whose address is at
    # 0x03007FFC (read through its mirror 0x03FFFFFC), then restores them and
    # returns from the interrupt in one load-multiple. The repro handlers rely
    # on no register value at entry.
    0x20: 0xE24EE004,  # sub lr, lr, #4         lr = the interrupted instruction
    0x24: 0xE52DE004,  # str lr, [sp, #-4]!
    0x28: 0xE92D100F,  # stmfd sp!, {r0-r3, r12}
    0x2C: 0xE28FE004,  # add lr, pc, #4         lr = 0x38, where the handler returns
    0x30: 0xE3A0C301,  # mov r12, #0x04000000
    0x34: 0xE51CF004,  # ldr pc, [r12, #-4]     user handler
    0x38: 0xE8FD900F,  # ldmfd sp!, {r0-r3, r12, pc}^   return, CPSR = SPSR_irq

    # SWI handler (Supervisor mode, IRQs masked, lr = the instruction after
    # the swi).
    0x40: 0xE92D4003,  # stmfd sp!, {r0, r1, lr}
    0x44: 0xE55E0002,  # ldrb r0, [lr, #-2]     SWI number (ARM swi 0xNN0000, Thumb swi 0xNN)
    0x48: 0xE3500005,  # cmp r0, #5             VBlankIntrWait?
    0x4C: b(0x4C, SWI_RETURN, cond=0x1),  # bne swi_return   any other SWI: return
    # VBlankIntrWait, in System mode with IRQs enabled (GBATEK: the BIOS
    # halt functions enable IME and wait in Halt). SPSR_svc is saved because
    # an IRQ handler could itself call a SWI.
    0x50: 0xE14F1000,  # mrs r1, spsr
    0x54: 0xE52D1004,  # str r1, [sp, #-4]!
    0x58: 0xE321F01F,  # msr cpsr_c, #0x1F      System mode, IRQs enabled
    0x5C: 0xE3A01301,  # mov r1, #0x04000000
    0x60: 0xE3A00001,  # mov r0, #1
    0x64: 0xE5C10208,  # strb r0, [r1, #0x208]  IME = 1
    0x68: 0xE15100B8,  # ldrh r0, [r1, #-8]     IntrCheck (0x03007FF8, through its mirror)
    0x6C: 0xE3C00001,  # bic r0, r0, #1
    0x70: 0xE14100B8,  # strh r0, [r1, #-8]     discard an earlier VBlank
    0x74: 0xE3A00000,  # wait: mov r0, #0
    0x78: 0xE5C10301,  # strb r0, [r1, #0x301]  HALTCNT = 0: Halt until an interrupt
    0x7C: 0xE15100B8,  # ldrh r0, [r1, #-8]
    0x80: 0xE3100001,  # tst r0, #1             has the handler flagged a VBlank?
    0x84: b(0x84, SWI_WAIT, cond=0x0),    # beq wait
    0x88: 0xE3C00001,  # bic r0, r0, #1
    0x8C: 0xE14100B8,  # strh r0, [r1, #-8]     acknowledge it
    0x90: 0xE321F0D3,  # msr cpsr_c, #0xD3      back to Supervisor mode, IRQs masked
    0x94: 0xE49D1004,  # ldr r1, [sp], #4
    0x98: 0xE169F001,  # msr spsr_fc, r1
    0x9C: 0xE8FD8003,  # swi_return: ldmfd sp!, {r0, r1, pc}^   return, CPSR = SPSR_svc
}


def build():
    image = bytearray(SIZE)
    for addr, word in CODE.items():
        struct.pack_into('<I', image, addr, word)
    return bytes(image)


def compare(dump_path):
    """Print every word of the image that occurs in the dump, and every run of
    two or more consecutive words that equals consecutive words of the dump.
    Prints only the image's own offsets and words. Returns 1 if there is a
    run, else 0."""
    with open(dump_path, 'rb') as f:
        dump = f.read()
    if len(dump) != SIZE:
        sys.stderr.write('%s is %d bytes, not %d\n' % (dump_path, len(dump), SIZE))
        return 2
    count = SIZE // 4
    ours = struct.unpack('<%dI' % count, build())
    theirs = struct.unpack('<%dI' % count, dump)
    where = {}
    for i, word in enumerate(theirs):
        where.setdefault(word, []).append(i)
    used = [i for i, word in enumerate(ours) if word]
    print('%d nonzero words in the stand-in' % len(used))
    single = [i for i in used if ours[i] in where]
    for i in single:
        print('  word at 0x%02X (%08X) also occurs in the dump (%d time(s))'
              % (i * 4, ours[i], len(where[ours[i]])))
    runs = []
    for i in used:
        for j in where.get(ours[i], []):
            if i and j and ours[i - 1] and ours[i - 1] == theirs[j - 1]:
                continue  # not the start of a run
            n = 0
            while i + n < count and j + n < count and ours[i + n] and \
                    ours[i + n] == theirs[j + n]:
                n += 1
            if n >= 2:
                runs.append((i * 4, j * 4, n))
    for ours_at, theirs_at, n in runs:
        print('  RUN: %d words at 0x%02X equal the dump at 0x%X' % (n, ours_at, theirs_at))
    print('%d single word(s) in common, %d run(s) of two or more words'
          % (len(single), len(runs)))
    return 1 if runs else 0


def main(argv):
    if len(argv) == 3 and argv[1] == '--compare':
        return compare(argv[2])
    if len(argv) != 2 or argv[1].startswith('-'):
        sys.stderr.write('usage: make_bios.py OUT.bin | make_bios.py --compare DUMP\n')
        return 2
    image = build()
    with open(argv[1], 'wb') as out:
        out.write(image)
    print(hashlib.sha1(image).hexdigest())
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
