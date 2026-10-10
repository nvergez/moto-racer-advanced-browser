// Seed disassembly and functions from gbaharness dynamic data, with the
// ARM/Thumb mode the CPU actually used.
// Args: [calls=calls.tsv] [coverage=coverage.tsv] [range=LO-HI] [space=OVERLAY]
//       [analyze=true|false] [out=FILE]
//   calls     call targets (BL / mov lr,pc+bx / bx veneers): disassemble and
//             create a function at each one.
//   coverage  executed instruction addresses: disassemble where nothing is yet.
//   range     only use addresses in [LO, HI] (RAM contents differ between game
//             states, so restrict RAM seeding to the state that matches the block).
//   space     put the addresses into overlay space NAME (e.g. IWRAM_BOOT).
//   analyze   run auto-analysis on the changes afterwards (default true).
//   fix       true: where static analysis disagrees with what the CPU executed
//             (wrong ARM/Thumb mode, or the address is inside other code/data),
//             clear that code unit and re-disassemble in the executed mode.
//             Default false: conflicts are only listed.
// Addresses whose block has no bytes, or that were executed in both modes,
// are skipped and counted.
//@category GBA

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.PrintWriter;
import java.math.BigInteger;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSpace;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.CodeUnit;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.SourceType;

public class SeedFromHarness extends GhidraScript {
	private Register tmode;
	private AddressSpace space;
	private long lo = 0, hi = 0xFFFFFFFFL;
	private int disasm, funcs, skippedNoBytes, skippedBothModes, conflicts, existing, outOfRange, fixed;
	private boolean fix;
	private final java.util.List<String> conflictLog = new java.util.ArrayList<>();

	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		PrintWriter out = MraOut.open(this, args);
		tmode = currentProgram.getProgramContext().getRegister("TMode");
		String spaceName = MraOut.opt(args, "space", null);
		space = spaceName == null ? currentProgram.getAddressFactory().getDefaultAddressSpace()
			: currentProgram.getAddressFactory().getAddressSpace(spaceName);
		if (space == null) {
			throw new IllegalArgumentException("no address space " + spaceName);
		}
		String range = MraOut.opt(args, "range", null);
		if (range != null) {
			String[] p = range.split("-");
			lo = MraOut.parseNum(p[0]);
			hi = MraOut.parseNum(p[1]);
		}
		fix = Boolean.parseBoolean(MraOut.opt(args, "fix", "false"));
		String calls = MraOut.opt(args, "calls", null);
		String cov = MraOut.opt(args, "coverage", null);
		if (calls != null) {
			seed(calls, true);
			out.printf("calls %s: functions created %d, disassembled %d, existing %d, conflicts %d (fixed %d), no bytes %d, out of range %d%n",
				calls, funcs, disasm, existing, conflicts, fixed, skippedNoBytes, outOfRange);
		}
		if (cov != null) {
			funcs = disasm = existing = conflicts = skippedNoBytes = skippedBothModes = outOfRange = fixed = 0;
			seed(cov, false);
			out.printf("coverage %s: disassembled %d, already code %d, conflicts %d (fixed %d), both-mode %d, no bytes %d, out of range %d%n",
				cov, disasm, existing, conflicts, fixed, skippedBothModes, skippedNoBytes, outOfRange);
		}
		if (!conflictLog.isEmpty()) {
			out.println("# conflicts (executed_addr executed_mode | what static analysis has there):");
			for (int i = 0; i < conflictLog.size() && i < 300; i++) {
				out.println("#   " + conflictLog.get(i));
			}
			if (conflictLog.size() > 300) {
				out.println("#   ... " + (conflictLog.size() - 300) + " more");
			}
		}
		if (Boolean.parseBoolean(MraOut.opt(args, "analyze", "true"))) {
			analyzeChanges(currentProgram);
		}
		MraOut.close(out);
	}

	private void seed(String path, boolean isCalls) throws Exception {
		try (BufferedReader r = new BufferedReader(new FileReader(path))) {
			String line;
			while ((line = r.readLine()) != null) {
				if (line.startsWith("target") || line.startsWith("addr") || line.startsWith("#")) {
					continue;
				}
				String[] f = line.split("\t");
				long off = Long.parseLong(f[0], 16);
				String mode = f[1];
				if (off < lo || off > hi) {
					outOfRange++;
					continue;
				}
				if (mode.equals("AT")) {
					skippedBothModes++;
					continue;
				}
				Address a = space.getAddress(off);
				MemoryBlock b = currentProgram.getMemory().getBlock(a);
				if (b == null || !(b.isInitialized() || b.isMapped())) {
					skippedNoBytes++;
					continue;
				}
				boolean thumb = mode.equals("T");
				Instruction ins = getInstructionAt(a);
				String why = null;
				if (ins == null && thumb) {
					// A Thumb BL is two 16-bit halves to the CPU but one 4-byte instruction to Ghidra.
					Instruction c = getInstructionContaining(a);
					if (c != null && c.getLength() == 4 && c.getAddress().equals(a.subtract(2)) &&
						MraOut.mode(currentProgram, c.getAddress()).equals("Thumb")) {
						existing++;
						continue;
					}
				}
				if (ins == null) {
					CodeUnit cu = getInstructionContaining(a);
					if (cu == null) {
						cu = currentProgram.getListing().getDefinedDataContaining(a);
					}
					if (cu != null) {
						why = "inside " + cu.getAddress() + " " + MraOut.mode(currentProgram, cu.getAddress()) + " " + cu;
					}
				} else {
					BigInteger v = currentProgram.getProgramContext().getValue(tmode, a, false);
					boolean isThumb = v != null && v.intValue() == 1;
					if (isThumb != thumb) {
						why = "instruction in other mode: " + ins;
					}
				}
				if (why != null) {
					conflicts++;
					conflictLog.add(String.format("%s %s | %s", a, thumb ? "T" : "A", why));
					if (!fix) {
						continue;
					}
					CodeUnit cu = getInstructionContaining(a);
					if (cu == null) {
						cu = currentProgram.getListing().getDefinedDataContaining(a);
					}
					Address cs = cu != null ? cu.getAddress() : a;
					Address ce = cu != null ? cu.getMaxAddress() : a;
					clearListing(cs, ce.compareTo(a.add(thumb ? 1 : 3)) > 0 ? ce : a.add(thumb ? 1 : 3));
					ins = null;
					fixed++;
				}
				if (ins == null) {
					try {
						currentProgram.getProgramContext().setValue(tmode, a, a,
							thumb ? BigInteger.ONE : BigInteger.ZERO);
					} catch (Exception e) {
						conflicts++;
						conflictLog.add(String.format("%s %s | context change refused: %s", a, thumb ? "T" : "A", e.getMessage()));
						continue;
					}
					if (disassemble(a)) {
						disasm++;
					}
				} else {
					existing++;
				}
				if (isCalls && getFunctionAt(a) == null && getInstructionAt(a) != null) {
					Function fn = createFunction(a, null);
					if (fn != null) {
						funcs++;
					}
				}
			}
		}
	}
}
