// Input replays compiled into a test build, for runs that cannot read a file
// (the browser bundle). tools/replay/script2replay.py --embed writes the table
// under build/; src/main.cpp looks a route up in it for
// MRA_REPLAY=embedded:ROUTE. Builds without replays link
// src/replay_routes_none.cpp, an empty table (docs/phase2-plan.md, P2-02).
#pragma once

extern "C" {

struct MraReplayRoute {
    const char* name;    // route name, as in tools/difftest/routes.toml
    const char* replay;  // the route's replay, mra-keyinput-v1 text
};

// The table; its length goes to *count.
const MraReplayRoute* mra_replay_route_table(unsigned* count);

}  // extern "C"
