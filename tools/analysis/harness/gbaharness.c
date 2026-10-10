/*
 * gbaharness: headless, deterministic GBA run harness built on libmgba 0.10.5.
 *
 * Boots a ROM through a real BIOS image (no HLE BIOS, no BIOS skip), feeds a
 * scripted input sequence, and writes state dumps, traces and logs.
 * See ../README.md for usage. Contains no game data: the ROM and BIOS are
 * supplied at run time with --rom and --bios.
 *
 * Frame numbering: "frame N" is the frame whose completion moves mGBA's frame
 * counter from N-1 to N (completion = start of VBlank, VCOUNT=160). A dump
 * "at frame N" is the state right after frame N completed. Events (writes,
 * SWIs, executed instructions) are tagged with the frame being emulated, i.e.
 * counter+1, so VBlank-time work is attributed to the frame it prepares.
 */
#include <mgba/core/blip_buf.h>
#include <mgba/core/config.h>
#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/core/serialize.h>
#include <mgba/core/timing.h>
#include <mgba/gba/core.h>
#include <mgba/internal/arm/arm.h>
#include <mgba/internal/gba/bios.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/io.h>
#include <mgba/internal/gba/memory.h>
#include <mgba/internal/gba/savedata.h>
#include <mgba/internal/gba/timer.h>
#include <mgba/internal/gba/video.h>
#include <mgba-util/crc32.h>
#include <mgba-util/math.h>
#include <mgba-util/vfs.h>

#include <ctype.h>
#include <errno.h>
#include <getopt.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <zlib.h>

#define MAX_RANGES 32
#define W 240
#define H 160

typedef struct {
	uint32_t lo, hi; /* inclusive */
} Range;

static bool inRanges(const Range* r, int n, uint32_t v) {
	for (int i = 0; i < n; ++i) {
		if (v >= r[i].lo && v <= r[i].hi) {
			return true;
		}
	}
	return false;
}

/* ---------------------------------------------------------------- options */

static struct {
	const char* rom;
	const char* bios;
	const char* out;
	const char* script;
	const char* save;
	const char* loadState;
	const char* wav;
	const char* idle;
	long frames;
	Range dumpAt[MAX_RANGES];
	int nDumpAt;
	int dumpVcount;
	long shotEvery;
	Range shotAt[MAX_RANGES];
	int nShotAt;
	Range trace[MAX_RANGES];
	int nTrace;
	Range lines[MAX_RANGES];
	int nLines;
	Range watch[MAX_RANGES];
	int nWatch;
	Range watchRead[MAX_RANGES];
	int nWatchRead;
	Range watchFrames[MAX_RANGES];
	int nWatchFrames;
	long watchMax;
	Range pc[MAX_RANGES];
	int nPc;
	bool pcRegs;
	long pcMax;
	bool coverage;
	bool calls;
	Range stepFrames[MAX_RANGES];
	int nStepFrames;
	bool traceSwi;
	char* traceIo[64];
	int nTraceIo;
	Range traceMem[MAX_RANGES]; /* lo = address, hi = size in bytes (1/2/4) */
	int nTraceMem;
	int logLevel;
	bool quiet;
	bool openbusOn;      /* --openbus: replace the BIOS open-bus value game code reads */
	uint32_t openbus;
	const char* saveType; /* --save-type: force the cartridge backup type */
} opt = {
	.frames = -1,
	.dumpVcount = -1,
	.idle = "ignore",
	.watchMax = 2000000,
	.pcMax = 5000000,
	.logLevel = mLOG_FATAL | mLOG_ERROR | mLOG_WARN,
};

/* ---------------------------------------------------------------- globals */

static struct mCore* core;
static struct GBA* gba;
static struct ARMCore* cpu;
static color_t* videoBuf;
static FILE* fWrites;
static FILE* fReads;
static long nReadLines;
static FILE* fPc;
static FILE* fSwi;
static FILE* fTrace;
static FILE* fLines;
static FILE* fIndex;
static FILE* fMarks;
static FILE* fWav;
static long wavSamples;
static long nWriteLines;
static long nPcLines;
static long logCounts[8];
static uint64_t openbusHits;

/* Per-frame write statistics (bytes). */
enum { WS_VRAM0, WS_VRAM1, WS_VRAM2, WS_VRAM3, WS_VRAM4, WS_VRAM5, WS_PAL, WS_OAM, WS_EWRAM, WS_IWRAM, WS_IO, WS_COUNT };
static const char* wsNames[WS_COUNT] = { "vramw_00000", "vramw_04000", "vramw_08000", "vramw_0C000", "vramw_10000",
	                                     "vramw_14000", "palw", "oamw", "ewramw", "iwramw", "iow" };
static uint64_t wsCpu[WS_COUNT];
static uint64_t wsDma[WS_COUNT];

/* SWI attribution for BIOS-side writes. */
static int lastSwi = -1;
static uint32_t lastSwiPc;

/* Coverage. */
static uint32_t* covRom;   /* 0x08000000, 32 MiB / 2 */
static uint32_t* covEwram; /* 0x02000000 */
static uint32_t* covIwram; /* 0x03000000 */
static uint32_t* covBios;  /* 0x00000000 */
static uint8_t* covModeRom;
static uint8_t* covModeEwram;
static uint8_t* covModeIwram;
static uint8_t* covModeBios;
static uint64_t covOther;
static uint64_t covTotalByRegion[16];

static void die(const char* fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "gbaharness: ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
	exit(2);
}

static void mkdirs(const char* path) {
	char tmp[4096];
	snprintf(tmp, sizeof(tmp), "%s", path);
	for (char* p = tmp + 1; *p; ++p) {
		if (*p == '/') {
			*p = 0;
			mkdir(tmp, 0755);
			*p = '/';
		}
	}
	mkdir(tmp, 0755);
}

static FILE* openOut(const char* name, const char* mode) {
	char path[4096];
	snprintf(path, sizeof(path), "%s/%s", opt.out, name);
	FILE* f = fopen(path, mode);
	if (!f) {
		die("cannot open %s: %s", path, strerror(errno));
	}
	return f;
}

static uint32_t curFrame(void) {
	return gba->video.frameCounter;
}

/* Address of the instruction currently executing (valid inside a store hook or
 * SWI hook): mGBA keeps PC two instructions ahead during execution. */
static uint32_t execPc(void) {
	return cpu->gprs[ARM_PC] - (cpu->executionMode == MODE_THUMB ? 4 : 8);
}

/* Address of the next instruction to execute (valid between steps). */
static uint32_t nextPc(void) {
	return cpu->gprs[ARM_PC] - (cpu->executionMode == MODE_THUMB ? 2 : 4);
}

/* ---------------------------------------------------------------- logging */

static void logCallback(struct mLogger* logger, int category, enum mLogLevel level, const char* format, va_list args) {
	(void) logger;
	for (int i = 0; i < 8; ++i) {
		if (level & (1 << i)) {
			logCounts[i]++;
		}
	}
	if (!(level & opt.logLevel)) {
		return;
	}
	fprintf(stderr, "[f%u %s/%s] ", curFrame() + 1, mLogCategoryId(category), level == mLOG_FATAL ? "FATAL" : level == mLOG_ERROR ? "ERROR" : level == mLOG_WARN ? "WARN" : level == mLOG_INFO ? "INFO" : level == mLOG_DEBUG ? "DEBUG" : level == mLOG_STUB ? "STUB" : level == mLOG_GAME_ERROR ? "GAME_ERROR" : "?");
	vfprintf(stderr, format, args);
	fprintf(stderr, "\n");
}

static struct mLogger logger = { .log = logCallback };

/* ---------------------------------------------------------------- I/O table */

typedef struct {
	uint16_t off;
	uint8_t size;
	const char* name;
} IoReg;

static const IoReg IO_REGS[] = {
	{ 0x000, 2, "DISPCNT" }, { 0x002, 2, "GREENSWAP" }, { 0x004, 2, "DISPSTAT" }, { 0x006, 2, "VCOUNT" },
	{ 0x008, 2, "BG0CNT" }, { 0x00A, 2, "BG1CNT" }, { 0x00C, 2, "BG2CNT" }, { 0x00E, 2, "BG3CNT" },
	{ 0x010, 2, "BG0HOFS" }, { 0x012, 2, "BG0VOFS" }, { 0x014, 2, "BG1HOFS" }, { 0x016, 2, "BG1VOFS" },
	{ 0x018, 2, "BG2HOFS" }, { 0x01A, 2, "BG2VOFS" }, { 0x01C, 2, "BG3HOFS" }, { 0x01E, 2, "BG3VOFS" },
	{ 0x020, 2, "BG2PA" }, { 0x022, 2, "BG2PB" }, { 0x024, 2, "BG2PC" }, { 0x026, 2, "BG2PD" },
	{ 0x028, 4, "BG2X" }, { 0x02C, 4, "BG2Y" },
	{ 0x030, 2, "BG3PA" }, { 0x032, 2, "BG3PB" }, { 0x034, 2, "BG3PC" }, { 0x036, 2, "BG3PD" },
	{ 0x038, 4, "BG3X" }, { 0x03C, 4, "BG3Y" },
	{ 0x040, 2, "WIN0H" }, { 0x042, 2, "WIN1H" }, { 0x044, 2, "WIN0V" }, { 0x046, 2, "WIN1V" },
	{ 0x048, 2, "WININ" }, { 0x04A, 2, "WINOUT" }, { 0x04C, 2, "MOSAIC" },
	{ 0x050, 2, "BLDCNT" }, { 0x052, 2, "BLDALPHA" }, { 0x054, 2, "BLDY" },
	{ 0x060, 2, "SOUND1CNT_L" }, { 0x062, 2, "SOUND1CNT_H" }, { 0x064, 2, "SOUND1CNT_X" },
	{ 0x068, 2, "SOUND2CNT_L" }, { 0x06C, 2, "SOUND2CNT_H" },
	{ 0x070, 2, "SOUND3CNT_L" }, { 0x072, 2, "SOUND3CNT_H" }, { 0x074, 2, "SOUND3CNT_X" },
	{ 0x078, 2, "SOUND4CNT_L" }, { 0x07C, 2, "SOUND4CNT_H" },
	{ 0x080, 2, "SOUNDCNT_L" }, { 0x082, 2, "SOUNDCNT_H" }, { 0x084, 2, "SOUNDCNT_X" }, { 0x088, 2, "SOUNDBIAS" },
	{ 0x090, 2, "WAVE_RAM0_L" }, { 0x092, 2, "WAVE_RAM0_H" }, { 0x094, 2, "WAVE_RAM1_L" }, { 0x096, 2, "WAVE_RAM1_H" },
	{ 0x098, 2, "WAVE_RAM2_L" }, { 0x09A, 2, "WAVE_RAM2_H" }, { 0x09C, 2, "WAVE_RAM3_L" }, { 0x09E, 2, "WAVE_RAM3_H" },
	{ 0x0A0, 4, "FIFO_A" }, { 0x0A4, 4, "FIFO_B" },
	{ 0x0B0, 4, "DMA0SAD" }, { 0x0B4, 4, "DMA0DAD" }, { 0x0B8, 2, "DMA0CNT_L" }, { 0x0BA, 2, "DMA0CNT_H" },
	{ 0x0BC, 4, "DMA1SAD" }, { 0x0C0, 4, "DMA1DAD" }, { 0x0C4, 2, "DMA1CNT_L" }, { 0x0C6, 2, "DMA1CNT_H" },
	{ 0x0C8, 4, "DMA2SAD" }, { 0x0CC, 4, "DMA2DAD" }, { 0x0D0, 2, "DMA2CNT_L" }, { 0x0D2, 2, "DMA2CNT_H" },
	{ 0x0D4, 4, "DMA3SAD" }, { 0x0D8, 4, "DMA3DAD" }, { 0x0DC, 2, "DMA3CNT_L" }, { 0x0DE, 2, "DMA3CNT_H" },
	{ 0x100, 2, "TM0CNT_L" }, { 0x102, 2, "TM0CNT_H" }, { 0x104, 2, "TM1CNT_L" }, { 0x106, 2, "TM1CNT_H" },
	{ 0x108, 2, "TM2CNT_L" }, { 0x10A, 2, "TM2CNT_H" }, { 0x10C, 2, "TM3CNT_L" }, { 0x10E, 2, "TM3CNT_H" },
	{ 0x120, 4, "SIODATA32" }, { 0x128, 2, "SIOCNT" }, { 0x12A, 2, "SIODATA8" },
	{ 0x130, 2, "KEYINPUT" }, { 0x132, 2, "KEYCNT" }, { 0x134, 2, "RCNT" },
	{ 0x200, 2, "IE" }, { 0x202, 2, "IF" }, { 0x204, 2, "WAITCNT" }, { 0x208, 2, "IME" },
	{ 0x300, 2, "POSTFLG_HALTCNT" },
};
#define N_IO_REGS (sizeof(IO_REGS) / sizeof(IO_REGS[0]))

static uint32_t ioRaw(uint32_t off, int size) {
	/* Latched register contents as mGBA stores them (includes write-only regs). */
	uint32_t v = gba->memory.io[(off & 0x3FF) >> 1];
	if (size == 4) {
		v |= (uint32_t) gba->memory.io[((off & 0x3FF) >> 1) + 1] << 16;
	}
	return v;
}

static const IoReg* ioByName(const char* name) {
	for (size_t i = 0; i < N_IO_REGS; ++i) {
		if (!strcasecmp(IO_REGS[i].name, name)) {
			return &IO_REGS[i];
		}
	}
	return NULL;
}

/* Read-only computation of a timer's current counter (does not touch mGBA state). */
static uint32_t timerCurrent(int t) {
	struct GBATimer* tm = &gba->timers[t];
	uint16_t latched = gba->memory.io[(0x100 + t * 4) >> 1];
	if (!GBATimerFlagsIsEnable(tm->flags) || GBATimerFlagsIsCountUp(tm->flags)) {
		return latched;
	}
	int prescaleBits = GBATimerFlagsGetPrescaleBits(tm->flags);
	int32_t now = mTimingCurrentTime(&gba->timing) & ~((1 << prescaleBits) - 1);
	int64_t ticks = ((int64_t) now - tm->lastEvent) >> prescaleBits;
	int64_t v = latched + ticks;
	while (v >= 0x10000) {
		v -= 0x10000 - tm->reload;
	}
	return (uint32_t) v;
}

/* ---------------------------------------------------------------- memory peek */

/* Canonicalize mirrored addresses; returns false for regions we don't track. */
static bool canon(uint32_t a, uint32_t* out) {
	switch (a >> 24) {
	case 0x0:
		if (a < 0x4000) { *out = a; return true; }
		return false;
	case 0x2: *out = 0x02000000 | (a & 0x3FFFF); return true;
	case 0x3: *out = 0x03000000 | (a & 0x7FFF); return true;
	case 0x4:
		if ((a & 0xFFFFFF) < 0x400) { *out = a; return true; }
		return false;
	case 0x5: *out = 0x05000000 | (a & 0x3FF); return true;
	case 0x6: {
		uint32_t off = a & 0x1FFFF;
		if (off >= 0x18000) off -= 0x8000;
		*out = 0x06000000 | off;
		return true;
	}
	case 0x7: *out = 0x07000000 | (a & 0x3FF); return true;
	default:
		if ((a >> 24) >= 0x8 && (a >> 24) <= 0xD) { *out = a; return true; }
		if ((a >> 24) == 0xE || (a >> 24) == 0xF) { *out = 0x0E000000 | (a & 0xFFFF); return true; }
		return false;
	}
}

static uint8_t* backing(uint32_t c, size_t* avail) {
	switch (c >> 24) {
	case 0x0: *avail = 0x4000 - c; return (uint8_t*) gba->memory.bios + c;
	case 0x2: *avail = 0x40000 - (c & 0x3FFFF); return (uint8_t*) gba->memory.wram + (c & 0x3FFFF);
	case 0x3: *avail = 0x8000 - (c & 0x7FFF); return (uint8_t*) gba->memory.iwram + (c & 0x7FFF);
	case 0x4: *avail = 0x400 - (c & 0x3FF); return (uint8_t*) gba->memory.io + (c & 0x3FF);
	case 0x5: *avail = 0x400 - (c & 0x3FF); return (uint8_t*) gba->video.palette + (c & 0x3FF);
	case 0x6: *avail = 0x18000 - (c & 0x1FFFF); return (uint8_t*) gba->video.vram + (c & 0x1FFFF);
	case 0x7: *avail = 0x400 - (c & 0x3FF); return (uint8_t*) gba->video.oam.raw + (c & 0x3FF);
	default:
		if ((c >> 24) >= 0x8 && (c >> 24) <= 0xD) {
			uint32_t off = c & 0x01FFFFFF;
			if (off >= gba->memory.romSize) return NULL;
			*avail = gba->memory.romSize - off;
			return (uint8_t*) gba->memory.rom + off;
		}
		return NULL;
	}
}

/* Side-effect-free read of size 1/2/4 at a (mirrors resolved). */
static uint32_t peek(uint32_t a, int size) {
	uint32_t c;
	size_t avail = 0;
	if (!canon(a, &c)) return 0;
	uint8_t* p = backing(c, &avail);
	if (!p || avail < (size_t) size) return 0;
	uint32_t v = 0;
	for (int i = 0; i < size; ++i) v |= (uint32_t) p[i] << (8 * i);
	return v;
}

/* ---------------------------------------------------------------- PNG */

static void pngChunk(FILE* f, const char* type, const uint8_t* data, uint32_t len) {
	uint8_t hdr[8] = { len >> 24, len >> 16, len >> 8, len, type[0], type[1], type[2], type[3] };
	fwrite(hdr, 1, 8, f);
	if (len) fwrite(data, 1, len, f);
	uLong crc = crc32(0L, (const Bytef*) type, 4);
	if (len) crc = crc32(crc, data, len);
	uint8_t c[4] = { crc >> 24, crc >> 16, crc >> 8, crc };
	fwrite(c, 1, 4, f);
}

static void writePng(const char* path, const uint8_t* rgb, int w, int h) {
	FILE* f = fopen(path, "wb");
	if (!f) die("cannot write %s", path);
	static const uint8_t sig[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
	fwrite(sig, 1, 8, f);
	uint8_t ihdr[13] = { w >> 24, w >> 16, w >> 8, w, h >> 24, h >> 16, h >> 8, h, 8, 2, 0, 0, 0 };
	pngChunk(f, "IHDR", ihdr, 13);
	size_t rawLen = (size_t) h * (w * 3 + 1);
	uint8_t* raw = malloc(rawLen);
	for (int y = 0; y < h; ++y) {
		raw[y * (w * 3 + 1)] = 0;
		memcpy(&raw[y * (w * 3 + 1) + 1], &rgb[y * w * 3], w * 3);
	}
	uLongf zLen = compressBound(rawLen);
	uint8_t* z = malloc(zLen);
	compress2(z, &zLen, raw, rawLen, 6);
	pngChunk(f, "IDAT", z, (uint32_t) zLen);
	pngChunk(f, "IEND", NULL, 0);
	fclose(f);
	free(raw);
	free(z);
}

static void screenshot(const char* path) {
	static uint8_t rgb[W * H * 3];
	for (int i = 0; i < W * H; ++i) {
		uint32_t c = videoBuf[i]; /* XBGR8: R in the low byte */
		rgb[i * 3 + 0] = c & 0xFF;
		rgb[i * 3 + 1] = (c >> 8) & 0xFF;
		rgb[i * 3 + 2] = (c >> 16) & 0xFF;
	}
	writePng(path, rgb, W, H);
}

/* ---------------------------------------------------------------- dumps */

static void writeBin(const char* dir, const char* name, const void* data, size_t size) {
	char path[4096];
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	FILE* f = fopen(path, "wb");
	if (!f) die("cannot write %s", path);
	fwrite(data, 1, size, f);
	fclose(f);
}

static double fix8(int16_t v) {
	return v / 256.0;
}

static double fix28(uint32_t v) {
	int32_t s = (int32_t) (v << 4) >> 4; /* 28-bit signed, 8 fractional bits */
	return s / 256.0;
}

static const char* savedataName(enum SavedataType t) {
	switch (t) {
	case SAVEDATA_AUTODETECT: return "autodetect (no save access seen)";
	case SAVEDATA_FORCE_NONE: return "none";
	case SAVEDATA_SRAM: return "SRAM";
	case SAVEDATA_FLASH512: return "FLASH512";
	case SAVEDATA_FLASH1M: return "FLASH1M";
	case SAVEDATA_EEPROM: return "EEPROM";
	case SAVEDATA_EEPROM512: return "EEPROM512";
	case SAVEDATA_SRAM512: return "SRAM512";
	}
	return "?";
}

static uint32_t dumpFrameNo; /* frame number written into dump JSON files */

static void writeIoJson(const char* dir) {
	char path[4096];
	snprintf(path, sizeof(path), "%s/io.json", dir);
	FILE* f = fopen(path, "w");
	if (!f) die("cannot write %s", path);
	fprintf(f, "{\n  \"frame\": %u,\n  \"vcount_at_dump\": %d,\n  \"note\": \"raw = mGBA latched register value (write-only registers included); default snapshot point is the start of VBlank (VCOUNT=160) right after the frame was drawn\",\n", dumpFrameNo, gba->video.vcount);
	fprintf(f, "  \"regs\": {\n");
	for (size_t i = 0; i < N_IO_REGS; ++i) {
		const IoReg* r = &IO_REGS[i];
		fprintf(f, "    \"%s\": \"0x%0*X\"%s\n", r->name, r->size * 2, ioRaw(r->off, r->size), i + 1 < N_IO_REGS ? "," : "");
	}
	fprintf(f, "  },\n");
	uint16_t dispcnt = ioRaw(0, 2);
	fprintf(f, "  \"dispcnt\": {\"mode\": %d, \"frame_select_page\": %d, \"hblank_interval_free\": %d, \"obj_1d\": %d, \"forced_blank\": %d, \"bg0\": %d, \"bg1\": %d, \"bg2\": %d, \"bg3\": %d, \"obj\": %d, \"win0\": %d, \"win1\": %d, \"objwin\": %d},\n",
	        dispcnt & 7, (dispcnt >> 4) & 1, (dispcnt >> 5) & 1, (dispcnt >> 6) & 1, (dispcnt >> 7) & 1, (dispcnt >> 8) & 1,
	        (dispcnt >> 9) & 1, (dispcnt >> 10) & 1, (dispcnt >> 11) & 1, (dispcnt >> 12) & 1, (dispcnt >> 13) & 1,
	        (dispcnt >> 14) & 1, (dispcnt >> 15) & 1);
	fprintf(f, "  \"bg\": [\n");
	for (int b = 0; b < 4; ++b) {
		uint16_t c = ioRaw(0x8 + 2 * b, 2);
		fprintf(f, "    {\"cnt\": \"0x%04X\", \"priority\": %d, \"char_base\": \"0x%05X\", \"mosaic\": %d, \"colors256\": %d, \"screen_base\": \"0x%05X\", \"affine_wrap\": %d, \"size\": %d, \"hofs\": %d, \"vofs\": %d}%s\n",
		        c, c & 3, ((c >> 2) & 3) * 0x4000, (c >> 6) & 1, (c >> 7) & 1, ((c >> 8) & 31) * 0x800, (c >> 13) & 1, c >> 14,
		        ioRaw(0x10 + 4 * b, 2) & 0x1FF, ioRaw(0x12 + 4 * b, 2) & 0x1FF, b < 3 ? "," : "");
	}
	fprintf(f, "  ],\n  \"affine\": {\n");
	for (int b = 2; b < 4; ++b) {
		uint32_t base = b == 2 ? 0x20 : 0x30;
		fprintf(f, "    \"bg%d\": {\"pa\": %.6f, \"pb\": %.6f, \"pc\": %.6f, \"pd\": %.6f, \"x\": %.4f, \"y\": %.4f}%s\n", b,
		        fix8(ioRaw(base, 2)), fix8(ioRaw(base + 2, 2)), fix8(ioRaw(base + 4, 2)), fix8(ioRaw(base + 6, 2)),
		        fix28(ioRaw(base + 8, 4)), fix28(ioRaw(base + 12, 4)), b == 2 ? "," : "");
	}
	fprintf(f, "  },\n  \"dma\": [\n");
	static const char* timing[4] = { "immediate", "vblank", "hblank", "special" };
	static const char* actl[4] = { "inc", "dec", "fixed", "inc_reload" };
	for (int d = 0; d < 4; ++d) {
		uint32_t base = 0xB0 + 12 * d;
		uint16_t cnt = ioRaw(base + 10, 2);
		struct GBADMA* dm = &gba->memory.dma[d];
		fprintf(f, "    {\"sad\": \"0x%08X\", \"dad\": \"0x%08X\", \"count\": %u, \"cnt_h\": \"0x%04X\", \"dst\": \"%s\", \"src\": \"%s\", \"repeat\": %d, \"word32\": %d, \"timing\": \"%s\", \"irq\": %d, \"enable\": %d, \"internal_next_source\": \"0x%08X\", \"internal_next_dest\": \"0x%08X\", \"internal_next_count\": %u}%s\n",
		        ioRaw(base, 4), ioRaw(base + 4, 4), ioRaw(base + 8, 2), cnt, actl[(cnt >> 5) & 3], actl[(cnt >> 7) & 3],
		        (cnt >> 9) & 1, (cnt >> 10) & 1, timing[(cnt >> 12) & 3], (cnt >> 14) & 1, (cnt >> 15) & 1, dm->nextSource,
		        dm->nextDest, dm->nextCount, d < 3 ? "," : "");
	}
	fprintf(f, "  ],\n  \"timers\": [\n");
	static const int prescale[4] = { 1, 64, 256, 1024 };
	for (int t = 0; t < 4; ++t) {
		uint16_t cnt = ioRaw(0x102 + 4 * t, 2);
		fprintf(f, "    {\"reload\": \"0x%04X\", \"counter_now\": \"0x%04X\", \"cnt_h\": \"0x%04X\", \"prescaler\": %d, \"count_up\": %d, \"irq\": %d, \"enable\": %d}%s\n",
		        gba->timers[t].reload, timerCurrent(t), cnt, prescale[cnt & 3], (cnt >> 2) & 1, (cnt >> 6) & 1, (cnt >> 7) & 1, t < 3 ? "," : "");
	}
	uint16_t sh = ioRaw(0x82, 2);
	fprintf(f, "  ],\n  \"soundcnt_h\": {\"psg_volume\": %d, \"dma_a_full_volume\": %d, \"dma_b_full_volume\": %d, \"a_right\": %d, \"a_left\": %d, \"a_timer\": %d, \"b_right\": %d, \"b_left\": %d, \"b_timer\": %d},\n",
	        sh & 3, (sh >> 2) & 1, (sh >> 3) & 1, (sh >> 8) & 1, (sh >> 9) & 1, (sh >> 10) & 1, (sh >> 12) & 1, (sh >> 13) & 1, (sh >> 14) & 1);
	fprintf(f, "  \"interrupts\": {\"IE\": \"0x%04X\", \"IF\": \"0x%04X\", \"IME\": %d, \"bits\": \"0 vblank,1 hblank,2 vcount,3-6 timer0-3,7 serial,8-11 dma0-3,12 keypad,13 gamepak\"},\n",
	        ioRaw(0x200, 2), ioRaw(0x202, 2), ioRaw(0x208, 2) & 1);
	fprintf(f, "  \"emulator\": {\"vcount\": %d, \"cpu_halted\": %d, \"savedata_type\": \"%s\", \"bios_checksum\": \"0x%08X\", \"full_bios\": %d}\n}\n",
	        gba->video.vcount, cpu->halted, savedataName(gba->memory.savedata.type), gba->biosChecksum, gba->memory.fullBios);
	fclose(f);
}

static void writeCpuJson(const char* dir) {
	char path[4096];
	snprintf(path, sizeof(path), "%s/cpu.json", dir);
	FILE* f = fopen(path, "w");
	if (!f) die("cannot write %s", path);
	fprintf(f, "{\n  \"frame\": %u,\n  \"next_pc\": \"0x%08X\",\n  \"thumb\": %d,\n  \"cpsr\": \"0x%08X\",\n  \"halted\": %d,\n  \"gprs\": [", dumpFrameNo, nextPc(),
	        cpu->executionMode == MODE_THUMB, cpu->cpsr.packed, cpu->halted);
	for (int i = 0; i < 16; ++i) fprintf(f, "\"0x%08X\"%s", cpu->gprs[i], i < 15 ? ", " : "");
	fprintf(f, "]\n}\n");
	fclose(f);
}

static void dumpStateAt(const char* label, uint32_t frameNo, int vcount) {
	char dir[4096];
	char vsuffix[16] = "";
	if (vcount >= 0) snprintf(vsuffix, sizeof(vsuffix), "_v%03d", vcount);
	if (label && *label) {
		snprintf(dir, sizeof(dir), "%s/dumps/f%06u%s_%s", opt.out, frameNo, vsuffix, label);
	} else {
		snprintf(dir, sizeof(dir), "%s/dumps/f%06u%s", opt.out, frameNo, vsuffix);
	}
	mkdirs(dir);
	dumpFrameNo = frameNo;
	char path[4096];
	snprintf(path, sizeof(path), "%s/screen.png", dir);
	screenshot(path);
	writeBin(dir, "io.bin", gba->memory.io, 0x400);
	writeBin(dir, "palette.bin", gba->video.palette, 0x400);
	writeBin(dir, "vram.bin", gba->video.vram, 0x18000);
	writeBin(dir, "oam.bin", gba->video.oam.raw, 0x400);
	writeBin(dir, "iwram.bin", gba->memory.iwram, 0x8000);
	writeBin(dir, "ewram.bin", gba->memory.wram, 0x40000);
	writeIoJson(dir);
	writeCpuJson(dir);
	fprintf(fIndex, "%u\tdump\t%s\t%s\n", frameNo, label ? label : "", dir);
	fflush(fIndex);
	if (!opt.quiet) fprintf(stderr, "dump  f%u %s\n", frameNo, dir);
}

static void dumpState(const char* label) {
	dumpStateAt(label, curFrame(), -1);
}

static void shot(const char* label) {
	char dir[4096], path[4096];
	snprintf(dir, sizeof(dir), "%s/shots", opt.out);
	mkdirs(dir);
	if (label && *label) {
		snprintf(path, sizeof(path), "%s/f%06u_%s.png", dir, curFrame(), label);
	} else {
		snprintf(path, sizeof(path), "%s/f%06u.png", dir, curFrame());
	}
	screenshot(path);
	fprintf(fIndex, "%u\tshot\t%s\t%s\n", curFrame(), label ? label : "", path);
	fflush(fIndex);
	if (!opt.quiet) fprintf(stderr, "shot  f%u %s\n", curFrame(), path);
}

/* ---------------------------------------------------------------- write hooks */

static void (*origStore32)(struct ARMCore*, uint32_t, int32_t, int*);
static void (*origStore16)(struct ARMCore*, uint32_t, int16_t, int*);
static void (*origStore8)(struct ARMCore*, uint32_t, int8_t, int*);
static uint32_t (*origStoreMultiple)(struct ARMCore*, uint32_t, int, enum LSMDirection, int*);
static bool hooksInstalled;

static int wsIndex(uint32_t c) {
	switch (c >> 24) {
	case 0x2: return WS_EWRAM;
	case 0x3: return WS_IWRAM;
	case 0x4: return WS_IO;
	case 0x5: return WS_PAL;
	case 0x6: return WS_VRAM0 + ((c & 0x1FFFF) >> 14);
	case 0x7: return WS_OAM;
	}
	return -1;
}

/* Who is doing the current memory access: "cpu" (game code), "bios" (BIOS code,
 * ctx = most recent SWI and its call site) or "dmaN" (pc is then 0). */
static void accessSource(bool dma, uint32_t* pc, char* src, size_t srcLen, char* ctx, size_t ctxLen) {
	snprintf(ctx, ctxLen, "-");
	*pc = 0;
	if (dma) {
		snprintf(src, srcLen, "dma%d", gba->performingDMA >> 1);
		return;
	}
	*pc = execPc();
	if (*pc < 0x4000) {
		snprintf(src, srcLen, "bios");
		if (lastSwi >= 0) snprintf(ctx, ctxLen, "swi%02X@%08X", lastSwi, lastSwiPc);
	} else {
		snprintf(src, srcLen, "cpu");
	}
}

static void onStore(uint32_t addr, int size, uint32_t value) {
	uint32_t c;
	if (!canon(addr, &c)) {
		return;
	}
	bool dma = gba->performingDMA != 0;
	int wi = wsIndex(c);
	if (wi >= 0) {
		if (dma) wsDma[wi] += size; else wsCpu[wi] += size;
	}
	if (!fWrites || !opt.nWatch) return;
	uint32_t frame = curFrame() + 1;
	if (opt.nWatchFrames && !inRanges(opt.watchFrames, opt.nWatchFrames, frame)) return;
	/* Range check on any byte of the access. */
	bool hit = false;
	for (int i = 0; i < size && !hit; ++i) hit = inRanges(opt.watch, opt.nWatch, c + i);
	if (!hit) return;
	if (nWriteLines >= opt.watchMax) {
		if (nWriteLines == opt.watchMax) fprintf(fWrites, "# truncated at --watch-max\n");
		nWriteLines++;
		return;
	}
	nWriteLines++;
	uint32_t old = peek(c, size);
	char src[16], ctx[32];
	uint32_t pc = 0;
	accessSource(dma, &pc, src, sizeof(src), ctx, sizeof(ctx));
	fprintf(fWrites, "%u\t%d\t%s\t%08X\t%c\t%08X\t%s\t%08X\t%d\t%0*X\t%0*X\n", frame, gba->video.vcount, src, pc,
	        dma ? '-' : (cpu->executionMode == MODE_THUMB ? 'T' : 'A'), cpu->gprs[ARM_LR], ctx, c, size, size * 2, old,
	        size * 2, value & (size == 4 ? 0xFFFFFFFFu : size == 2 ? 0xFFFFu : 0xFFu));
}

static void hStore32(struct ARMCore* c, uint32_t address, int32_t value, int* cc) {
	onStore(address & ~3u, 4, (uint32_t) value);
	origStore32(c, address, value, cc);
}

static void hStore16(struct ARMCore* c, uint32_t address, int16_t value, int* cc) {
	onStore(address & ~1u, 2, (uint16_t) value);
	origStore16(c, address, value, cc);
}

static void hStore8(struct ARMCore* c, uint32_t address, int8_t value, int* cc) {
	onStore(address, 1, (uint8_t) value);
	origStore8(c, address, value, cc);
}

static uint32_t hStoreMultiple(struct ARMCore* c, uint32_t address, int mask, enum LSMDirection direction, int* cc) {
	/* Mirror GBAStoreMultiple's address computation (mGBA 0.10.5 src/gba/memory.c). */
	uint32_t a = address;
	int offset = 4;
	if (direction & LSM_D) {
		offset = -4;
		a -= (popcount32(mask) << 2) - 4;
	}
	if (direction & LSM_B) {
		a += offset;
	}
	a &= ~3u;
	if (!mask) {
		onStore(a, 4, c->gprs[ARM_PC] + (c->executionMode == MODE_ARM ? 4 : 2));
	} else {
		for (int i = 0; i < 16; ++i) {
			if (mask & (1 << i)) {
				uint32_t v = c->gprs[i];
				if (i == ARM_PC) v += c->executionMode == MODE_ARM ? 4 : 2;
				onStore(a, 4, v);
				a += 4;
			}
		}
	}
	return origStoreMultiple(c, address, mask, direction, cc);
}

static void installStoreHooks(void) {
	if (hooksInstalled) return;
	origStore32 = cpu->memory.store32;
	origStore16 = cpu->memory.store16;
	origStore8 = cpu->memory.store8;
	origStoreMultiple = cpu->memory.storeMultiple;
	cpu->memory.store32 = hStore32;
	cpu->memory.store16 = hStore16;
	cpu->memory.store8 = hStore8;
	cpu->memory.storeMultiple = hStoreMultiple;
	hooksInstalled = true;
}

static uint32_t (*origLoad32)(struct ARMCore*, uint32_t, int*);
static uint32_t (*origLoad16)(struct ARMCore*, uint32_t, int*);
static uint32_t (*origLoad8)(struct ARMCore*, uint32_t, int*);
static uint32_t (*origLoadMultiple)(struct ARMCore*, uint32_t, int, enum LSMDirection, int*);

static void onLoad(uint32_t addr, int size, uint32_t value) {
	uint32_t c;
	if (!canon(addr, &c)) return;
	uint32_t frame = curFrame() + 1;
	if (opt.nWatchFrames && !inRanges(opt.watchFrames, opt.nWatchFrames, frame)) return;
	bool hit = false;
	for (int i = 0; i < size && !hit; ++i) hit = inRanges(opt.watchRead, opt.nWatchRead, c + i);
	if (!hit) return;
	if (nReadLines >= opt.watchMax) {
		if (nReadLines == opt.watchMax) fprintf(fReads, "# truncated at --watch-max\n");
		nReadLines++;
		return;
	}
	nReadLines++;
	bool dma = gba->performingDMA != 0;
	char src[16], ctx[32];
	uint32_t pc;
	accessSource(dma, &pc, src, sizeof(src), ctx, sizeof(ctx));
	fprintf(fReads, "%u\t%d\t%s\t%08X\t%c\t%08X\t%s\t%08X\t%d\t%0*X\n", frame, gba->video.vcount, src, pc,
	        dma ? '-' : (cpu->executionMode == MODE_THUMB ? 'T' : 'A'), cpu->gprs[ARM_LR], ctx, c, size, size * 2,
	        value & (size == 4 ? 0xFFFFFFFFu : size == 2 ? 0xFFFFu : 0xFFu));
}

/* --openbus: a load from the BIOS region (0x0-0x3FFF) by code running outside
 * the BIOS returns mGBA's biosPrefetch latch (the last BIOS opcode fetched).
 * To see how the game reacts to another BIOS image, swap that latch for the
 * override around the original load, so mGBA's own size and rotation logic
 * still applies. DMA reads are left alone. */
static bool isGameBiosLoad(uint32_t address) {
	return opt.openbusOn && address < 0x4000 && gba->memory.activeRegion != REGION_BIOS && !gba->performingDMA;
}

#define OPENBUS_WRAP(call) \
	do { \
		if (isGameBiosLoad(address)) { \
			uint32_t saved = gba->memory.biosPrefetch; \
			gba->memory.biosPrefetch = opt.openbus; \
			v = call; \
			gba->memory.biosPrefetch = saved; \
			openbusHits++; \
		} else { \
			v = call; \
		} \
	} while (0)

static uint32_t hLoad32(struct ARMCore* c, uint32_t address, int* cc) {
	uint32_t v;
	OPENBUS_WRAP(origLoad32(c, address, cc));
	if (opt.nWatchRead) onLoad(address & ~3u, 4, v);
	return v;
}

static uint32_t hLoad16(struct ARMCore* c, uint32_t address, int* cc) {
	uint32_t v;
	OPENBUS_WRAP(origLoad16(c, address, cc));
	if (opt.nWatchRead) onLoad(address & ~1u, 2, v);
	return v;
}

static uint32_t hLoad8(struct ARMCore* c, uint32_t address, int* cc) {
	uint32_t v;
	OPENBUS_WRAP(origLoad8(c, address, cc));
	if (opt.nWatchRead) onLoad(address, 1, v);
	return v;
}

static uint32_t hLoadMultiple(struct ARMCore* c, uint32_t address, int mask, enum LSMDirection direction, int* cc) {
	if (opt.nWatchRead) {
		uint32_t a = address;
		int offset = 4;
		if (direction & LSM_D) {
			offset = -4;
			a -= (popcount32(mask) << 2) - 4;
		}
		if (direction & LSM_B) a += offset;
		a &= ~3u;
		int n = mask ? popcount32(mask) : 1;
		for (int i = 0; i < n; ++i) onLoad(a + 4 * i, 4, peek(a + 4 * i, 4)); /* value = memory content */
	}
	uint32_t v;
	OPENBUS_WRAP(origLoadMultiple(c, address, mask, direction, cc));
	return v;
}

static void installLoadHooks(void) {
	origLoad32 = cpu->memory.load32;
	origLoad16 = cpu->memory.load16;
	origLoad8 = cpu->memory.load8;
	origLoadMultiple = cpu->memory.loadMultiple;
	cpu->memory.load32 = hLoad32;
	cpu->memory.load16 = hLoad16;
	cpu->memory.load8 = hLoad8;
	cpu->memory.loadMultiple = hLoadMultiple;
}

/* ---------------------------------------------------------------- SWI hooks */

static const char* SWI_NAMES[0x2B] = {
	"SoftReset", "RegisterRamReset", "Halt", "Stop", "IntrWait", "VBlankIntrWait", "Div", "DivArm", "Sqrt",
	"ArcTan", "ArcTan2", "CpuSet", "CpuFastSet", "GetBiosChecksum", "BgAffineSet", "ObjAffineSet", "BitUnPack",
	"LZ77UnCompWram", "LZ77UnCompVram", "HuffUnComp", "RLUnCompWram", "RLUnCompVram", "Diff8bitUnFilterWram",
	"Diff8bitUnFilterVram", "Diff16bitUnFilter", "SoundBias", "SoundDriverInit", "SoundDriverMode",
	"SoundDriverMain", "SoundDriverVSync", "SoundChannelClear", "MidiKey2Freq", "SoundWhatever0",
	"SoundWhatever1", "SoundWhatever2", "SoundWhatever3", "SoundWhatever4", "MultiBoot", "HardReset",
	"CustomHalt", "SoundDriverVSyncOff", "SoundDriverVSyncOn", "SoundGetJumpList",
};
static uint64_t swiCounts[256];
static void (*origSwi16)(struct ARMCore*, int);
static void (*origSwi32)(struct ARMCore*, int);

static void logSwi(int num, uint32_t pc) {
	lastSwi = num;
	lastSwiPc = pc;
	swiCounts[num & 0xFF]++;
	if (fSwi) {
		fprintf(fSwi, "%u\t%d\t%08X\t%c\t%02X\t%s\t%08X\t%08X\t%08X\t%08X\t%08X\n", curFrame() + 1, gba->video.vcount, pc,
		        cpu->executionMode == MODE_THUMB ? 'T' : 'A', num & 0xFF, (num & 0xFF) < 0x2B ? SWI_NAMES[num & 0xFF] : "?",
		        cpu->gprs[0], cpu->gprs[1], cpu->gprs[2], cpu->gprs[3], cpu->gprs[ARM_LR]);
	}
}

static void hSwi16(struct ARMCore* c, int immediate) {
	logSwi(immediate & 0xFF, execPc());
	origSwi16(c, immediate);
}

static void hSwi32(struct ARMCore* c, int immediate) {
	logSwi((immediate >> 16) & 0xFF, execPc());
	origSwi32(c, immediate);
}

/* ---------------------------------------------------------------- stepping */

static bool stepActive(uint32_t frame) {
	bool inStep = !opt.nStepFrames || inRanges(opt.stepFrames, opt.nStepFrames, frame);
	bool cov = (opt.coverage || opt.calls) && inStep;
	bool pc = opt.nPc && inStep;
	bool lines = opt.nLines && inRanges(opt.lines, opt.nLines, frame);
	bool vdump = opt.dumpVcount >= 0 && opt.nDumpAt && inRanges(opt.dumpAt, opt.nDumpAt, frame);
	return cov || pc || lines || vdump;
}

/* Dynamic call-target detection (stepping mode). Open-addressing hash tables. */
typedef struct {
	uint32_t key; /* addr | thumb bit (bit 0) ; 0 = empty */
	uint32_t count;
	uint32_t firstFrom;
	uint32_t firstFrame;
	uint8_t kind; /* 1 = call (LR = return address), 2 = bx to a non-return address */
} CallEntry;
#define CALL_TABLE_BITS 18
static CallEntry* callTable;
static uint32_t* retSet; /* return addresses seen at calls (addr|1 so 0 stays "empty") */
static uint32_t nCalls, nRets;

static uint32_t hashU32(uint32_t x) {
	x ^= x >> 16;
	x *= 0x7FEB352D;
	x ^= x >> 15;
	x *= 0x846CA68B;
	x ^= x >> 16;
	return x;
}

static void retAdd(uint32_t a) {
	uint32_t key = (a & ~1u) | 1u;
	uint32_t mask = (1u << CALL_TABLE_BITS) - 1;
	for (uint32_t i = hashU32(key) & mask;; i = (i + 1) & mask) {
		if (retSet[i] == key) return;
		if (!retSet[i]) {
			if (nRets < mask / 2) { retSet[i] = key; nRets++; }
			return;
		}
	}
}

static bool retHas(uint32_t a) {
	uint32_t key = (a & ~1u) | 1u;
	uint32_t mask = (1u << CALL_TABLE_BITS) - 1;
	for (uint32_t i = hashU32(key) & mask;; i = (i + 1) & mask) {
		if (retSet[i] == key) return true;
		if (!retSet[i]) return false;
	}
}

static void callAdd(uint32_t target, bool thumb, uint32_t from, uint8_t kind, uint32_t frame) {
	uint32_t key = (target & ~1u) | (thumb ? 1u : 0u);
	if (!key) key = 0x80000000u; /* never a real target */
	uint32_t mask = (1u << CALL_TABLE_BITS) - 1;
	for (uint32_t i = hashU32(key) & mask;; i = (i + 1) & mask) {
		CallEntry* e = &callTable[i];
		if (e->key == key) {
			e->count++;
			if (kind == 1) e->kind = 1;
			return;
		}
		if (!e->key) {
			if (nCalls >= mask / 2) return;
			e->key = key;
			e->count = 1;
			e->firstFrom = from;
			e->firstFrame = frame;
			e->kind = kind;
			nCalls++;
			return;
		}
	}
}

static int cmpCall(const void* a, const void* b) {
	const CallEntry* x = a;
	const CallEntry* y = b;
	return x->key < y->key ? -1 : x->key > y->key;
}

static void covRecord(uint32_t a, bool thumb) {
	uint32_t* arr = NULL;
	uint8_t* modes = NULL;
	uint32_t idx = 0;
	switch (a >> 24) {
	case 0x0:
		if (a < 0x4000) { arr = covBios; modes = covModeBios; idx = a >> 1; }
		break;
	case 0x2: arr = covEwram; modes = covModeEwram; idx = (a & 0x3FFFF) >> 1; break;
	case 0x3: arr = covIwram; modes = covModeIwram; idx = (a & 0x7FFF) >> 1; break;
	case 0x8: case 0x9:
		if ((a & 0x1FFFFFF) < gba->memory.romSize) { arr = covRom; modes = covModeRom; idx = (a & 0x1FFFFFF) >> 1; }
		break;
	}
	covTotalByRegion[(a >> 24) & 0xF]++;
	if (!arr) { covOther++; return; }
	arr[idx]++;
	modes[idx] |= thumb ? 2 : 1;
}

static void writeLineRow(uint32_t frame) {
	fprintf(fLines, "%u\t%d", frame, gba->video.vcount);
	static const char* cols[] = { "DISPCNT", "BG0CNT", "BG1CNT", "BG2CNT", "BG3CNT", "BG0HOFS", "BG0VOFS", "BG1HOFS",
	                              "BG1VOFS", "BG2HOFS", "BG2VOFS", "BG3HOFS", "BG3VOFS", "BG2PA", "BG2PB", "BG2PC", "BG2PD",
	                              "BG2X", "BG2Y", "BG3PA", "BG3PB", "BG3PC", "BG3PD", "BG3X", "BG3Y", "WIN0H", "WIN0V",
	                              "WIN1H", "WIN1V", "WININ", "WINOUT", "BLDCNT", "BLDALPHA", "BLDY", "MOSAIC" };
	for (size_t i = 0; i < sizeof(cols) / sizeof(cols[0]); ++i) {
		const IoReg* r = ioByName(cols[i]);
		fprintf(fLines, "\t%0*X", r->size * 2, ioRaw(r->off, r->size));
	}
	fprintf(fLines, "\n");
}

static void runFrameStepping(void) {
	uint32_t start = gba->video.frameCounter;
	uint32_t frame = start + 1;
	bool cov = opt.coverage && (!opt.nStepFrames || inRanges(opt.stepFrames, opt.nStepFrames, frame));
	bool pcOn = opt.nPc && (!opt.nStepFrames || inRanges(opt.stepFrames, opt.nStepFrames, frame));
	bool lines = fLines && inRanges(opt.lines, opt.nLines, frame);
	bool calls = opt.calls && (!opt.nStepFrames || inRanges(opt.stepFrames, opt.nStepFrames, frame));
	bool vdump = opt.dumpVcount >= 0 && opt.nDumpAt && inRanges(opt.dumpAt, opt.nDumpAt, frame);
	int lastV = -1;
	for (;;) {
		while (cpu->cycles >= cpu->nextEvent) {
			cpu->irqh.processEvents(cpu);
			if (gba->video.frameCounter != start) {
				return;
			}
		}
		if (gba->video.vcount != lastV) {
			lastV = gba->video.vcount;
			if (lines) writeLineRow(frame);
			if (vdump && lastV == opt.dumpVcount) {
				dumpStateAt("", frame, lastV);
				vdump = false;
			}
		}
		uint32_t pc = nextPc();
		bool thumb = cpu->executionMode == MODE_THUMB;
		if (cov) covRecord(pc, thumb);
		if (pcOn && inRanges(opt.pc, opt.nPc, pc) && nPcLines < opt.pcMax) {
			nPcLines++;
			fprintf(fPc, "%u\t%d\t%08X\t%c\t%0*X", frame, gba->video.vcount, pc, thumb ? 'T' : 'A', thumb ? 4 : 8,
			        thumb ? (cpu->prefetch[0] & 0xFFFF) : cpu->prefetch[0]);
			if (opt.pcRegs) {
				for (int i = 0; i < 16; ++i) fprintf(fPc, "\t%08X", cpu->gprs[i]);
				fprintf(fPc, "\t%08X", cpu->cpsr.packed);
			}
			fprintf(fPc, "\n");
		}
		uint32_t opcode = cpu->prefetch[0];
		ARMRun(cpu);
		if (calls) {
			uint32_t size = thumb ? 2 : 4;
			bool nowThumb = cpu->executionMode == MODE_THUMB;
			uint32_t npc = cpu->gprs[ARM_PC] - (nowThumb ? 2 : 4);
			if (npc != pc + size) {
				uint32_t lr = cpu->gprs[ARM_LR] & ~1u;
				if (lr == pc + size) {
					callAdd(npc, nowThumb, pc, 1, frame);
					retAdd(lr);
				} else {
					bool isBx = thumb ? ((opcode & 0xFF87) == 0x4700) : ((opcode & 0x0FFFFFF0) == 0x012FFF10);
					int rm = thumb ? ((opcode >> 3) & 0xF) : (opcode & 0xF);
					if (isBx && rm != ARM_LR && !retHas(npc)) callAdd(npc, nowThumb, pc, 2, frame);
				}
			}
		}
		if (gba->video.frameCounter != start) {
			return;
		}
	}
}

/* ---------------------------------------------------------------- per-frame */

static void drainAudio(void) {
	static int16_t buf[2048 * 2];
	blip_t* l = core->getAudioChannel(core, 0);
	blip_t* r = core->getAudioChannel(core, 1);
	int avail = blip_samples_avail(l);
	while (avail > 0) {
		int n = avail > 2048 ? 2048 : avail;
		blip_read_samples(l, buf, n, 1);
		blip_read_samples(r, buf + 1, n, 1);
		if (fWav) {
			fwrite(buf, sizeof(int16_t), n * 2, fWav);
			wavSamples += n;
		}
		avail -= n;
	}
}

static void writeWavHeader(FILE* f, long samples, int rate) {
	uint32_t dataLen = (uint32_t) samples * 4;
	uint8_t h[44];
	memcpy(h, "RIFF", 4);
	uint32_t v = 36 + dataLen;
	memcpy(h + 4, &v, 4);
	memcpy(h + 8, "WAVEfmt ", 8);
	v = 16; memcpy(h + 16, &v, 4);
	uint16_t s = 1; memcpy(h + 20, &s, 2);
	s = 2; memcpy(h + 22, &s, 2);
	v = rate; memcpy(h + 24, &v, 4);
	v = rate * 4; memcpy(h + 28, &v, 4);
	s = 4; memcpy(h + 32, &s, 2);
	s = 16; memcpy(h + 34, &s, 2);
	memcpy(h + 36, "data", 4);
	memcpy(h + 40, &dataLen, 4);
	fseek(f, 0, SEEK_SET);
	fwrite(h, 1, 44, f);
}

static uint32_t crcRange(const void* p, size_t n) {
	return doCrc32(p, n);
}

static void traceHeader(void) {
	fprintf(fTrace, "frame\tkeys\tDISPCNT\tmode\tpage\tDISPSTAT\tBG0CNT\tBG1CNT\tBG2CNT\tBG3CNT\tBG2PA\tBG2PB\tBG2PC\tBG2PD\tBG2X\tBG2Y\tBG3PA\tBG3PB\tBG3PC\tBG3PD\tBG3X\tBG3Y\tBLDCNT\tDMA0CNT_H\tDMA1CNT_H\tDMA2CNT_H\tDMA3CNT_H\tIE\tcrc_vram_00000_09FFF\tcrc_vram_0A000_13FFF\tcrc_vram_10000_17FFF\tcrc_pal\tcrc_oam");
	for (int i = 0; i < WS_COUNT; ++i) fprintf(fTrace, "\t%s", wsNames[i]);
	fprintf(fTrace, "\tvramw_dma");
	for (int i = 0; i < opt.nTraceIo; ++i) fprintf(fTrace, "\t%s", opt.traceIo[i]);
	for (int i = 0; i < opt.nTraceMem; ++i) fprintf(fTrace, "\tmem_%08X", opt.traceMem[i].lo);
	fprintf(fTrace, "\n");
}

static void traceRow(uint32_t keys) {
	uint16_t d = ioRaw(0, 2);
	fprintf(fTrace, "%u\t%03X\t%04X\t%d\t%d\t%04X", curFrame(), keys, d, d & 7, (d >> 4) & 1, ioRaw(4, 2));
	static const uint16_t offs2[] = { 0x08, 0x0A, 0x0C, 0x0E, 0x20, 0x22, 0x24, 0x26 };
	for (size_t i = 0; i < 8; ++i) fprintf(fTrace, "\t%04X", ioRaw(offs2[i], 2));
	fprintf(fTrace, "\t%08X\t%08X", ioRaw(0x28, 4), ioRaw(0x2C, 4));
	static const uint16_t offs3[] = { 0x30, 0x32, 0x34, 0x36 };
	for (size_t i = 0; i < 4; ++i) fprintf(fTrace, "\t%04X", ioRaw(offs3[i], 2));
	fprintf(fTrace, "\t%08X\t%08X\t%04X", ioRaw(0x38, 4), ioRaw(0x3C, 4), ioRaw(0x50, 2));
	for (int i = 0; i < 4; ++i) fprintf(fTrace, "\t%04X", ioRaw(0xBA + 12 * i, 2));
	fprintf(fTrace, "\t%04X", ioRaw(0x200, 2));
	uint8_t* vram = (uint8_t*) gba->video.vram;
	fprintf(fTrace, "\t%08X\t%08X\t%08X\t%08X\t%08X", crcRange(vram, 0xA000), crcRange(vram + 0xA000, 0xA000),
	        crcRange(vram + 0x10000, 0x8000), crcRange(gba->video.palette, 0x400), crcRange(gba->video.oam.raw, 0x400));
	uint64_t vdma = 0;
	for (int i = 0; i < WS_COUNT; ++i) {
		fprintf(fTrace, "\t%llu", (unsigned long long) (wsCpu[i] + wsDma[i]));
		if (i <= WS_VRAM5) vdma += wsDma[i];
	}
	fprintf(fTrace, "\t%llu", (unsigned long long) vdma);
	for (int i = 0; i < opt.nTraceIo; ++i) {
		const IoReg* r = ioByName(opt.traceIo[i]);
		fprintf(fTrace, "\t%0*X", r->size * 2, ioRaw(r->off, r->size));
	}
	for (int i = 0; i < opt.nTraceMem; ++i) {
		int sz = (int) opt.traceMem[i].hi;
		fprintf(fTrace, "\t%0*X", sz * 2, peek(opt.traceMem[i].lo, sz));
	}
	fprintf(fTrace, "\n");
}

/* ---------------------------------------------------------------- input script */

static uint32_t heldKeys;
static uint32_t lastKeys;

static uint32_t parseKeys(const char* s, int lineNo) {
	uint32_t k = 0;
	char buf[256];
	snprintf(buf, sizeof(buf), "%s", s);
	for (char* tok = strtok(buf, "+,|"); tok; tok = strtok(NULL, "+,|")) {
		static const char* names[] = { "A", "B", "SELECT", "START", "RIGHT", "LEFT", "UP", "DOWN", "R", "L" };
		bool found = false;
		for (int i = 0; i < 10; ++i) {
			if (!strcasecmp(tok, names[i])) { k |= 1u << i; found = true; }
		}
		if (!strcasecmp(tok, "NONE")) found = true;
		if (!found) die("script line %d: unknown key '%s'", lineNo, tok);
	}
	return k;
}

static bool stopRequested;

static bool frameLimitReached(void) {
	return opt.frames >= 0 && (long) curFrame() >= opt.frames;
}

static void afterFrame(uint32_t keys) {
	drainAudio();
	uint32_t f = curFrame();
	if (fTrace && inRanges(opt.trace, opt.nTrace, f)) traceRow(keys);
	memset(wsCpu, 0, sizeof(wsCpu));
	memset(wsDma, 0, sizeof(wsDma));
	if (opt.nDumpAt && opt.dumpVcount < 0 && inRanges(opt.dumpAt, opt.nDumpAt, f)) dumpState("");
	if ((opt.shotEvery > 0 && f % opt.shotEvery == 0) || (opt.nShotAt && inRanges(opt.shotAt, opt.nShotAt, f))) shot("");
}

static void runFrames(long n, uint32_t keys) {
	for (long i = 0; i < n && !stopRequested; ++i) {
		if (frameLimitReached()) { stopRequested = true; break; }
		core->setKeys(core, keys);
		lastKeys = keys;
		if (stepActive(curFrame() + 1)) {
			runFrameStepping();
		} else {
			core->runFrame(core);
		}
		afterFrame(keys);
	}
}

static void saveState(const char* path) {
	struct VFile* vf = VFileOpen(path, O_CREAT | O_TRUNC | O_RDWR);
	if (!vf) die("cannot write savestate %s", path);
	if (!mCoreSaveStateNamed(core, vf, SAVESTATE_SAVEDATA | SAVESTATE_RTC)) die("savestate failed");
	vf->close(vf);
	fprintf(fIndex, "%u\tsavestate\t\t%s\n", curFrame(), path);
	if (!opt.quiet) fprintf(stderr, "state f%u %s\n", curFrame(), path);
}

static void runScript(const char* path) {
	FILE* f = fopen(path, "r");
	if (!f) die("cannot open script %s", path);
	char line[1024];
	int lineNo = 0;
	int tapOn = 6, tapOff = 6;
	while (!stopRequested && fgets(line, sizeof(line), f)) {
		lineNo++;
		char* hash = strchr(line, '#');
		if (hash) *hash = 0;
		char* argv[8];
		int argc = 0;
		for (char* tok = strtok(line, " \t\r\n"); tok && argc < 8; tok = strtok(NULL, " \t\r\n")) argv[argc++] = tok;
		if (!argc) continue;
		const char* cmd = argv[0];
		if (!strcmp(cmd, "wait")) {
			if (argc < 2) die("line %d: wait N", lineNo);
			runFrames(atol(argv[1]), heldKeys);
		} else if (!strcmp(cmd, "until")) {
			if (argc < 2) die("line %d: until FRAME", lineNo);
			long target = atol(argv[1]);
			if ((long) curFrame() > target) fprintf(stderr, "warning: line %d: already past frame %ld (at %u)\n", lineNo, target, curFrame());
			while ((long) curFrame() < target && !stopRequested) runFrames(1, heldKeys);
		} else if (!strcmp(cmd, "press")) {
			if (argc < 2) die("line %d: press KEYS [N]", lineNo);
			runFrames(argc > 2 ? atol(argv[2]) : tapOn, heldKeys | parseKeys(argv[1], lineNo));
		} else if (!strcmp(cmd, "tap")) {
			if (argc < 2) die("line %d: tap KEYS [COUNT]", lineNo);
			int count = argc > 2 ? atoi(argv[2]) : 1;
			uint32_t k = parseKeys(argv[1], lineNo);
			for (int i = 0; i < count && !stopRequested; ++i) {
				runFrames(tapOn, heldKeys | k);
				runFrames(tapOff, heldKeys);
			}
		} else if (!strcmp(cmd, "taptiming")) {
			if (argc < 3) die("line %d: taptiming ON OFF", lineNo);
			tapOn = atoi(argv[1]);
			tapOff = atoi(argv[2]);
		} else if (!strcmp(cmd, "hold")) {
			if (argc < 2) die("line %d: hold KEYS", lineNo);
			heldKeys |= parseKeys(argv[1], lineNo);
		} else if (!strcmp(cmd, "release")) {
			heldKeys = argc > 1 ? heldKeys & ~parseKeys(argv[1], lineNo) : 0;
		} else if (!strcmp(cmd, "dump")) {
			dumpState(argc > 1 ? argv[1] : "");
		} else if (!strcmp(cmd, "shot")) {
			shot(argc > 1 ? argv[1] : "");
		} else if (!strcmp(cmd, "mark")) {
			fprintf(fMarks, "%u\t%s\n", curFrame(), argc > 1 ? argv[1] : "");
			fflush(fMarks);
			if (!opt.quiet) fprintf(stderr, "mark  f%u %s\n", curFrame(), argc > 1 ? argv[1] : "");
		} else if (!strcmp(cmd, "savestate")) {
			if (argc < 2) die("line %d: savestate PATH", lineNo);
			char p[4096];
			if (argv[1][0] == '/') snprintf(p, sizeof(p), "%s", argv[1]);
			else snprintf(p, sizeof(p), "%s/%s", opt.out, argv[1]);
			saveState(p);
		} else if (!strcmp(cmd, "end")) {
			stopRequested = true;
		} else {
			die("script line %d: unknown command '%s'", lineNo, cmd);
		}
	}
	fclose(f);
}

/* ---------------------------------------------------------------- args */

static uint32_t parseNum(const char* s) {
	return (uint32_t) strtoul(s, NULL, 0);
}

/* "A-B", "A+LEN" or "A" (single value), comma separated. */
static int parseRanges(const char* s, Range* out, int max) {
	int n = 0;
	char buf[4096];
	snprintf(buf, sizeof(buf), "%s", s);
	for (char* tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
		if (n >= max) die("too many ranges (at most %d per option): %s", MAX_RANGES, s);
		char* dash = strchr(tok + 1, '-');
		char* plus = strchr(tok + 1, '+');
		if (dash) {
			*dash = 0;
			out[n].lo = parseNum(tok);
			out[n].hi = parseNum(dash + 1);
		} else if (plus) {
			*plus = 0;
			out[n].lo = parseNum(tok);
			out[n].hi = out[n].lo + parseNum(plus + 1) - 1;
		} else {
			out[n].lo = out[n].hi = parseNum(tok);
		}
		n++;
	}
	return n;
}

static void usage(void) {
	fprintf(stderr,
	        "usage: gbaharness --rom ROM --bios BIOS --out DIR [options]\n"
	        "  --script FILE        input script (wait/press/tap/hold/release/until/dump/shot/mark/savestate/end)\n"
	        "  --frames N           stop after frame N (also keeps running after the script ends until N)\n"
	        "  --dump-at LIST       full dumps at frames, e.g. 100,200-210\n"
	        "  --dump-vcount L      take --dump-at dumps when VCOUNT first equals L during the frame\n"
	        "                       (L<160: mid-drawing of that frame; 160-227: its leading VBlank)\n"
	        "  --shot-every N       screenshot every N frames into DIR/shots\n"
	        "  --shot-at LIST       screenshots at frames, e.g. 3810-3840,4000\n"
	        "  --trace LIST         per-frame register/VRAM-hash trace rows for frames -> trace.tsv\n"
	        "  --trace-io NAMES     extra I/O registers for trace.tsv, e.g. BG2HOFS,SOUNDCNT_H\n"
	        "  --trace-mem LIST     extra memory words for trace.tsv: ADDR:SIZE,... (size 1/2/4)\n"
	        "  --trace-lines LIST   per-scanline register rows for frames -> lines.tsv (stepping)\n"
	        "  --watch-write LIST   log writes to address ranges (A-B or A+LEN) -> writes.tsv\n"
	        "  --watch-read LIST    log reads from address ranges -> reads.tsv (CPU loads and DMA reads)\n"
	        "  --watch-frames LIST  restrict write/read logging to frames\n"
	        "  --watch-max N        cap on writes.tsv lines (default 2000000)\n"
	        "  --trace-pc LIST      log executed instructions in PC ranges -> pctrace.tsv (stepping)\n"
	        "  --trace-pc-regs      include r0-r15,cpsr in pctrace.tsv\n"
	        "  --pc-max N           cap on pctrace.tsv lines (default 5000000)\n"
	        "  --coverage           count executed instructions per address -> coverage.tsv (stepping)\n"
	        "  --calls              detect call targets (BL, mov lr,pc+bx, bx via veneers) -> calls.tsv (stepping)\n"
	        "  --step-frames LIST   limit --coverage/--calls/--trace-pc to frames\n"
	        "  --trace-swi          log SWI calls -> swi.tsv\n"
	        "  --wav FILE           write audio (stereo s16, 32768 Hz)\n"
	        "  --save FILE          cartridge save file to load/persist (default: fresh in-memory save)\n"
	        "  --load-state FILE    start from an mGBA savestate written by this harness\n"
	        "  --idle MODE          idle loop optimization: ignore (default), remove, detect\n"
	        "  --save-type TYPE     force the backup type: sram|flash512|flash1m|eeprom|eeprom512|none\n"
	        "                       (default: mGBA autodetect on first access)\n"
	        "  --openbus VALUE      game-code loads from the BIOS region (0x0-0x3FFF) see VALUE instead of\n"
	        "                       the open-bus latch the real BIOS left (A/B tests for other BIOS images)\n"
	        "  --log-level MASK     mGBA log mask (default 0x7 = fatal|error|warn; 0x7F all incl. debug)\n"
	        "  --quiet\n");
	exit(2);
}

int main(int argc, char** argv) {
	static struct option longopts[] = {
		{ "rom", required_argument, 0, 'r' }, { "bios", required_argument, 0, 'b' },
		{ "out", required_argument, 0, 'o' }, { "script", required_argument, 0, 's' },
		{ "frames", required_argument, 0, 'n' }, { "dump-at", required_argument, 0, 'd' }, { "dump-vcount", required_argument, 0, 'V' },
		{ "shot-every", required_argument, 0, 'S' }, { "shot-at", required_argument, 0, 'K' }, { "trace", required_argument, 0, 't' },
		{ "trace-io", required_argument, 0, 'I' }, { "trace-mem", required_argument, 0, 'M' },
		{ "trace-lines", required_argument, 0, 'L' }, { "watch-write", required_argument, 0, 'w' },
		{ "watch-frames", required_argument, 0, 'W' }, { "watch-read", required_argument, 0, 'R' }, { "watch-max", required_argument, 0, 'x' },
		{ "trace-pc", required_argument, 0, 'p' }, { "trace-pc-regs", no_argument, 0, 'P' },
		{ "pc-max", required_argument, 0, 'X' }, { "coverage", no_argument, 0, 'c' }, { "calls", no_argument, 0, 'C' },
		{ "step-frames", required_argument, 0, 'F' }, { "trace-swi", no_argument, 0, 'i' },
		{ "wav", required_argument, 0, 'a' }, { "save", required_argument, 0, 'v' },
		{ "load-state", required_argument, 0, 'l' }, { "idle", required_argument, 0, 'y' },
		{ "log-level", required_argument, 0, 'g' }, { "quiet", no_argument, 0, 'q' },
		{ "save-type", required_argument, 0, 'T' }, { "openbus", required_argument, 0, 'O' },
		{ "help", no_argument, 0, 'h' }, { 0, 0, 0, 0 },
	};
	int ch;
	while ((ch = getopt_long(argc, argv, "", longopts, NULL)) != -1) {
		switch (ch) {
		case 'r': opt.rom = optarg; break;
		case 'b': opt.bios = optarg; break;
		case 'o': opt.out = optarg; break;
		case 's': opt.script = optarg; break;
		case 'n': opt.frames = atol(optarg); break;
		case 'd': opt.nDumpAt += parseRanges(optarg, opt.dumpAt + opt.nDumpAt, MAX_RANGES - opt.nDumpAt); break;
		case 'S': opt.shotEvery = atol(optarg); break;
		case 'V': opt.dumpVcount = atoi(optarg); break;
		case 'K': opt.nShotAt += parseRanges(optarg, opt.shotAt + opt.nShotAt, MAX_RANGES - opt.nShotAt); break;
		case 't': opt.nTrace += parseRanges(optarg, opt.trace + opt.nTrace, MAX_RANGES - opt.nTrace); break;
		case 'I': {
			char* s = strdup(optarg);
			for (char* tok = strtok(s, ","); tok; tok = strtok(NULL, ",")) {
				if (opt.nTraceIo >= 64) die("too many --trace-io registers (at most 64)");
				if (!ioByName(tok)) die("unknown I/O register %s", tok);
				opt.traceIo[opt.nTraceIo++] = tok;
			}
			break;
		}
		case 'M': {
			char* s = strdup(optarg);
			for (char* tok = strtok(s, ","); tok; tok = strtok(NULL, ",")) {
				if (opt.nTraceMem >= MAX_RANGES) die("too many --trace-mem entries (at most %d)", MAX_RANGES);
				char* colon = strchr(tok, ':');
				opt.traceMem[opt.nTraceMem].lo = parseNum(tok);
				opt.traceMem[opt.nTraceMem].hi = colon ? parseNum(colon + 1) : 4;
				opt.nTraceMem++;
			}
			break;
		}
		case 'L': opt.nLines += parseRanges(optarg, opt.lines + opt.nLines, MAX_RANGES - opt.nLines); break;
		case 'w': opt.nWatch += parseRanges(optarg, opt.watch + opt.nWatch, MAX_RANGES - opt.nWatch); break;
		case 'R': opt.nWatchRead += parseRanges(optarg, opt.watchRead + opt.nWatchRead, MAX_RANGES - opt.nWatchRead); break;
		case 'W': opt.nWatchFrames += parseRanges(optarg, opt.watchFrames + opt.nWatchFrames, MAX_RANGES - opt.nWatchFrames); break;
		case 'x': opt.watchMax = atol(optarg); break;
		case 'p': opt.nPc += parseRanges(optarg, opt.pc + opt.nPc, MAX_RANGES - opt.nPc); break;
		case 'P': opt.pcRegs = true; break;
		case 'X': opt.pcMax = atol(optarg); break;
		case 'c': opt.coverage = true; break;
		case 'C': opt.calls = true; break;
		case 'F': opt.nStepFrames += parseRanges(optarg, opt.stepFrames + opt.nStepFrames, MAX_RANGES - opt.nStepFrames); break;
		case 'i': opt.traceSwi = true; break;
		case 'a': opt.wav = optarg; break;
		case 'v': opt.save = optarg; break;
		case 'l': opt.loadState = optarg; break;
		case 'y': opt.idle = optarg; break;
		case 'g': opt.logLevel = (int) strtol(optarg, NULL, 0); break;
		case 'q': opt.quiet = true; break;
		case 'T': opt.saveType = optarg; break;
		case 'O': opt.openbusOn = true; opt.openbus = parseNum(optarg); break;
		default: usage();
		}
	}
	if (!opt.rom || !opt.bios || !opt.out) usage();
	if (!opt.script && opt.frames < 0) die("need --script and/or --frames");
	mkdirs(opt.out);

	mLogSetDefaultLogger(&logger);
	core = GBACoreCreate();
	if (!core || !core->init(core)) die("core init failed");
	mCoreInitConfig(core, NULL); /* empty config: the user's mGBA config.ini is NOT read */
	mCoreConfigSetValue(&core->config, "idleOptimization", opt.idle);
	mCoreConfigSetIntValue(&core->config, "useBios", 1);
	mCoreConfigSetIntValue(&core->config, "skipBios", 0);
	/* With an empty config opts.volume is 0, which sets mGBA's masterVolume to 0
	 * and makes --wav output silent. 0x100 is mGBA's full volume. Audio output
	 * only; emulation is unaffected. */
	mCoreConfigSetIntValue(&core->config, "volume", 0x100);
	mCoreLoadForeignConfig(core, &core->config);
	gba = core->board;
	cpu = core->cpu;

	unsigned w, h;
	core->desiredVideoDimensions(core, &w, &h);
	if (w != W || h != H) die("unexpected video size %ux%u", w, h);
	videoBuf = calloc(W * H, sizeof(color_t));
	core->setVideoBuffer(core, videoBuf, W);
	core->setAudioBufferSize(core, 4096);
	blip_set_rates(core->getAudioChannel(core, 0), core->frequency(core), 32768);
	blip_set_rates(core->getAudioChannel(core, 1), core->frequency(core), 32768);

	struct VFile* romVf = VFileOpen(opt.rom, O_RDONLY);
	if (!romVf || !core->loadROM(core, romVf)) die("cannot load ROM %s", opt.rom);
	struct VFile* biosVf = VFileOpen(opt.bios, O_RDONLY);
	if (!biosVf || !core->loadBIOS(core, biosVf, 0)) die("cannot load BIOS %s (not a GBA BIOS?)", opt.bios);
	struct VFile* saveVf = opt.save ? VFileOpen(opt.save, O_CREAT | O_RDWR) : VFileMemChunk(NULL, 0);
	if (!saveVf) die("cannot open save");
	core->loadSave(core, saveVf);
	if (opt.saveType) {
		static const struct {
			const char* name;
			enum SavedataType type;
		} types[] = {
			{ "sram", SAVEDATA_SRAM }, { "flash512", SAVEDATA_FLASH512 }, { "flash1m", SAVEDATA_FLASH1M },
			{ "eeprom", SAVEDATA_EEPROM }, { "eeprom512", SAVEDATA_EEPROM512 }, { "none", SAVEDATA_FORCE_NONE },
		};
		bool found = false;
		for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); ++i) {
			if (!strcmp(opt.saveType, types[i].name)) {
				GBASavedataForceType(&gba->memory.savedata, types[i].type);
				found = true;
			}
		}
		if (!found) die("unknown --save-type %s", opt.saveType);
	}

	core->reset(core);
	if (!gba->memory.fullBios || !gba->biosVf) die("real BIOS not active after reset");
	uint32_t resetPc = nextPc();
	if (!opt.loadState && resetPc >= 0x4000) die("BIOS was skipped (PC=0x%08X after reset)", resetPc);

	if (opt.loadState) {
		struct VFile* vf = VFileOpen(opt.loadState, O_RDONLY);
		if (!vf || !mCoreLoadStateNamed(core, vf, SAVESTATE_SAVEDATA | SAVESTATE_RTC)) die("cannot load state %s", opt.loadState);
		vf->close(vf);
	}

	fIndex = openOut("index.tsv", "w");
	fprintf(fIndex, "frame\tkind\tlabel\tpath\n");
	fMarks = openOut("marks.tsv", "w");
	fprintf(fMarks, "frame\tlabel\n");
	if (opt.nTrace) {
		fTrace = openOut("trace.tsv", "w");
		traceHeader();
	}
	if (opt.nLines) {
		fLines = openOut("lines.tsv", "w");
		fprintf(fLines, "frame\tvcount\tDISPCNT\tBG0CNT\tBG1CNT\tBG2CNT\tBG3CNT\tBG0HOFS\tBG0VOFS\tBG1HOFS\tBG1VOFS\tBG2HOFS\tBG2VOFS\tBG3HOFS\tBG3VOFS\tBG2PA\tBG2PB\tBG2PC\tBG2PD\tBG2X\tBG2Y\tBG3PA\tBG3PB\tBG3PC\tBG3PD\tBG3X\tBG3Y\tWIN0H\tWIN0V\tWIN1H\tWIN1V\tWININ\tWINOUT\tBLDCNT\tBLDALPHA\tBLDY\tMOSAIC\n");
	}
	if (opt.nWatch) {
		fWrites = openOut("writes.tsv", "w");
		fprintf(fWrites, "frame\tvcount\tsource\tpc\tmode\tlr\tswi_ctx\taddr\tsize\told\tnew\n");
	}
	if (opt.nWatchRead) {
		fReads = openOut("reads.tsv", "w");
		fprintf(fReads, "frame\tvcount\tsource\tpc\tmode\tlr\tswi_ctx\taddr\tsize\tvalue\n");
	}
	if (opt.nWatchRead || opt.openbusOn) installLoadHooks();
	if (opt.nWatch || opt.nTrace) installStoreHooks();
	if (opt.nPc) {
		fPc = openOut("pctrace.tsv", "w");
		fprintf(fPc, "frame\tvcount\tpc\tmode\topcode%s\n", opt.pcRegs ? "\tr0\tr1\tr2\tr3\tr4\tr5\tr6\tr7\tr8\tr9\tr10\tr11\tr12\tsp\tlr\tpc_reg\tcpsr" : "");
	}
	/* SWIs are always counted (cheap); the per-call log is optional. */
	origSwi16 = cpu->irqh.swi16;
	origSwi32 = cpu->irqh.swi32;
	cpu->irqh.swi16 = hSwi16;
	cpu->irqh.swi32 = hSwi32;
	if (opt.traceSwi) {
		fSwi = openOut("swi.tsv", "w");
		fprintf(fSwi, "frame\tvcount\tpc\tmode\tswi\tname\tr0\tr1\tr2\tr3\tlr\n");
	}
	if (opt.calls) {
		callTable = calloc(1u << CALL_TABLE_BITS, sizeof(CallEntry));
		retSet = calloc(1u << CALL_TABLE_BITS, sizeof(uint32_t));
	}
	if (opt.coverage || opt.calls) {
		covRom = calloc(gba->memory.romSize / 2 + 1, 4);
		covModeRom = calloc(gba->memory.romSize / 2 + 1, 1);
		covEwram = calloc(0x20000, 4);
		covModeEwram = calloc(0x20000, 1);
		covIwram = calloc(0x4000, 4);
		covModeIwram = calloc(0x4000, 1);
		covBios = calloc(0x2000, 4);
		covModeBios = calloc(0x2000, 1);
	}
	if (opt.wav) {
		fWav = fopen(opt.wav, "wb");
		if (!fWav) die("cannot write %s", opt.wav);
		writeWavHeader(fWav, 0, 32768);
	}

	uint32_t startFrame = curFrame();
	clock_t t0 = clock();
	if (opt.script) runScript(opt.script);
	if (opt.frames >= 0) {
		while (!frameLimitReached()) runFrames(1, heldKeys);
	}
	double secs = (double) (clock() - t0) / CLOCKS_PER_SEC;

	if (fWav) {
		writeWavHeader(fWav, wavSamples, 32768);
		fclose(fWav);
	}
	if (opt.coverage) {
		FILE* f = openOut("coverage.tsv", "w");
		fprintf(f, "addr\tmode\tcount\n");
		struct { uint32_t base; uint32_t n; uint32_t* arr; uint8_t* modes; } regs[] = {
			{ 0x00000000, 0x2000, covBios, covModeBios }, { 0x02000000, 0x20000, covEwram, covModeEwram },
			{ 0x03000000, 0x4000, covIwram, covModeIwram }, { 0x08000000, gba->memory.romSize / 2, covRom, covModeRom },
		};
		for (size_t r = 0; r < 4; ++r) {
			for (uint32_t i = 0; i < regs[r].n; ++i) {
				if (regs[r].arr[i]) {
					uint8_t m = regs[r].modes[i];
					fprintf(f, "%08X\t%s\t%u\n", regs[r].base + i * 2, m == 3 ? "AT" : m == 2 ? "T" : "A", regs[r].arr[i]);
				}
			}
		}
		fclose(f);
	}

	if (opt.calls) {
		CallEntry* list = malloc(sizeof(CallEntry) * (nCalls + 1));
		uint32_t n = 0;
		for (uint32_t i = 0; i < (1u << CALL_TABLE_BITS); ++i) {
			if (callTable[i].key) list[n++] = callTable[i];
		}
		qsort(list, n, sizeof(CallEntry), cmpCall);
		FILE* f = openOut("calls.tsv", "w");
		fprintf(f, "target\tmode\tkind\tcount\tfirst_from\tfirst_frame\n");
		for (uint32_t i = 0; i < n; ++i) {
			fprintf(f, "%08X\t%c\t%s\t%u\t%08X\t%u\n", list[i].key & ~1u, (list[i].key & 1) ? 'T' : 'A',
			        list[i].kind == 1 ? "call" : "bx", list[i].count, list[i].firstFrom, list[i].firstFrame);
		}
		fclose(f);
		free(list);
	}

	FILE* s = openOut("summary.json", "w");
	fprintf(s, "{\n  \"start_frame\": %u,\n  \"end_frame\": %u,\n  \"wall_seconds\": %.2f,\n", startFrame, curFrame(), secs);
	fprintf(s, "  \"rom_crc32\": \"0x%08X\",\n  \"bios_checksum\": \"0x%08X\",\n  \"bios_official\": %s,\n  \"pc_after_reset\": \"0x%08X\",\n",
	        gba->romCrc32, gba->biosChecksum, gba->biosChecksum == GBA_BIOS_CHECKSUM ? "true" : "false", resetPc);
	fprintf(s, "  \"loaded_state\": %s%s%s,\n  \"idle_optimization\": \"%s\",\n", opt.loadState ? "\"" : "", opt.loadState ? opt.loadState : "null", opt.loadState ? "\"" : "", opt.idle);
	fprintf(s, "  \"savedata_type\": \"%s\",\n", savedataName(gba->memory.savedata.type));
	if (opt.saveType) fprintf(s, "  \"forced_save_type\": \"%s\",\n", opt.saveType);
	if (opt.openbusOn) {
		fprintf(s, "  \"openbus_override\": {\"value\": \"0x%08X\", \"game_loads_overridden\": %llu},\n", opt.openbus,
		        (unsigned long long) openbusHits);
	}
	fprintf(s, "  \"log_counts\": {\"fatal\": %ld, \"error\": %ld, \"warn\": %ld, \"info\": %ld, \"debug\": %ld, \"stub\": %ld, \"game_error\": %ld},\n",
	        logCounts[0], logCounts[1], logCounts[2], logCounts[3], logCounts[4], logCounts[5], logCounts[6]);
	fprintf(s, "  \"swi_counts\": {");
	bool first = true;
	for (int i = 0; i < 256; ++i) {
		if (swiCounts[i]) {
			fprintf(s, "%s\"0x%02X %s\": %llu", first ? "" : ", ", i, i < 0x2B ? SWI_NAMES[i] : "?", (unsigned long long) swiCounts[i]);
			first = false;
		}
	}
	fprintf(s, "},\n");
	if (opt.coverage) {
		fprintf(s, "  \"executed_instructions_by_region\": {\"bios\": %llu, \"ewram\": %llu, \"iwram\": %llu, \"rom\": %llu, \"other\": %llu},\n",
		        (unsigned long long) covTotalByRegion[0], (unsigned long long) covTotalByRegion[2], (unsigned long long) covTotalByRegion[3],
		        (unsigned long long) (covTotalByRegion[8] + covTotalByRegion[9]), (unsigned long long) covOther);
	}
	fprintf(s, "  \"write_log_lines\": %ld,\n  \"read_log_lines\": %ld,\n  \"pc_trace_lines\": %ld\n}\n", nWriteLines, nReadLines, nPcLines);
	fclose(s);
	if (!opt.quiet) fprintf(stderr, "done: frames %u..%u in %.2fs, save type %s\n", startFrame, curFrame(), secs, savedataName(gba->memory.savedata.type));

	if (fTrace) fclose(fTrace);
	if (fLines) fclose(fLines);
	if (fWrites) fclose(fWrites);
	if (fReads) fclose(fReads);
	if (fPc) fclose(fPc);
	if (fSwi) fclose(fSwi);
	fclose(fIndex);
	fclose(fMarks);
	core->deinit(core);
	return 0;
}
