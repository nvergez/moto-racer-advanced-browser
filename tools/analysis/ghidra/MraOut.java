// Shared helpers for the GBA scripts in this directory (not a script itself).
// Output goes to the file named by an "out=FILE" script argument, or to
// System.out (mixed with Ghidra's log lines) when none is given.

import java.io.FileWriter;
import java.io.PrintWriter;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.Program;

public class MraOut {
	public static PrintWriter open(GhidraScript s, String[] args) throws Exception {
		for (String a : args) {
			if (a.startsWith("out=")) {
				return new PrintWriter(new FileWriter(a.substring(4)));
			}
		}
		return new PrintWriter(System.out, true);
	}

	public static void close(PrintWriter w) {
		w.flush();
		if (w.checkError()) {
			// ignore
		}
		w.close();
	}

	/** Script args without out=... entries. */
	public static List<String> positional(String[] args) {
		List<String> r = new ArrayList<>();
		for (String a : args) {
			if (!a.startsWith("out=")) {
				r.add(a);
			}
		}
		return r;
	}

	/** Value of key=... argument, or def. */
	public static String opt(String[] args, String key, String def) {
		for (String a : args) {
			if (a.startsWith(key + "=")) {
				return a.substring(key.length() + 1);
			}
		}
		return def;
	}

	public static long parseNum(String s) {
		s = s.trim().toLowerCase();
		if (s.startsWith("0x")) {
			return Long.parseUnsignedLong(s.substring(2), 16);
		}
		return Long.parseLong(s);
	}

	/** "Thumb" or "ARM" from the TMode context register at addr. */
	public static String mode(Program p, Address addr) {
		Register tmode = p.getProgramContext().getRegister("TMode");
		BigInteger v = p.getProgramContext().getValue(tmode, addr, false);
		return (v != null && v.intValue() == 1) ? "Thumb" : "ARM";
	}
}
