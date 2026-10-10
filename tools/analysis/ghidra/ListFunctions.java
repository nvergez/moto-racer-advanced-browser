// List functions as TSV: entry, name, mode (ARM/Thumb), body size in bytes,
// instruction count, memory block, number of callers.
// Args: [block=NAME] [min=BYTES] [out=FILE]
//@category GBA

import java.io.PrintWriter;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryBlock;

public class ListFunctions extends GhidraScript {
	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		PrintWriter out = MraOut.open(this, args);
		String blockFilter = MraOut.opt(args, "block", null);
		long min = Long.parseLong(MraOut.opt(args, "min", "0"));
		out.println("entry\tname\tmode\tsize\tinstructions\tblock\tcallers");
		Listing listing = currentProgram.getListing();
		int n = 0;
		for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
			MemoryBlock b = currentProgram.getMemory().getBlock(f.getEntryPoint());
			String bname = b == null ? "?" : b.getName();
			if (blockFilter != null && !blockFilter.equalsIgnoreCase(bname)) {
				continue;
			}
			long size = f.getBody().getNumAddresses();
			if (size < min) {
				continue;
			}
			int insns = 0;
			InstructionIterator it = listing.getInstructions(f.getBody(), true);
			while (it.hasNext()) {
				it.next();
				insns++;
			}
			int callers = f.getCallingFunctions(monitor).size();
			out.printf("0x%08X\t%s\t%s\t%d\t%d\t%s\t%d%n", f.getEntryPoint().getOffset(), f.getName(),
				MraOut.mode(currentProgram, f.getEntryPoint()), size, insns, bname, callers);
			n++;
		}
		MraOut.close(out);
		println("listed " + n + " functions");
	}
}
