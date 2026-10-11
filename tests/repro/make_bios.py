#!/usr/bin/env python3
"""A minimal 16 KiB stand-in BIOS for the repro ROMs, so that they need no BIOS
dump and can run in CI.

    make_bios.py OUT.bin      prints the SHA-1 of the image it wrote

It is not a GBA BIOS. It holds only what the repro ROMs use once the runtime
has skipped the boot intro ([bios] skip_intro = true): the exception vectors,
the IRQ dispatcher that calls the user handler at 0x03007FFC, and
VBlankIntrWait (SWI 0x05). Any other SWI returns at once, and reset, which
skip_intro never runs, is a branch to itself. tests/repro/bios.toml is its
gba_recompile config, with this image's SHA-1.

Written from GBATEK's descriptions ("BIOS Interrupt handling", which lists
the six instructions of the IRQ dispatcher, and "BIOS Halt Functions") for
this test only; nothing here comes from a BIOS image. Each instruction is
written out as its 32-bit ARM encoding with the assembly in a comment; the
encodings were checked with the Capstone 5.0.9 disassembler
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
IRQ_RETURN = 0x30       # where the user handler returns: bios.toml seeds it
SWI_HANDLER = 0x40
SWI_WAIT = 0x78
SWI_RETURN = 0xA4

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

    # IRQ dispatcher (IRQ mode): call the user handler whose address is at
    # 0x03007FFC (read through its mirror 0x03FFFFFC), then return.
    0x20: 0xE92D500F,  # stmfd sp!, {r0-r3, r12, lr}
    0x24: 0xE3A00301,  # mov r0, #0x04000000
    0x28: 0xE28FE000,  # add lr, pc, #0         lr = 0x30
    0x2C: 0xE510F004,  # ldr pc, [r0, #-4]      user handler
    0x30: 0xE8BD500F,  # ldmfd sp!, {r0-r3, r12, lr}
    0x34: 0xE25EF004,  # subs pc, lr, #4        return from the interrupt

    # SWI handler (Supervisor mode, IRQs masked).
    0x40: 0xE92D5800,  # stmfd sp!, {r11, r12, lr}
    0x44: 0xE55EC002,  # ldrb r12, [lr, #-2]    SWI number (ARM swi 0xNN0000, Thumb swi 0xNN)
    0x48: 0xE35C0005,  # cmp r12, #5            VBlankIntrWait?
    0x4C: b(0x4C, SWI_RETURN, cond=0x1),  # bne swi_return   any other SWI: return
    # VBlankIntrWait, in System mode with IRQs enabled (GBATEK: the BIOS
    # halt functions enable IME and wait in Halt).
    0x50: 0xE14FB000,  # mrs r11, spsr
    0x54: 0xE92D0800,  # stmfd sp!, {r11}
    0x58: 0xE321F01F,  # msr cpsr_c, #0x1F      System mode, IRQs enabled
    0x5C: 0xE92D400C,  # stmfd sp!, {r2, r3, lr}
    0x60: 0xE3A03301,  # mov r3, #0x04000000
    0x64: 0xE3A02001,  # mov r2, #1
    0x68: 0xE5C32208,  # strb r2, [r3, #0x208]  IME = 1
    0x6C: 0xE15320B8,  # ldrh r2, [r3, #-8]     IntrCheck (0x03007FF8, through its mirror)
    0x70: 0xE3C22001,  # bic r2, r2, #1
    0x74: 0xE14320B8,  # strh r2, [r3, #-8]     discard an earlier VBlank
    0x78: 0xE3A02000,  # wait: mov r2, #0
    0x7C: 0xE5C32301,  # strb r2, [r3, #0x301]  HALTCNT = 0: Halt until an interrupt
    0x80: 0xE15320B8,  # ldrh r2, [r3, #-8]
    0x84: 0xE3120001,  # tst r2, #1             has the handler flagged a VBlank?
    0x88: b(0x88, SWI_WAIT, cond=0x0),    # beq wait
    0x8C: 0xE3C22001,  # bic r2, r2, #1
    0x90: 0xE14320B8,  # strh r2, [r3, #-8]     acknowledge it
    0x94: 0xE8BD400C,  # ldmfd sp!, {r2, r3, lr}
    0x98: 0xE321F0D3,  # msr cpsr_c, #0xD3      back to Supervisor mode, IRQs masked
    0x9C: 0xE8BD0800,  # ldmfd sp!, {r11}
    0xA0: 0xE169F00B,  # msr spsr_fc, r11
    0xA4: 0xE8BD5800,  # swi_return: ldmfd sp!, {r11, r12, lr}
    0xA8: 0xE1B0F00E,  # movs pc, lr            return to the caller, restoring CPSR
}


def build():
    image = bytearray(SIZE)
    for addr, word in CODE.items():
        struct.pack_into('<I', image, addr, word)
    return bytes(image)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write('usage: make_bios.py OUT.bin\n')
        return 2
    image = build()
    with open(argv[1], 'wb') as out:
        out.write(image)
    print(hashlib.sha1(image).hexdigest())
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
