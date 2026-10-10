// List every disassembled SWI instruction with its BIOS call number.
// Args: [out=FILE]
// Thumb "swi #n": BIOS function = n (8-bit immediate).
// ARM "swi #n": the BIOS reads the 24-bit comment field and uses bits 16-23,
// so BIOS function = (n >> 16) & 0xFF.
// Only covers code Ghidra has disassembled; the harness --trace-swi option gives
// the dynamic SWI log (see ../README.md).
//@category GBA

import java.io.PrintWriter;
import java.util.TreeMap;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.scalar.Scalar;

public class FindSwi extends GhidraScript {
	private static final String[] NAMES = {
		"SoftReset", "RegisterRamReset", "Halt", "Stop", "IntrWait", "VBlankIntrWait", "Div", "DivArm", "Sqrt",
		"ArcTan", "ArcTan2", "CpuSet", "CpuFastSet", "GetBiosChecksum", "BgAffineSet", "ObjAffineSet",
		"BitUnPack", "LZ77UnCompWram", "LZ77UnCompVram", "HuffUnComp", "RLUnCompWram", "RLUnCompVram",
		"Diff8bitUnFilterWram", "Diff8bitUnFilterVram", "Diff16bitUnFilter", "SoundBias", "SoundDriverInit",
		"SoundDriverMode", "SoundDriverMain", "SoundDriverVSync", "SoundChannelClear", "MidiKey2Freq",
		"SoundWhatever0", "SoundWhatever1", "SoundWhatever2", "SoundWhatever3", "SoundWhatever4", "MultiBoot",
		"HardReset", "CustomHalt", "SoundDriverVSyncOff", "SoundDriverVSyncOn", "SoundGetJumpList",
	};

	@Override
	public void run() throws Exception {
		PrintWriter out = MraOut.open(this, getScriptArgs());
		out.println("address\tmode\timmediate\tbios_fn\tname\tfunction");
		TreeMap<Integer, Integer> counts = new TreeMap<>();
		InstructionIterator it = currentProgram.getListing().getInstructions(true);
		while (it.hasNext()) {
			Instruction ins = it.next();
			String m = ins.getMnemonicString().toLowerCase();
			if (!m.startsWith("swi") && !m.startsWith("svc")) {
				continue;
			}
			String mode = MraOut.mode(currentProgram, ins.getAddress());
			long imm = -1;
			for (Object o : ins.getOpObjects(0)) {
				if (o instanceof Scalar) {
					imm = ((Scalar) o).getUnsignedValue();
				}
			}
			int fn = imm < 0 ? -1 : (int) (mode.equals("Thumb") ? (imm & 0xFF) : ((imm >> 16) & 0xFF));
			String name = fn >= 0 && fn < NAMES.length ? NAMES[fn] : "?";
			// ARM semihosting call numbers (ARM C library / debugger), not GBA BIOS calls.
			if ((mode.equals("ARM") && imm == 0x123456) || (mode.equals("Thumb") && imm == 0xAB)) {
				name = "ARM_semihosting(not_BIOS)";
				fn = -2;
			}
			Function f = getFunctionContaining(ins.getAddress());
			out.printf("%s\t%s\t0x%X\t%s\t%s\t%s%n", ins.getAddress(), mode, imm,
				fn < 0 ? "-" : String.format("0x%02X", fn), name,
				f == null ? "-" : f.getName());
			counts.merge(fn, 1, Integer::sum);
		}
		out.println("# counts by BIOS function:");
		for (var e : counts.entrySet()) {
			int fn = e.getKey();
			String n = fn == -2 ? "ARM_semihosting(not_BIOS)" : fn >= 0 && fn < NAMES.length ? NAMES[fn] : "?";
			out.printf("#   %s %-26s %d%n", fn < 0 ? "  - " : String.format("0x%02X", fn), n, e.getValue());
		}
		MraOut.close(out);
	}
}
