// Print a summary of the current analysis state: functions by ARM/Thumb mode,
// instruction bytes per memory block, and ROM coverage.
// Args: [out=FILE]
//@category GBA

import java.io.PrintWriter;
import java.math.BigInteger;
import java.util.LinkedHashMap;
import java.util.Map;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryBlock;

public class AnalysisSummary extends GhidraScript {
	@Override
	public void run() throws Exception {
		PrintWriter out = MraOut.open(this, getScriptArgs());
		Register tmode = currentProgram.getProgramContext().getRegister("TMode");
		int arm = 0, thumb = 0, total = 0;
		long armBytes = 0, thumbBytes = 0;
		for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
			total++;
			BigInteger v = currentProgram.getProgramContext().getValue(tmode, f.getEntryPoint(), false);
			long size = f.getBody().getNumAddresses();
			if (v != null && v.intValue() == 1) {
				thumb++;
				thumbBytes += size;
			} else {
				arm++;
				armBytes += size;
			}
		}
		out.printf("program: %s  language: %s%n", currentProgram.getName(),
			currentProgram.getLanguageID());
		out.printf("functions: %d (ARM %d, %d bytes; Thumb %d, %d bytes)%n", total, arm, armBytes,
			thumb, thumbBytes);

		Map<String, long[]> perBlock = new LinkedHashMap<>();
		for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
			perBlock.put(b.getName(), new long[] { 0, 0, b.getSize(), b.isInitialized() ? 1 : b.isMapped() ? 2 : 0 });
		}
		long insns = 0;
		InstructionIterator it = currentProgram.getListing().getInstructions(true);
		while (it.hasNext()) {
			Instruction ins = it.next();
			insns++;
			MemoryBlock b = currentProgram.getMemory().getBlock(ins.getAddress());
			if (b != null) {
				long[] s = perBlock.get(b.getName());
				s[0]++;
				s[1] += ins.getLength();
			}
		}
		long dataBytes = 0;
		DataIterator dit = currentProgram.getListing().getDefinedData(true);
		while (dit.hasNext()) {
			dataBytes += dit.next().getLength();
		}
		out.printf("instructions: %d   defined data bytes: %d%n", insns, dataBytes);
		out.println("block           size        init  instructions  insn_bytes  pct_of_block");
		for (Map.Entry<String, long[]> e : perBlock.entrySet()) {
			long[] s = e.getValue();
			out.printf("%-14s  0x%08X  %-4s  %12d  %10d  %6.2f%%%n", e.getKey(), s[2],
				s[3] == 1 ? "yes" : s[3] == 2 ? "map" : "no", s[0], s[1], s[2] == 0 ? 0.0 : 100.0 * s[1] / s[2]);
		}
		out.flush();
		MraOut.close(out);
	}
}
