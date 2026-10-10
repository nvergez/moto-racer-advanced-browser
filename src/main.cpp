// Native entry point for the recompiled Moto Racer Advance.
//
// The ROM identity is built in from the game config (see CMakeLists.txt and
// mra_build_config.h.in), so the executable refuses any other ROM even when it
// runs without game.toml. Game-owned hooks and enhancements will be installed
// here, before run_game(), as later phases need them.
#include "mra_build_config.h"
#include "runtime.h"

int main(int argc, char** argv) {
    gbarecomp::RunOptions opts;
    opts.builtin_game_name = MRA_GAME_NAME;
    opts.builtin_rom_sha1 = MRA_ROM_SHA1;
    return gbarecomp::run_game(argc, argv, opts);
}
