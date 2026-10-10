// Dump disassembly and/or decompiler output for the function containing an
// address (or a raw address range).
// Args: ADDRESS|SYMBOL [what=both|disasm|decomp] [mode=arm|thumb] [len=BYTES] [out=FILE]
//   ADDRESS may be 0x..., an overlay address like IWRAM_BOOT::0x03000034, or a symbol name.
//   If no function contains ADDRESS, one is created at ADDRESS (disassembling
//   with mode=, default ARM). Under -readOnly that change is not saved.
//   len=BYTES dumps a raw disassembly range instead of a function.
// Disassembly lines show: address, bytes, instruction, then for each data
// reference the referenced symbol and, for initialized memory, its 32-bit value.
//@category GBA

import java.io.PrintWriter;
import java.math.BigInteger;
import java.util.List;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.Symbol;

public class DumpFunction extends GhidraScript {
	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		List<String> pos = MraOut.positional(args);
		if (pos.isEmpty()) {
			throw new IllegalArgumentException("usage: DumpFunction.java ADDRESS [what=both|disasm|decomp] [mode=arm|thumb] [len=N] [out=FILE]");
		}
		PrintWriter out = MraOut.open(this, args);
		String what = MraOut.opt(args, "what", "both");
		String modeArg = MraOut.opt(args, "mode", null);
		String lenArg = MraOut.opt(args, "len", null);
		Address addr = resolve(pos.get(0));

		CodeUnitFormat cuf = new CodeUnitFormat(CodeUnitFormatOptions.ShowBlockName.NEVER,
			CodeUnitFormatOptions.ShowNamespace.NEVER);

		if (lenArg != null) {
			long len = MraOut.parseNum(lenArg);
			ensureCode(addr, modeArg);
			AddressSet range = new AddressSet(addr, addr.add(len - 1));
			out.printf("# raw range %s..%s (%s)%n", addr, addr.add(len - 1), MraOut.mode(currentProgram, addr));
			disasm(out, cuf, range);
			MraOut.close(out);
			return;
		}

		Function f = getFunctionContaining(addr);
		if (f == null) {
			ensureCode(addr, modeArg);
			f = createFunction(addr, null);
			if (f == null) {
				throw new IllegalStateException("could not create a function at " + addr);
			}
			out.printf("# note: function created at %s for this dump (persists only with ghidra_run.sh --write on a private copy)%n", addr);
		}
		MemoryBlock b = currentProgram.getMemory().getBlock(f.getEntryPoint());
		out.printf("# function %s at %s  mode=%s  size=%d  block=%s%n", f.getName(), f.getEntryPoint(),
			MraOut.mode(currentProgram, f.getEntryPoint()), f.getBody().getNumAddresses(),
			b == null ? "?" : b.getName());
		out.printf("# callers: %s%n", f.getCallingFunctions(monitor));
		out.printf("# callees: %s%n", f.getCalledFunctions(monitor));
		if (what.equals("both") || what.equals("disasm")) {
			out.println("# ---- disassembly");
			disasm(out, cuf, f.getBody());
		}
		if (what.equals("both") || what.equals("decomp")) {
			out.println("# ---- decompiler");
			DecompInterface ifc = new DecompInterface();
			ifc.setOptions(new DecompileOptions());
			ifc.openProgram(currentProgram);
			DecompileResults r = ifc.decompileFunction(f, 120, monitor);
			if (r.decompileCompleted()) {
				out.println(r.getDecompiledFunction().getC());
			} else {
				out.println("// decompilation failed: " + r.getErrorMessage());
			}
			ifc.dispose();
		}
		MraOut.close(out);
	}

	private Address resolve(String s) {
		if (s.contains("::")) { // overlay address, e.g. IWRAM_BOOT::0x03000034
			String[] p = s.split("::");
			ghidra.program.model.address.AddressSpace sp = currentProgram.getAddressFactory().getAddressSpace(p[0]);
			if (sp == null) {
				throw new IllegalArgumentException("no address space " + p[0]);
			}
			return sp.getAddress(MraOut.parseNum(p[1].startsWith("0x") ? p[1] : "0x" + p[1]));
		}
		if (s.toLowerCase().startsWith("0x") || s.matches("[0-9a-fA-F]{6,8}")) {
			return toAddr(MraOut.parseNum(s.startsWith("0x") || s.startsWith("0X") ? s : "0x" + s));
		}
		List<Symbol> syms = getSymbols(s, null);
		if (syms.isEmpty()) {
			throw new IllegalArgumentException("no symbol " + s);
		}
		return syms.get(0).getAddress();
	}

	private void ensureCode(Address addr, String modeArg) throws Exception {
		if (getInstructionAt(addr) != null) {
			return;
		}
		if (modeArg != null) {
			Register tmode = currentProgram.getProgramContext().getRegister("TMode");
			BigInteger v = modeArg.equalsIgnoreCase("thumb") ? BigInteger.ONE : BigInteger.ZERO;
			currentProgram.getProgramContext().setValue(tmode, addr, addr, v);
		}
		disassemble(addr);
	}

	private void disasm(PrintWriter out, CodeUnitFormat cuf, AddressSetView body) throws Exception {
		Listing listing = currentProgram.getListing();
		CodeUnitIterator it = listing.getCodeUnits(body, true);
		while (it.hasNext()) {
			CodeUnit cu = it.next();
			Symbol primary = getSymbolAt(cu.getAddress());
			if (primary != null) {
				out.printf("%s:%n", primary.getName());
			}
			StringBuilder bytes = new StringBuilder();
			byte[] bs = cu.getBytes();
			for (int i = 0; i < bs.length && i < 8; i++) {
				bytes.append(String.format("%02x", bs[i] & 0xff));
			}
			StringBuilder note = new StringBuilder();
			if (cu instanceof Instruction) {
				for (Reference ref : cu.getReferencesFrom()) {
					if (!ref.isMemoryReference()) {
						continue;
					}
					Address to = ref.getToAddress();
					Symbol s = getSymbolAt(to);
					note.append("  ; ").append(ref.getReferenceType()).append(" ").append(to);
					if (s != null) {
						note.append(" ").append(s.getName());
					}
					if (ref.getReferenceType().isData()) {
						MemoryBlock blk = currentProgram.getMemory().getBlock(to);
						if (blk != null && (blk.isInitialized() || blk.isMapped())) {
							try {
								int v = currentProgram.getMemory().getInt(to);
								Symbol vs = getSymbolAt(toAddr(v & 0xFFFFFFFFL));
								note.append(String.format(" = 0x%08X", v));
								if (vs != null) {
									note.append(" (").append(vs.getName()).append(")");
								}
							} catch (Exception e) {
								// value outside memory map
							}
						}
					}
				}
			}
			out.printf("  %s  %-16s %s%s%n", cu.getAddress(), bytes, cuf.getRepresentationString(cu), note);
		}
	}
}
