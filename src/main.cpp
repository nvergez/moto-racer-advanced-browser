// Native entry point for the recompiled Moto Racer Advance.
//
// The ROM identity is built in from the game config (see CMakeLists.txt and
// mra_build_config.h.in), so the executable refuses any other ROM even when it
// runs without game.toml. Game-owned hooks and enhancements are installed
// here, before run_game().
//
// Test hooks (docs/phase2-plan.md, P2-02). Each is off unless its environment
// variable is set; with neither set, nothing below reaches gbarecomp:
//
//   MRA_REPLAY=FILE or MRA_REPLAY=embedded:ROUTE
//     Replay an input trace in the mra-keyinput-v1 format, which
//     tools/replay/script2replay.py writes from a harness input script, at
//     the start of each VBlank, as the mGBA harness applies its inputs. FILE
//     is read once at start; embedded:ROUTE takes the route's replay from the
//     table a test build compiles in (src/replay_routes.h), for the browser,
//     which cannot read a file of ours. The replay goes through gbarecomp's
//     RunOptions::input_frame, so it keeps working while an interpreter bridge
//     holds the run loop. A non-null input_frame also puts gbarecomp in its
//     touch-policy mode, which is why it is installed only when MRA_REPLAY is
//     set.
//
//   MRA_INTERP_BIOS=1, with GBARECOMP_FORCE_INTERP=1
//     The reference of comparison 1 (ADR 0001, decision 5): gbarecomp's
//     interpreter runs the BIOS too, so the two sides of a comparison with the
//     recompiled build do not share the recompiled BIOS. Only 1 turns it on,
//     and 0 or an empty value leaves it off.
//
//   MRA_FP_TAIL=PATH, with GBARECOMP_INSN_TRACE=1 (P2-09)
//     When the run ends, write the last MRA_FP_TAIL_RECORDS records (default
//     500,000, at most 2,000,000) of gbarecomp's per-instruction fingerprint
//     ring to PATH as CSV, for tools/difftest/fpdiff.py. gbarecomp's own
//     GBARECOMP_FP_SAVE writes the whole ring, 8M records of 80 bytes
//     (640 MB) once a run has executed that many instructions; the tail keeps
//     the window around a divergence at about 220 bytes per record.
//
// A bad value stops the program with exit code 2 before the game starts.
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <string>
#include <vector>

#include "mra_build_config.h"
#include "replay_routes.h"
#include "runtime.h"
#include "runtime_arm.h"
#include "touch_input.h"

namespace {

constexpr int kConfigError = 2;

// ---- MRA_REPLAY -------------------------------------------------------------

constexpr char kReplayHeader[] = "mra-keyinput-v1";
constexpr char kEmbeddedPrefix[] = "embedded:";
constexpr std::uint16_t kNoKeys = 0x03FF;          // KEYINPUT, active low
constexpr std::uint64_t kFirstReplayFrame = 2;     // see replay_input_frame
constexpr std::uint64_t kMaxReplayFrame = 0xFFFFFFFFu;
constexpr long kMaxReplayBytes = 16L << 20;

struct ReplayEvent {
    std::uint64_t frame;  // harness frame (tools/analysis/README.md)
    std::uint16_t keys;   // KEYINPUT from that frame on, active low
};

std::vector<ReplayEvent> g_replay;

// The keys of harness frame `frame`: those of the last event at or before it.
std::uint16_t replay_keys(std::uint64_t frame) {
    const auto after = std::upper_bound(
        g_replay.begin(), g_replay.end(), frame,
        [](std::uint64_t f, const ReplayEvent& e) { return f < e.frame; });
    return after == g_replay.begin() ? kNoKeys : std::prev(after)->keys;
}

// RunOptions::input_frame. gbarecomp calls it once per emulated frame at the
// start of VBlank, before the VBlank IRQ is raised, with the PPU frame_count k
// (gbarecomp/src/runtime/runtime.h, RunOptions::input_frame). That VBlank start
// ends harness frame k+1 (docs/research/phase2-diagnosis.md, section 7.3), so
// the frame that starts here is k+2, and these are its keys: the harness sets
// a frame's keys right after the VBlank start that ends the frame before it.
// The returned mask is ANDed with the host keys. It only steers input; it
// reads no guest memory.
std::uint16_t replay_input_frame(const gbarecomp::TouchFrameInfo* frame) {
    return replay_keys(frame->frame_count + 2u);
}

void replay_error(const std::string& source, unsigned line, const std::string& why) {
    if (line)
        std::fprintf(stderr, "mra: MRA_REPLAY: %s:%u: %s\n", source.c_str(), line, why.c_str());
    else
        std::fprintf(stderr, "mra: MRA_REPLAY: %s: %s\n", source.c_str(), why.c_str());
}

bool parse_decimal(const std::string& s, std::uint64_t& out) {
    if (s.empty() || s.size() > 10) return false;
    std::uint64_t v = 0;
    for (const char c : s) {
        if (c < '0' || c > '9') return false;
        v = v * 10u + static_cast<unsigned>(c - '0');
    }
    out = v;
    return true;
}

bool parse_hex(const std::string& s, std::uint64_t& out) {
    if (s.empty() || s.size() > 4) return false;
    std::uint64_t v = 0;
    for (const char c : s) {
        unsigned d;
        if (c >= '0' && c <= '9') d = static_cast<unsigned>(c - '0');
        else if (c >= 'a' && c <= 'f') d = static_cast<unsigned>(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') d = static_cast<unsigned>(c - 'A' + 10);
        else return false;
        v = v * 16u + d;
    }
    out = v;
    return true;
}

// The format is described at the top of tools/replay/script2replay.py, whose
// parse_replay() applies the same rules.
bool parse_replay(const std::string& text, const std::string& source,
                  std::vector<ReplayEvent>& events) {
    std::size_t pos = 0;
    unsigned line_no = 0;
    while (pos < text.size()) {
        std::size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(pos, end - pos);
        pos = end + 1;
        ++line_no;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line_no == 1) {
            if (line != kReplayHeader) {
                replay_error(source, 1, std::string("the first line must be '") +
                                            kReplayHeader + "'");
                return false;
            }
            continue;
        }
        if (line.empty() || line[0] == '#') continue;
        const std::size_t comma = line.find(',');
        std::uint64_t frame = 0, keys = 0;
        if (comma == std::string::npos ||
            !parse_decimal(line.substr(0, comma), frame) ||
            line.compare(comma + 1, 2, "0x") != 0 ||
            !parse_hex(line.substr(comma + 3), keys)) {
            replay_error(source, line_no, "expected FRAME,0xKEYS, got '" + line + "'");
            return false;
        }
        if (frame < kFirstReplayFrame || frame > kMaxReplayFrame) {
            replay_error(source, line_no, "frame " + std::to_string(frame) +
                                              " is outside 2-4294967295");
            return false;
        }
        if (keys > kNoKeys) {
            replay_error(source, line_no, "keys are more than 0x03FF");
            return false;
        }
        if (!events.empty() && frame <= events.back().frame) {
            replay_error(source, line_no, "frame " + std::to_string(frame) +
                                              " does not come after frame " +
                                              std::to_string(events.back().frame));
            return false;
        }
        events.push_back({frame, static_cast<std::uint16_t>(keys)});
    }
    if (line_no == 0) {
        replay_error(source, 0, "empty; the first line must be 'mra-keyinput-v1'");
        return false;
    }
    return true;
}

bool read_file(const char* path, std::string& out) {
    std::FILE* f = std::fopen(path, "rb");
    if (!f) {
        replay_error(path, 0, std::string("cannot open: ") + std::strerror(errno));
        return false;
    }
    char buf[65536];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
        out.append(buf, n);
        if (out.size() > static_cast<std::size_t>(kMaxReplayBytes)) {
            std::fclose(f);
            replay_error(path, 0, "larger than 16 MiB");
            return false;
        }
    }
    const bool failed = std::ferror(f) != 0;
    std::fclose(f);
    if (failed) replay_error(path, 0, "read error");
    return !failed;
}

bool embedded_replay(const std::string& route, std::string& out) {
    unsigned count = 0;
    const MraReplayRoute* table = mra_replay_route_table(&count);
    std::string known;
    for (unsigned i = 0; i < count; ++i) {
        if (route == table[i].name) {
            out = table[i].replay;
            return true;
        }
        known += (known.empty() ? "" : ", ") + std::string(table[i].name);
    }
    if (count == 0)
        replay_error(kEmbeddedPrefix + route, 0,
                     "this build embeds no replays (a test build does: "
                     "scripts/build-native.sh --replays, scripts/build-web.sh --dev --replays)");
    else
        replay_error(kEmbeddedPrefix + route, 0, "no such route; this build embeds " + known);
    return false;
}

bool env_set(const char* name) {
    const char* v = std::getenv(name);
    return v && v[0];
}

// As gbarecomp reads GBARECOMP_FORCE_INTERP (runtime.cpp:1606-1607, run_game):
// set, not empty and not starting with '0'. Only for gbarecomp's variables,
// so that we agree with gbarecomp on whether one is on; ours take 0 or 1.
bool env_on(const char* name) {
    const char* v = std::getenv(name);
    return v && v[0] && v[0] != '0';
}

int install_replay(gbarecomp::RunOptions& opts) {
    const char* value = std::getenv("MRA_REPLAY");
    if (!value || !value[0]) return 0;
    // gbarecomp suspends input_frame while its own replay runs
    // (runtime.cpp, touch_policy_suspended), so ours would do nothing.
    if (env_set("GBARECOMP_INPUT_REPLAY")) {
        std::fprintf(stderr,
                     "mra: MRA_REPLAY and GBARECOMP_INPUT_REPLAY are both set; gbarecomp "
                     "suspends MRA_REPLAY's hook during its own replay. Unset one.\n");
        return kConfigError;
    }
    const std::string source = value;
    std::string text;
    if (source.compare(0, std::strlen(kEmbeddedPrefix), kEmbeddedPrefix) == 0) {
        if (!embedded_replay(source.substr(std::strlen(kEmbeddedPrefix)), text))
            return kConfigError;
    } else if (!read_file(value, text)) {
        return kConfigError;
    }
    std::vector<ReplayEvent> events;
    if (!parse_replay(text, source, events)) return kConfigError;
    g_replay = std::move(events);
    opts.input_frame = &replay_input_frame;
    if (g_replay.empty())
        std::printf("mra_replay=%s events=0\n", source.c_str());
    else
        std::printf("mra_replay=%s events=%zu frames=%llu-%llu\n", source.c_str(),
                    g_replay.size(),
                    static_cast<unsigned long long>(g_replay.front().frame),
                    static_cast<unsigned long long>(g_replay.back().frame));
    return 0;
}

// ---- MRA_INTERP_BIOS ----------------------------------------------------------

constexpr std::uint32_t kBiosEnd = 0x00004000u;

// The force-interp hook that was installed before ours, if any (a game-owned
// one); interpret_bios defers to it above the BIOS.
RuntimeForceInterpHook g_next_force_interp_hook = nullptr;

// g_runtime_force_interp_hook. dispatch_resolve consults it before the BIOS
// dispatch table (gbarecomp/src/armv4t/runtime_arm.cpp), and the run loop and
// the IRQ drive loop before stepping, so every BIOS entry goes to the
// interpreter. With GBARECOMP_FORCE_INTERP alone, an interpreted SWI enters
// the recompiled BIOS (docs/research/phase2-diagnosis.md, section 7.1).
int interpret_bios(std::uint32_t pc, int thumb) {
    if (pc < kBiosEnd) return 1;
    return g_next_force_interp_hook ? g_next_force_interp_hook(pc, thumb) : 0;
}

int install_interp_bios() {
    const char* value = std::getenv("MRA_INTERP_BIOS");
    if (!value || !value[0] || std::strcmp(value, "0") == 0) return 0;
    if (std::strcmp(value, "1") != 0) {
        std::fprintf(stderr, "mra: MRA_INTERP_BIOS must be 1 (on) or 0 (off), not '%s'\n",
                     value);
        return kConfigError;
    }
    if (!env_on("GBARECOMP_FORCE_INTERP")) {
        std::fprintf(stderr,
                     "mra: MRA_INTERP_BIOS needs GBARECOMP_FORCE_INTERP=1: it makes gbarecomp's "
                     "interpreter reference run the BIOS in the interpreter too.\n");
        return kConfigError;
    }
    // Keep a hook installed before ours working above the BIOS. main() calls
    // this last, after every other hook: one installed later would replace
    // ours. run_game clears the hook when it returns (RamDispatchHookReset).
    g_next_force_interp_hook = g_runtime_force_interp_hook;
    g_runtime_force_interp_hook = &interpret_bios;
    std::printf("mra_interp_bios=ENABLED (BIOS PCs below 0x4000 run in the interpreter%s; "
                "each BIOS entry is a bridge, so the coverage banner reads NOT_STATIC)\n",
                g_next_force_interp_hook ? ", other PCs as the game's force-interp hook says"
                                         : "");
    return 0;
}

// ---- MRA_FP_TAIL ------------------------------------------------------------

constexpr unsigned long kFpTailDefault = 500000;
constexpr unsigned long kFpTailMax = 2000000;  // about 440 MB of CSV

const char* g_fp_tail_path = nullptr;
std::uint32_t g_fp_tail_records = 0;

int parse_fp_tail() {
    const char* path = std::getenv("MRA_FP_TAIL");
    const char* records = std::getenv("MRA_FP_TAIL_RECORDS");
    if (!path || !path[0]) {
        if (records && records[0]) {
            std::fprintf(stderr, "mra: MRA_FP_TAIL_RECORDS is set without MRA_FP_TAIL\n");
            return kConfigError;
        }
        return 0;
    }
    // gbarecomp arms the ring from GBARECOMP_INSN_TRACE at machine reset
    // (runtime_trace_reset, runtime_arm.cpp); without it the ring is empty.
    if (!env_on("GBARECOMP_INSN_TRACE")) {
        std::fprintf(stderr,
                     "mra: MRA_FP_TAIL needs GBARECOMP_INSN_TRACE=1, which arms gbarecomp's "
                     "fingerprint ring\n");
        return kConfigError;
    }
    std::uint64_t n = kFpTailDefault;
    if (records && records[0]) {
        if (!parse_decimal(records, n) || n == 0 || n > kFpTailMax) {
            std::fprintf(stderr, "mra: MRA_FP_TAIL_RECORDS must be a number from 1 to %lu, not '%s'\n",
                         kFpTailMax, records);
            return kConfigError;
        }
    }
    g_fp_tail_path = path;
    g_fp_tail_records = static_cast<std::uint32_t>(n);
    std::printf("mra_fp_tail=ENABLED path=\"%s\" records=%llu\n", path,
                static_cast<unsigned long long>(n));
    return 0;
}

// After run_game returns: the ring stays allocated (runtime_shutdown does not
// free it), so its tail is still there to save.
void save_fp_tail() {
    if (!g_fp_tail_path) return;
    const std::uint32_t n = runtime_fp_save_tail_csv(g_fp_tail_path, g_fp_tail_records);
    std::printf("mra_fp_tail_saved path=\"%s\" records=%u\n", g_fp_tail_path, n);
    std::fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
    gbarecomp::RunOptions opts;
    opts.builtin_game_name = MRA_GAME_NAME;
    opts.builtin_rom_sha1 = MRA_ROM_SHA1;
    if (const int rc = install_replay(opts)) return rc;
    if (const int rc = parse_fp_tail()) return rc;
    // Last: it chains to a force-interp hook installed before it.
    if (const int rc = install_interp_bios()) return rc;
    const int rc = gbarecomp::run_game(argc, argv, opts);
    save_fp_tail();
    return rc;
}
