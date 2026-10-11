// The routes table of a build without embedded input replays: empty. Test
// builds compile the table tools/replay/script2replay.py --embed writes
// instead (CMakeLists.txt, MRA_REPLAY_ROUTES).
#include "replay_routes.h"

extern "C" const MraReplayRoute* mra_replay_route_table(unsigned* count) {
    *count = 0;
    return nullptr;
}
