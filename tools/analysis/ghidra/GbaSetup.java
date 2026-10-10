// Prepare a raw GBA ROM import for analysis: memory map, I/O register labels,
// BIOS-reserved IWRAM labels, cartridge header data, and the ARM entry point.
//
// Intended as an analyzeHeadless -preScript on a program imported with
//   -loader BinaryLoader -loader-baseAddr 0x08000000 -loader-blockName ROM
//   -processor ARM:LE:32:v4t
// Safe to re-run: existing blocks/labels are skipped.
//
// Contains no ROM data: only GBA hardware constants (from GBATEK).
//@category GBA

import java.math.BigInteger;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.SourceType;

public class GbaSetup extends GhidraScript {

	// name, start, size, read, write, execute, volatile
	private static final Object[][] BLOCKS = {
		{ "BIOS",      0x00000000L, 0x4000L,    true, false, true,  false },
		{ "EWRAM",     0x02000000L, 0x40000L,   true, true,  true,  false },
		{ "IWRAM",     0x03000000L, 0x8000L,    true, true,  true,  false },
		{ "IO",        0x04000000L, 0x400L,     true, true,  false, true  },
		{ "PALETTE",   0x05000000L, 0x400L,     true, true,  false, true  },
		{ "VRAM",      0x06000000L, 0x18000L,   true, true,  false, true  },
		{ "OAM",       0x07000000L, 0x400L,     true, true,  false, true  },
		// Upper half of the wait-state-2 ROM mirror; EEPROM saves are accessed here.
		{ "CART_WS2_HI", 0x0D000000L, 0x1000000L, true, true, false, true },
		// SRAM / Flash save area.
		{ "SRAM",      0x0E000000L, 0x10000L,   true, true,  false, true  },
	};

	// offset, size (1/2/4, or N>4 for byte arrays), name
	private static final Object[][] IO_REGS = {
		{ 0x000, 2, "REG_DISPCNT" }, { 0x002, 2, "REG_GREENSWAP" }, { 0x004, 2, "REG_DISPSTAT" },
		{ 0x006, 2, "REG_VCOUNT" },
		{ 0x008, 2, "REG_BG0CNT" }, { 0x00A, 2, "REG_BG1CNT" }, { 0x00C, 2, "REG_BG2CNT" },
		{ 0x00E, 2, "REG_BG3CNT" },
		{ 0x010, 2, "REG_BG0HOFS" }, { 0x012, 2, "REG_BG0VOFS" }, { 0x014, 2, "REG_BG1HOFS" },
		{ 0x016, 2, "REG_BG1VOFS" }, { 0x018, 2, "REG_BG2HOFS" }, { 0x01A, 2, "REG_BG2VOFS" },
		{ 0x01C, 2, "REG_BG3HOFS" }, { 0x01E, 2, "REG_BG3VOFS" },
		{ 0x020, 2, "REG_BG2PA" }, { 0x022, 2, "REG_BG2PB" }, { 0x024, 2, "REG_BG2PC" },
		{ 0x026, 2, "REG_BG2PD" }, { 0x028, 4, "REG_BG2X" }, { 0x02C, 4, "REG_BG2Y" },
		{ 0x030, 2, "REG_BG3PA" }, { 0x032, 2, "REG_BG3PB" }, { 0x034, 2, "REG_BG3PC" },
		{ 0x036, 2, "REG_BG3PD" }, { 0x038, 4, "REG_BG3X" }, { 0x03C, 4, "REG_BG3Y" },
		{ 0x040, 2, "REG_WIN0H" }, { 0x042, 2, "REG_WIN1H" }, { 0x044, 2, "REG_WIN0V" },
		{ 0x046, 2, "REG_WIN1V" }, { 0x048, 2, "REG_WININ" }, { 0x04A, 2, "REG_WINOUT" },
		{ 0x04C, 2, "REG_MOSAIC" }, { 0x050, 2, "REG_BLDCNT" }, { 0x052, 2, "REG_BLDALPHA" },
		{ 0x054, 2, "REG_BLDY" },
		{ 0x060, 2, "REG_SOUND1CNT_L" }, { 0x062, 2, "REG_SOUND1CNT_H" }, { 0x064, 2, "REG_SOUND1CNT_X" },
		{ 0x068, 2, "REG_SOUND2CNT_L" }, { 0x06C, 2, "REG_SOUND2CNT_H" },
		{ 0x070, 2, "REG_SOUND3CNT_L" }, { 0x072, 2, "REG_SOUND3CNT_H" }, { 0x074, 2, "REG_SOUND3CNT_X" },
		{ 0x078, 2, "REG_SOUND4CNT_L" }, { 0x07C, 2, "REG_SOUND4CNT_H" },
		{ 0x080, 2, "REG_SOUNDCNT_L" }, { 0x082, 2, "REG_SOUNDCNT_H" }, { 0x084, 2, "REG_SOUNDCNT_X" },
		{ 0x088, 2, "REG_SOUNDBIAS" }, { 0x090, 16, "REG_WAVE_RAM" },
		{ 0x0A0, 4, "REG_FIFO_A" }, { 0x0A4, 4, "REG_FIFO_B" },
		{ 0x0B0, 4, "REG_DMA0SAD" }, { 0x0B4, 4, "REG_DMA0DAD" }, { 0x0B8, 2, "REG_DMA0CNT_L" },
		{ 0x0BA, 2, "REG_DMA0CNT_H" },
		{ 0x0BC, 4, "REG_DMA1SAD" }, { 0x0C0, 4, "REG_DMA1DAD" }, { 0x0C4, 2, "REG_DMA1CNT_L" },
		{ 0x0C6, 2, "REG_DMA1CNT_H" },
		{ 0x0C8, 4, "REG_DMA2SAD" }, { 0x0CC, 4, "REG_DMA2DAD" }, { 0x0D0, 2, "REG_DMA2CNT_L" },
		{ 0x0D2, 2, "REG_DMA2CNT_H" },
		{ 0x0D4, 4, "REG_DMA3SAD" }, { 0x0D8, 4, "REG_DMA3DAD" }, { 0x0DC, 2, "REG_DMA3CNT_L" },
		{ 0x0DE, 2, "REG_DMA3CNT_H" },
		{ 0x100, 2, "REG_TM0CNT_L" }, { 0x102, 2, "REG_TM0CNT_H" }, { 0x104, 2, "REG_TM1CNT_L" },
		{ 0x106, 2, "REG_TM1CNT_H" }, { 0x108, 2, "REG_TM2CNT_L" }, { 0x10A, 2, "REG_TM2CNT_H" },
		{ 0x10C, 2, "REG_TM3CNT_L" }, { 0x10E, 2, "REG_TM3CNT_H" },
		{ 0x120, 4, "REG_SIODATA32" }, { 0x124, 2, "REG_SIOMULTI2" }, { 0x126, 2, "REG_SIOMULTI3" },
		{ 0x128, 2, "REG_SIOCNT" }, { 0x12A, 2, "REG_SIODATA8" },
		{ 0x130, 2, "REG_KEYINPUT" }, { 0x132, 2, "REG_KEYCNT" }, { 0x134, 2, "REG_RCNT" },
		{ 0x140, 2, "REG_JOYCNT" }, { 0x150, 4, "REG_JOY_RECV" }, { 0x154, 4, "REG_JOY_TRANS" },
		{ 0x158, 2, "REG_JOYSTAT" },
		{ 0x200, 2, "REG_IE" }, { 0x202, 2, "REG_IF" }, { 0x204, 2, "REG_WAITCNT" },
		{ 0x208, 2, "REG_IME" }, { 0x300, 1, "REG_POSTFLG" }, { 0x301, 1, "REG_HALTCNT" },
	};

	@Override
	public void run() throws Exception {
		Memory mem = currentProgram.getMemory();

		MemoryBlock rom = mem.getBlock(toAddr(0x08000000L));
		if (rom == null) {
			throw new IllegalStateException("No block at 0x08000000: import with -loader-baseAddr 0x08000000");
		}
		rom.setWrite(false);
		rom.setExecute(true);
		if (!rom.getName().equals("ROM")) {
			rom.setName("ROM");
		}

		for (Object[] b : BLOCKS) {
			String name = (String) b[0];
			Address start = toAddr((Long) b[1]);
			long size = (Long) b[2];
			if (mem.getBlock(start) != null) {
				println("block exists, skipped: " + name);
				continue;
			}
			MemoryBlock blk = mem.createUninitializedBlock(name, start, size, false);
			blk.setRead((Boolean) b[3]);
			blk.setWrite((Boolean) b[4]);
			blk.setExecute((Boolean) b[5]);
			blk.setVolatile((Boolean) b[6]);
			println(String.format("block %-12s %s size 0x%X", name, start, size));
		}

		for (Object[] r : IO_REGS) {
			Address a = toAddr(0x04000000L + (Integer) r[0]);
			int size = (Integer) r[1];
			label(a, (String) r[2]);
			DataType dt = size == 1 ? ByteDataType.dataType
				: size == 2 ? WordDataType.dataType
				: size == 4 ? DWordDataType.dataType
				: new ArrayDataType(ByteDataType.dataType, size, 1);
			safeCreateData(a, dt);
		}

		// BIOS-reserved words at the top of IWRAM (GBATEK, "BIOS RAM usage").
		label(toAddr(0x03007FFCL), "BIOS_IRQ_HANDLER");
		safeCreateData(toAddr(0x03007FFCL), PointerDataType.dataType);
		label(toAddr(0x03007FF8L), "BIOS_IRQ_CHECK_FLAGS");
		safeCreateData(toAddr(0x03007FF8L), WordDataType.dataType);
		label(toAddr(0x03007FF4L), "BIOS_SOUND_BUFFER_PTR_UNUSED");
		label(toAddr(0x03007FF0L), "BIOS_SOUND_AREA_PTR");
		safeCreateData(toAddr(0x03007FF0L), PointerDataType.dataType);
		label(toAddr(0x03007F00L), "BIOS_STACK_USR_DEFAULT_TOP");
		label(toAddr(0x03007FA0L), "BIOS_STACK_IRQ_DEFAULT_TOP");
		label(toAddr(0x03007FE0L), "BIOS_STACK_SVC_DEFAULT_TOP");

		// Cartridge header.
		label(toAddr(0x08000000L), "rom_header_entry_branch");
		label(toAddr(0x08000004L), "rom_header_logo");
		safeCreateData(toAddr(0x08000004L), new ArrayDataType(ByteDataType.dataType, 156, 1));
		label(toAddr(0x080000A0L), "rom_header_title");
		safeCreateData(toAddr(0x080000A0L), new StringDataType(), 12);
		label(toAddr(0x080000ACL), "rom_header_game_code");
		safeCreateData(toAddr(0x080000ACL), new StringDataType(), 4);
		label(toAddr(0x080000B0L), "rom_header_maker_code");
		safeCreateData(toAddr(0x080000B0L), new StringDataType(), 2);
		label(toAddr(0x080000B2L), "rom_header_fixed_96");
		safeCreateData(toAddr(0x080000B2L), ByteDataType.dataType);
		label(toAddr(0x080000BCL), "rom_header_version");
		safeCreateData(toAddr(0x080000BCL), ByteDataType.dataType);
		label(toAddr(0x080000BDL), "rom_header_complement");
		safeCreateData(toAddr(0x080000BDL), ByteDataType.dataType);

		// The entry word is an ARM branch executed by the BIOS after boot.
		Register tmode = currentProgram.getProgramContext().getRegister("TMode");
		Address entry = toAddr(0x08000000L);
		currentProgram.getProgramContext().setValue(tmode, entry, entry.add(3), BigInteger.ZERO);
		addEntryPoint(entry);
		disassemble(entry);
		Function f = getFunctionAt(entry);
		if (f == null) {
			f = createFunction(entry, "_entry");
		}
		if (f != null && f.getName().startsWith("FUN_")) {
			f.setName("_entry", SourceType.USER_DEFINED);
		}
		println("GbaSetup done");
	}

	private void label(Address a, String name) throws Exception {
		if (getSymbol(name, null) != null) {
			return;
		}
		createLabel(a, name, true, SourceType.IMPORTED);
	}

	private void safeCreateData(Address a, DataType dt) {
		safeCreateData(a, dt, -1);
	}

	private void safeCreateData(Address a, DataType dt, int len) {
		try {
			if (getDataAt(a) != null && getDataAt(a).isDefined()) {
				return;
			}
			if (len > 0) {
				currentProgram.getListing().createData(a, dt, len);
			} else {
				createData(a, dt);
			}
		} catch (Exception e) {
			// Uninitialized blocks accept data types too; anything else is non-fatal.
			println("data at " + a + " skipped: " + e.getMessage());
		}
	}
}
