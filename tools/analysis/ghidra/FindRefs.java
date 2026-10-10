// Find static references to an address range, e.g. REG_DISPCNT (0x04000000).
// Args: ADDRESS [len=BYTES (default 1)] [base=ADDR] [out=FILE]
// Three passes, each its own section in the TSV output:
//   refs     Ghidra references (from auto-analysis constant propagation) to any
//            byte in [ADDRESS, ADDRESS+len), with ref type (READ/WRITE/DATA...).
//   literal  32-bit words in initialized memory (literal pools) whose value is
//            in the range, plus the instructions that load each literal.
//   scalar   instructions with an immediate operand in the range
//            (e.g. ARM "mov r0,#0x4000000").
// base=ADDR additionally lists literals equal to ADDR (e.g. 0x04000000) so you
// can find "load base, then [base,#off]" accesses Ghidra did not resolve.
// Static analysis only: the harness --watch-write/--watch-read options give the
// dynamic equivalent (see ../README.md).
//@category GBA

import java.io.PrintWriter;
import java.util.List;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;

public class FindRefs extends GhidraScript {
	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		List<String> pos = MraOut.positional(args);
		if (pos.isEmpty()) {
			throw new IllegalArgumentException("usage: FindRefs.java ADDRESS [len=N] [base=ADDR] [out=FILE]");
		}
		PrintWriter out = MraOut.open(this, args);
		long lo = MraOut.parseNum(pos.get(0));
		long len = MraOut.parseNum(MraOut.opt(args, "len", "1"));
		long hi = lo + len - 1;
		String baseArg = MraOut.opt(args, "base", null);
		long base = baseArg == null ? -1 : MraOut.parseNum(baseArg);

		out.println("section\tfrom\tmode\tfunction\tkind\ttarget\tinstruction");
		// Pass 1: references.
		int nRefs = 0;
		for (long a = lo; a <= hi; a++) {
			Address to = toAddr(a);
			ReferenceIterator it = currentProgram.getReferenceManager().getReferencesTo(to);
			while (it.hasNext()) {
				Reference r = it.next();
				out.printf("refs\t%s\t%s\t%s\t%s\t%s\t%s%n", r.getFromAddress(),
					MraOut.mode(currentProgram, r.getFromAddress()), fname(r.getFromAddress()),
					r.getReferenceType(), to, insn(r.getFromAddress()));
				nRefs++;
			}
		}

		// Pass 2: literal words.
		int nLit = 0;
		Memory mem = currentProgram.getMemory();
		for (MemoryBlock b : mem.getBlocks()) {
			if (!(b.isInitialized() || b.isMapped())) {
				continue;
			}
			long start = b.getStart().getOffset();
			long end = b.getEnd().getOffset();
			byte[] buf = new byte[(int) (end - start + 1)];
			b.getBytes(b.getStart(), buf);
			for (int i = 0; i + 3 < buf.length; i += 4) {
				long v = (buf[i] & 0xffL) | ((buf[i + 1] & 0xffL) << 8) | ((buf[i + 2] & 0xffL) << 16) |
					((buf[i + 3] & 0xffL) << 24);
				boolean inRange = v >= lo && v <= hi;
				boolean isBase = base >= 0 && v == base;
				if (!inRange && !isBase) {
					continue;
				}
				Address lit = toAddr(start + i);
				if (getInstructionContaining(lit) != null) {
					continue; // bytes are an instruction, not a literal
				}
				String kind = inRange ? "literal" : "base_literal";
				ReferenceIterator it = currentProgram.getReferenceManager().getReferencesTo(lit);
				boolean any = false;
				while (it.hasNext()) {
					Reference r = it.next();
					any = true;
					out.printf("%s\t%s\t%s\t%s\t%s@%s\t0x%08X\t%s%n", kind, r.getFromAddress(),
						MraOut.mode(currentProgram, r.getFromAddress()), fname(r.getFromAddress()),
						r.getReferenceType(), lit, v, insn(r.getFromAddress()));
				}
				if (!any) {
					out.printf("%s\t-\t-\t-\tunreferenced@%s\t0x%08X\t-%n", kind, lit, v);
				}
				nLit++;
			}
		}

		// Pass 3: scalar operands.
		int nScalar = 0;
		InstructionIterator ii = currentProgram.getListing().getInstructions(true);
		while (ii.hasNext()) {
			Instruction ins = ii.next();
			for (int op = 0; op < ins.getNumOperands(); op++) {
				for (Object o : ins.getOpObjects(op)) {
					if (o instanceof Scalar) {
						long v = ((Scalar) o).getUnsignedValue();
						if (v >= lo && v <= hi && v > 0xFF) { // skip tiny immediates that alias low addresses
							out.printf("scalar\t%s\t%s\t%s\toperand%d\t0x%08X\t%s%n", ins.getAddress(),
								MraOut.mode(currentProgram, ins.getAddress()), fname(ins.getAddress()), op, v,
								insn(ins.getAddress()));
							nScalar++;
						}
					}
				}
			}
		}
		out.printf("# summary: refs=%d literal_words=%d scalar_operands=%d%n", nRefs, nLit, nScalar);
		MraOut.close(out);
	}

	private String fname(Address a) {
		Function f = getFunctionContaining(a);
		return f == null ? "-" : f.getName();
	}

	private String insn(Address a) {
		Instruction i = getInstructionAt(a);
		return i == null ? "-" : i.toString();
	}
}
