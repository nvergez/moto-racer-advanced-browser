#!/usr/bin/env python3
"""Synthetic 4 KiB GBA ROMs that reproduce gbarecomp runtime bugs.

    make_rom.py CASE OUT.gba      CASE is irqleak1, irqleak2, irqleak3,
                                  overlay1 or overlay1heal

Prints the SHA-1 of the ROM it wrote. Each case has a gba_recompile config
next to this script (CASE.toml) whose [identity].sha1 pins these bytes.
irqleak1-3 reproduce the IRQ call-return leak (patch 0003, below); overlay1
reproduces the shared-IWRAM code images that patch 0006's RAM overlay
selector handles (see OVERLAY1). overlay1heal is the same ROM, byte for byte,
run with another config and selector (tests/repro/README.md).

No Nintendo code or data is inside: the header logo (0x04-0x9F) is left zero,
so the runtime must skip the BIOS intro ([bios] skip_intro = true in the
configs), which never checks the logo. Every instruction is written out below
as its 32-bit ARM encoding with the assembly in a comment. The encodings of
irqleak1-3 were checked with the Capstone 5.0.9 disassembler, those of
overlay1 with LLVM's (tests/repro/README.md, "How the encodings were
checked").

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

irqleak3: irqleak1's code under another header title and game code. Its
  executable also installs a gbarecomp function-entry hook at F
  (tests/repro/irqleak3_hooks.cpp) that performs F's `bx lr`. The bridge for
  F then returns from its hook check, before it interprets anything, without
  popping the frame; that exit does not go through the heal-to-static check
  that the first part of patch 0003 fixes. Only the second part, which drops
  frames left above the IRQ's entry depth when runtime_irq() returns, stops
  this leak. On the pin it overflows at return_pc=0x08000188, as irqleak1.
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


# Start-up code of irqleak1-3 at the header's branch target, 0x080000C0, and
# its literal pool. It installs the IRQ handler, stores F's address where the
# tail call reads it, enables the VBlank IRQ and switches to System mode with
# IRQs enabled. Each irqleak case appends its main loop at 0x080000F8.
# overlay1 has start-up code of its own (OVERLAY1).
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

# overlay1: two different ARM routines, images A and B, that the program copies
# in turn to the same IWRAM address, 0x03000000, and calls there, the way Moto
# Racer Advance's front end and race program share IWRAM. Each image writes
# its own value to the result word 0x02000010; the main loop logs the value
# after A to 0x02000000 and after B to 0x02000004, and counts completed
# cycles at 0x02000008, once per frame. The correct log is 0xA1, 0xB2.
#
# gbarecomp compiles one function per (address, instruction set), so a corpus
# with A at 0x03000000 (tests/repro/overlay1.toml) runs A's generated body
# whenever 0x03000000 is dispatched: after B is copied, the call still writes
# 0xA1, and the log reads 0xA1, 0xA1 with no dispatch miss, even under
# GBARECOMP_STRICT_STATIC=1. With patch 0006, B is compiled as a second corpus
# (tests/repro/overlay1.ovl.toml, gba_recompile --output-prefix ovl_), and the
# selector in tests/repro/overlay1_hooks.cpp picks the corpus whose image
# matches the live IWRAM word at the dispatch target.
#
# The two images differ at every offset, as Moto Racer Advance's do (none of
# their 525 overlapping words is equal, docs/research/phase2-diagnosis.md
# section 3.1); check_overlay_images() below checks it whenever the ROM is
# built. B is one word longer than A, so after A is copied over B, B's last
# word stays at 0x03000010, as the longer race image's tail stays behind the
# front-end image in the game.
OVERLAY_IMAGE_A = 0x08000400        # ROM source of image A
OVERLAY_SIZE_A = 0x10               # 4 words
OVERLAY_IMAGE_B = 0x08000500        # ROM source of image B
OVERLAY_SIZE_B = 0x14               # 5 words
OVERLAY1 = {
    # Start-up: install the IRQ handler, enable the VBlank IRQ, switch to
    # System mode with IRQs enabled, then run the main loop.
    0x080000C0: 0xE59F0038,  # ldr r0, [pc, #0x38]   -> 0x03007FFC (literal at 0x08000100)
    0x080000C4: 0xE59F1038,  # ldr r1, [pc, #0x38]   -> 0x08000180 (handler)
    0x080000C8: 0xE5801000,  # str r1, [r0]          user IRQ handler pointer
    0x080000CC: 0xE3A00301,  # mov r0, #0x04000000
    0x080000D0: 0xE3A01008,  # mov r1, #8
    0x080000D4: 0xE1C010B4,  # strh r1, [r0, #4]     DISPSTAT: VBlank IRQ enable
    0x080000D8: 0xE2802C02,  # add r2, r0, #0x200
    0x080000DC: 0xE3A01001,  # mov r1, #1
    0x080000E0: 0xE1C210B0,  # strh r1, [r2]         IE = VBlank
    0x080000E4: 0xE1C210B8,  # strh r1, [r2, #8]     IME = 1
    0x080000E8: 0xE321F01F,  # msr cpsr_c, #0x1F     System mode, IRQs enabled
    0x080000EC: b(0x080000EC, 0x08000200),             # b loop
    0x08000100: 0x03007FFC,
    0x08000104: 0x08000180,
    # VBlank handler: acknowledge the IRQ and flag it for VBlankIntrWait.
    0x08000180: 0xE3A00301,  # mov r0, #0x04000000
    0x08000184: 0xE2800C02,  # add r0, r0, #0x200
    0x08000188: 0xE3A01001,  # mov r1, #1
    0x0800018C: 0xE1C010B2,  # strh r1, [r0, #2]     IF: acknowledge VBlank
    0x08000190: 0xE59F000C,  # ldr r0, [pc, #0xC]    -> 0x03007FF8 (literal at 0x080001A4)
    0x08000194: 0xE1D010B0,  # ldrh r1, [r0]
    0x08000198: 0xE3811001,  # orr r1, r1, #1
    0x0800019C: 0xE1C010B0,  # strh r1, [r0]         BIOS IntrCheck |= VBlank
    0x080001A0: 0xE12FFF1E,  # bx lr
    0x080001A4: 0x03007FF8,
    # Main loop, one cycle per frame.
    0x08000200: 0xE3A04402,  # loop: mov r4, #0x02000000
    0x08000204: 0xE3A00408,  # mov r0, #0x08000000
    0x08000208: 0xE2800B01,  # add r0, r0, #0x400    image A
    0x0800020C: 0xE3A02004,  # mov r2, #4            its size in words
    0x08000210: b(0x08000210, 0x08000300, link=True),  # bl copy
    0x08000214: 0xE3A05000,  # mov r5, #0
    0x08000218: 0xE5845010,  # str r5, [r4, #0x10]   clear the result word
    0x0800021C: b(0x0800021C, 0x08000320, link=True),  # bl call_iwram
    0x08000220: 0xE5945010,  # ldr r5, [r4, #0x10]
    0x08000224: 0xE5845000,  # str r5, [r4]          log: result after A
    0x08000228: 0xE3A00408,  # mov r0, #0x08000000
    0x0800022C: 0xE2800C05,  # add r0, r0, #0x500    image B
    0x08000230: 0xE3A02005,  # mov r2, #5            its size in words
    0x08000234: b(0x08000234, 0x08000300, link=True),  # bl copy
    0x08000238: 0xE3A05000,  # mov r5, #0
    0x0800023C: 0xE5845010,  # str r5, [r4, #0x10]   clear the result word
    0x08000240: b(0x08000240, 0x08000320, link=True),  # bl call_iwram
    0x08000244: 0xE5945010,  # ldr r5, [r4, #0x10]
    0x08000248: 0xE5845004,  # str r5, [r4, #4]      log: result after B
    0x0800024C: 0xE5945008,  # ldr r5, [r4, #8]
    0x08000250: 0xE2855001,  # add r5, r5, #1
    0x08000254: 0xE5845008,  # str r5, [r4, #8]      cycles completed
    0x08000258: 0xEF050000,  # swi 0x050000          VBlankIntrWait
    0x0800025C: b(0x0800025C, 0x08000200),             # b loop
    # copy: r2 words from r0 to IWRAM 0x03000000, one word at a time.
    0x08000300: 0xE3A01403,  # mov r1, #0x03000000
    0x08000304: 0xE4903004,  # copy_loop: ldr r3, [r0], #4
    0x08000308: 0xE4813004,  # str r3, [r1], #4
    0x0800030C: 0xE2522001,  # subs r2, r2, #1
    0x08000310: b(0x08000310, 0x08000304, cond=0x1),   # bne copy_loop
    0x08000314: 0xE12FFF1E,  # bx lr
    # call_iwram: tail-call the image at 0x03000000; it returns to the BL
    # site in the main loop. A BX, so every call goes through the dispatcher.
    0x08000320: 0xE3A0C403,  # mov r12, #0x03000000
    0x08000324: 0xE12FFF1C,  # bx r12
    # Image A, run at 0x03000000.
    OVERLAY_IMAGE_A + 0x0: 0xE3A010A1,  # mov r1, #0xA1
    OVERLAY_IMAGE_A + 0x4: 0xE3A00402,  # mov r0, #0x02000000
    OVERLAY_IMAGE_A + 0x8: 0xE5801010,  # str r1, [r0, #0x10]
    OVERLAY_IMAGE_A + 0xC: 0xE12FFF1E,  # bx lr
    # Image B, run at 0x03000000.
    OVERLAY_IMAGE_B + 0x0: 0xE3A02402,  # mov r2, #0x02000000
    OVERLAY_IMAGE_B + 0x4: 0xE3A030B0,  # mov r3, #0xB0
    OVERLAY_IMAGE_B + 0x8: 0xE2833002,  # add r3, r3, #2
    OVERLAY_IMAGE_B + 0xC: 0xE5823010,  # str r3, [r2, #0x10]
    OVERLAY_IMAGE_B + 0x10: 0xE1A0F00E,  # mov pc, lr
}



def check_overlay_images():
    """Stop unless every word of images A and B is defined and the two images
    differ at every offset they share. The selectors in
    tests/repro/overlay1_hooks.cpp and overlay1heal_hooks.cpp tell the images
    apart by the one word at the dispatch target."""
    for base, size in ((OVERLAY_IMAGE_A, OVERLAY_SIZE_A),
                       (OVERLAY_IMAGE_B, OVERLAY_SIZE_B)):
        for off in range(0, size, 4):
            if base + off not in OVERLAY1:
                sys.exit('make_rom.py: overlay1 has no word at 0x%08X' % (base + off))
    for off in range(0, min(OVERLAY_SIZE_A, OVERLAY_SIZE_B), 4):
        word = OVERLAY1[OVERLAY_IMAGE_A + off]
        if word == OVERLAY1[OVERLAY_IMAGE_B + off]:
            sys.exit('make_rom.py: overlay images A and B have the same word, '
                     '%08X, at offset 0x%X' % (word, off))


CASES = {
    'irqleak1': (b'IRQLEAKTEST', b'ZZZZ', {**STARTUP, **IRQLEAK1}),
    'irqleak2': (b'IRQLEAKTST2', b'ZZZY', {**STARTUP, **IRQLEAK2}),
    'irqleak3': (b'IRQLEAKTST3', b'ZZZX', {**STARTUP, **IRQLEAK1}),
    'overlay1': (b'RAMOVERLAY1', b'ZZZW', OVERLAY1),
    # overlay1's bytes, with another config (tests/repro/overlay1heal.toml).
    'overlay1heal': (b'RAMOVERLAY1', b'ZZZW', OVERLAY1),
}


def build(case):
    title, game_code, code = CASES[case]
    if code is OVERLAY1:
        check_overlay_images()
    rom = bytearray(ROM_SIZE)
    header(rom, title, game_code)
    for addr, word in code.items():
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
