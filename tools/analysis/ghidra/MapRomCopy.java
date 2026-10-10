// Map a RAM range onto the ROM bytes it is copied from, as a byte-mapped block
// (no bytes are duplicated; the block reads through to ROM).
// Args: dst=ADDR src=ROMADDR len=BYTES name=BLOCKNAME [overlay=false|true]
//   overlay=false: replaces that part of the existing uninitialized block
//                  (e.g. IWRAM) so ROM code referencing dst resolves to it.
//   overlay=true:  adds an overlay space NAME::dst..; use for alternative
//                  contents of the same RAM range (code overlays).
// Find dst/src/len with ../py/ram_sources.py on a harness RAM dump.
//@category GBA

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;

public class MapRomCopy extends GhidraScript {
	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		long dst = MraOut.parseNum(req(args, "dst"));
		long src = MraOut.parseNum(req(args, "src"));
		long len = MraOut.parseNum(req(args, "len"));
		String name = req(args, "name");
		boolean overlay = Boolean.parseBoolean(MraOut.opt(args, "overlay", "false"));
		Memory mem = currentProgram.getMemory();
		Address d = toAddr(dst);
		Address s = toAddr(src);
		MemoryBlock srcBlk = mem.getBlock(s);
		if (srcBlk == null || !srcBlk.isInitialized() || !srcBlk.contains(s.add(len - 1))) {
			throw new IllegalArgumentException("source range not inside an initialized block");
		}
		if (mem.getBlock(name) != null) {
			println("block " + name + " exists, skipped");
			return;
		}
		if (overlay) {
			MemoryBlock b = mem.createByteMappedBlock(name, d, s, len, true);
			b.setPermissions(true, true, true);
			b.setComment(String.format("overlay: RAM 0x%08X+0x%X copied from ROM 0x%08X", dst, len, src));
			println("overlay " + b.getName() + " " + b.getStart() + ".." + b.getEnd());
			return;
		}
		MemoryBlock host = mem.getBlock(d);
		if (host == null || host.isInitialized() || !host.contains(d.add(len - 1))) {
			throw new IllegalArgumentException("dst range must lie inside one uninitialized block");
		}
		String hostName = host.getName();
		boolean r = host.isRead(), w = host.isWrite(), x = host.isExecute(), v = host.isVolatile();
		// Split off [d, d+len) from the host block, then replace it.
		if (host.getStart().compareTo(d) < 0) {
			mem.split(host, d);
			host = mem.getBlock(d);
		}
		Address end = d.add(len);
		if (host.contains(end)) {
			mem.split(host, end);
			MemoryBlock tail = mem.getBlock(end);
			tail.setName(hostName + "_HI");
			host = mem.getBlock(d);
		}
		mem.removeBlock(host, monitor);
		MemoryBlock b = mem.createByteMappedBlock(name, d, s, len, false);
		b.setPermissions(r, w, x);
		b.setVolatile(v);
		b.setComment(String.format("RAM 0x%08X+0x%X mapped to ROM 0x%08X (verified copy)", dst, len, src));
		println(String.format("mapped %s 0x%08X..0x%08X -> ROM 0x%08X", name, dst, dst + len - 1, src));
	}

	private String req(String[] args, String key) {
		String v = MraOut.opt(args, key, null);
		if (v == null) {
			throw new IllegalArgumentException("missing " + key + "=");
		}
		return v;
	}
}
