#!/usr/bin/env python3
"""Synthetic 4 KiB GBA ROMs that reproduce gbarecomp's IRQ call-return leak.

    make_rom.py CASE OUT.gba      CASE is irqleak1 or irqleak2

Prints the SHA-1 of the ROM it wrote. Each case has a gba_recompile config
next to this script (CASE.toml) whose [identity].sha1 pins these bytes.

No Nintendo code or data is inside: the header logo (0x04-0x9F) is left zero,
so the runtime must skip the BIOS intro ([bios] skip_intro = true in the
configs), which never checks the logo. Every instruction is written out below
as its 32-bit ARM encoding with the assembly in a comment; the encodings were
checked with the Capstone 5.0.9 disassembler (tests/repro/README.md).

The bug (patches/gbarecomp/0003-irq-call-return-leak.patch): a generated
function inside an IRQ handler calls a function that has no static entry. The
interpreter bridges the callee in IRQ-continuation mode, performs its return,
and stops at the caller's return address because that address has a static
entry. The caller then continues natively, but the call-return frame its BL
pushed is never popped. One frame leaks per IRQ.

irqleak1: the VBlank handler at 0x08000180 does `bl 0x08000140`, which
  tail-calls F (0x08000200) through a pointer in EWRAM, so F has no static
  entry. The return address 0x08000188 has one because the config sets
  static_resume_all = true. The main loop is `b .`. On the gbarecomp pin the
  call-return stack grows by one per VBlank until `generated call-return stack
  overflow at return_pc=0x08000188` (1,024 entries), and the run aborts.

irqleak2: static_resume_all = false. The handler's BL returns to 0x08000194,
  which has a static entry only because a branch at 0x08000188 targets it. The
  main loop calls W = { swi VBlankIntrWait; bx lr }. After each SWI, gbarecomp
  unwinds the host stack and W's `bx lr` dispatches 0x080000FC, which has no
  static entry. The bridge for that miss takes the top of the call-return
  stack as the address to stop at: a leaked 0x08000194, which only IRQ code
  ever reaches. On the pin the bridge interprets the main loop for the rest of
  the run while frames keep leaking, until the same overflow.
"""
import hashlib
import struct
import sys

ROM_BASE = 0x08000000
ROM_SIZE = 0x1000


def b(src, dst, cond=0xE, link=False):
    """ARM B/BL from src to dst (cond 0xE = always, 0x1 = NE)."""
    offset = ((dst - (src + 8)) >> 2) & 0xFFFFFF
    return (cond << 28) | ((0xB if link else 0xA) << 24) | offset


def header(rom, title, game_code):
    """Cartridge header with a zero logo. 0xBD is the complement check that
    the BIOS verifies (GBATEK, "GBA Cartridge Header")."""
    struct.pack_into('<I', rom, 0, b(ROM_BASE, 0x080000C0))  # b 0x080000C0
    rom[0xA0:0xAC] = title.ljust(12, b'\0')
    rom[0xAC:0xB0] = game_code
    rom[0xB0:0xB2] = b'00'          # maker code
    rom[0xB2] = 0x96                # fixed value
    rom[0xBD] = (-(sum(rom[0xA0:0xBD]) + 0x19)) & 0xFF


# Shared start-up code at the header's branch target, 0x080000C0, and its
# literal pool. It installs the IRQ handler, stores F's address where the tail
# call reads it, enables the VBlank IRQ and switches to System mode with IRQs
# enabled. Each case appends its main loop at 0x080000F8.
STARTUP = {
    0x080000C0: 0xE59F0038,  # ldr r0, [pc, #0x38]   -> 0x03007FFC (literal at 0x08000100)
    0x080000C4: 0xE59F1038,  # ldr r1, [pc, #0x38]   -> 0x08000180 (handler)
    0x080000C8: 0xE5801000,  # str r1, [r0]          user IRQ handler pointer
    0x080000CC: 0xE59F0034,  # ldr r0, [pc, #0x34]   -> 0x02000000
    0x080000D0: 0xE59F1034,  # ldr r1, [pc, #0x34]   -> 0x08000200 (F)
    0x080000D4: 0xE5801000,  # str r1, [r0]          function pointer in EWRAM
    0x080000D8: 0xE3A00301,  # mov r0, #0x04000000
    0x080000DC: 0xE3A01008,  # mov r1, #8
    0x080000E0: 0xE1C010B4,  # strh r1, [r0, #4]     DISPSTAT: VBlank IRQ enable
    0x080000E4: 0xE2802C02,  # add r2, r0, #0x200
    0x080000E8: 0xE3A01001,  # mov r1, #1
    0x080000EC: 0xE1C210B0,  # strh r1, [r2]         IE = VBlank
    0x080000F0: 0xE1C210B8,  # strh r1, [r2, #8]     IME = 1
    0x080000F4: 0xE321F01F,  # msr cpsr_c, #0x1F     System mode, IRQs enabled
    0x08000100: 0x03007FFC,
    0x08000104: 0x08000180,
    0x08000108: 0x02000000,
    0x0800010C: 0x08000200,
    # 0x08000140: tail call through the pointer in EWRAM.
    0x08000140: 0xE59FC004,  # ldr ip, [pc, #4]      -> 0x02000000
    0x08000144: 0xE59CC000,  # ldr ip, [ip]
    0x08000148: 0xE12FFF1C,  # bx ip
    0x0800014C: 0x02000000,
    # F: reached only through the pointer, so it has no static entry.
    0x08000200: 0xE12FFF1E,  # bx lr
}

IRQLEAK1 = {
    0x080000F8: 0xEAFFFFFE,  # b .                   main loop
    # VBlank handler, called by the BIOS IRQ vector through 0x03007FFC.
    0x08000180: 0xE52DE004,  # push {lr}
    0x08000184: 0xEBFFFFED,  # bl 0x08000140
    0x08000188: 0xE3A00301,  # mov r0, #0x04000000   <- the BL's return address
    0x0800018C: 0xE2800C02,  # add r0, r0, #0x200
    0x08000190: 0xE3A01001,  # mov r1, #1
    0x08000194: 0xE1C010B2,  # strh r1, [r0, #2]     IF: acknowledge VBlank
    0x08000198: 0xE49DE004,  # pop {lr}
    0x0800019C: 0xE12FFF1E,  # bx lr
}

IRQLEAK2 = {
    0x080000F8: b(0x080000F8, 0x08000240, link=True),  # loop: bl W
    0x080000FC: b(0x080000FC, 0x080000F8),             # b loop   <- W returns here
    # VBlank handler: a loop that runs once, so that the BL's return address
    # is also a branch target.
    0x08000180: 0xE52DE004,  # push {lr}
    0x08000184: 0xE3A04001,  # mov r4, #1
    0x08000188: b(0x08000188, 0x08000194),             # b check
    0x0800018C: 0xE2444001,  # again: sub r4, r4, #1
    0x08000190: b(0x08000190, 0x08000140, link=True),  # bl 0x08000140
    0x08000194: 0xE3540000,  # check: cmp r4, #0     <- the BL's return address
    0x08000198: b(0x08000198, 0x0800018C, cond=0x1),   # bne again
    0x0800019C: 0xE3A00301,  # mov r0, #0x04000000
    0x080001A0: 0xE2800C02,  # add r0, r0, #0x200
    0x080001A4: 0xE3A01001,  # mov r1, #1
    0x080001A8: 0xE1C010B2,  # strh r1, [r0, #2]     IF: acknowledge VBlank
    0x080001AC: 0xE59F0010,  # ldr r0, [pc, #0x10]   -> 0x03007FF8
    0x080001B0: 0xE1D010B0,  # ldrh r1, [r0]
    0x080001B4: 0xE3811001,  # orr r1, r1, #1
    0x080001B8: 0xE1C010B0,  # strh r1, [r0]         BIOS IntrCheck |= VBlank
    0x080001BC: 0xE49DE004,  # pop {lr}
    0x080001C0: 0xE12FFF1E,  # bx lr
    0x080001C4: 0x03007FF8,
    # W: wait for the next VBlank.
    0x08000240: 0xEF050000,  # swi 0x050000          VBlankIntrWait
    0x08000244: 0xE12FFF1E,  # bx lr
}

CASES = {
    'irqleak1': (b'IRQLEAKTEST', b'ZZZZ', IRQLEAK1),
    'irqleak2': (b'IRQLEAKTST2', b'ZZZY', IRQLEAK2),
}


def build(case):
    title, game_code, code = CASES[case]
    rom = bytearray(ROM_SIZE)
    header(rom, title, game_code)
    for addr, word in {**STARTUP, **code}.items():
        struct.pack_into('<I', rom, addr - ROM_BASE, word)
    return bytes(rom)


def main(argv):
    if len(argv) != 3 or argv[1] not in CASES:
        sys.stderr.write('usage: make_rom.py {%s} OUT.gba\n' % ','.join(sorted(CASES)))
        return 2
    rom = build(argv[1])
    with open(argv[2], 'wb') as out:
        out.write(rom)
    print(hashlib.sha1(rom).hexdigest())
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
