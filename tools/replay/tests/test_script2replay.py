"""Unit tests for tools/replay/script2replay.py (no game data).

Run: python3 -I -m unittest discover tools/replay/tests
"""
import io
import os
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import script2replay as s2r  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
A, B, SELECT, START, RIGHT = 1, 2, 4, 8, 16


def keys_of(script, frames=None):
    keys, _ = s2r.simulate(textwrap.dedent(script).split("\n"), "t", frames)
    return keys


def frames_with(keys, mask):
    return [f for f in range(1, len(keys)) if keys[f] == mask]


def read(path):
    with open(path) as f:
        return f.read()


class Simulate(unittest.TestCase):
    """The harness's runScript/runFrames, frame by frame."""

    def test_until_then_tap(self):
        # tools/analysis/README.md: "until 2714" then "tap A" puts A in the
        # rows of frames 2715-2720.
        keys = keys_of("until 2714\ntap A\n")
        self.assertEqual(len(keys) - 1, 2726)
        self.assertEqual(frames_with(keys, A), list(range(2715, 2721)))
        self.assertEqual(keys[2714], 0)
        self.assertEqual(keys[2721:], [0] * 6)

    def test_wait_press_taptiming(self):
        keys = keys_of("""\
            wait 10
            press B 3
            press A
            taptiming 2 1
            tap START 2
            """)
        self.assertEqual(frames_with(keys, B), [11, 12, 13])
        self.assertEqual(frames_with(keys, A), list(range(14, 20)))
        self.assertEqual(frames_with(keys, START), [20, 21, 23, 24])
        self.assertEqual(len(keys) - 1, 25)

    def test_hold_release_combine(self):
        keys = keys_of("""\
            hold A
            wait 2
            hold RIGHT
            tap b
            release RIGHT
            wait 1
            release
            wait 1
            """)
        self.assertEqual(keys[1:], [A, A] + [A | RIGHT | B] * 6 + [A | RIGHT] * 6 + [A, 0])

    def test_key_lists(self):
        self.assertEqual(s2r.parse_keys("A+b|select,NONE", "t"), A | B | SELECT)
        self.assertEqual(s2r.parse_keys("none", "t"), 0)
        self.assertEqual(s2r.parse_keys("L+R", "t"), (1 << 9) | (1 << 8))
        with self.assertRaisesRegex(s2r.Error, "unknown key 'X'"):
            s2r.parse_keys("A+X", "t")

    def test_comments_and_frame_free_commands(self):
        keys = keys_of("""\
            # comment
            wait 2   # trailing comment
            dump label
            shot label
            mark label
            savestate x.state
            wait 1
            """)
        self.assertEqual(len(keys) - 1, 3)

    def test_end_stops(self):
        keys = keys_of("wait 5\nend\nwait 5\n", frames=20)
        self.assertEqual(len(keys) - 1, 5)

    def test_frames_truncates(self):
        keys = keys_of("hold A\nwait 100\n", frames=10)
        self.assertEqual(keys[1:], [A] * 10)

    def test_frames_runs_on_with_held_keys(self):
        # gbaharness: after the script, runFrames(1, heldKeys) up to --frames.
        keys = keys_of("wait 3\nhold A\n", frames=6)
        self.assertEqual(keys[1:], [0, 0, 0, A, A, A])

    def test_until_in_the_past_warns(self):
        keys, warnings = s2r.simulate(["wait 10", "until 5", "wait 1"], "t")
        self.assertEqual(len(keys) - 1, 11)
        self.assertEqual(len(warnings), 1)
        self.assertIn("already past frame 5 (at 10)", warnings[0])

    def test_errors(self):
        for script, msg in (("jump 3", "unknown command 'jump'"),
                            ("wait", "wait N"),
                            ("wait -1", "not a non-negative decimal"),
                            ("wait 0x10", "not a non-negative decimal"),
                            ("press", "press KEYS"),
                            ("taptiming 3", "taptiming ON OFF"),
                            ("hold", "hold KEYS"),
                            ("savestate", "savestate PATH"),
                            ("tap Q", "unknown key")):
            with self.subTest(script=script):
                with self.assertRaisesRegex(s2r.Error, msg):
                    s2r.simulate([script], "t")


class Events(unittest.TestCase):
    def test_transitions_active_low(self):
        keys = keys_of("until 2714\ntap A\nwait 1\n")
        self.assertEqual(s2r.events_of(keys), [(2715, 0x03FE), (2721, 0x03FF)])

    def test_offset(self):
        keys = keys_of("until 10\ntap A\n")
        self.assertEqual(s2r.events_of(keys, -1), [(10, 0x03FE), (16, 0x03FF)])
        self.assertEqual(s2r.events_of(keys, 1), [(12, 0x03FE), (18, 0x03FF)])
        with self.assertRaisesRegex(s2r.Error, "lands on frame 1"):
            s2r.events_of(keys_of("wait 1\ntap A\n"), -1)

    def test_keys_on_frame_one_refused(self):
        with self.assertRaisesRegex(s2r.Error, "frame 1"):
            s2r.events_of(keys_of("tap A\n"))

    def test_no_keys_no_events(self):
        self.assertEqual(s2r.events_of(keys_of("wait 100\n")), [])


class Format(unittest.TestCase):
    def test_round_trip(self):
        text = s2r.replay_text([(2, 0x3FE), (100, 0x3FF)], "x.txt", 0, 120)
        self.assertTrue(text.startswith("mra-keyinput-v1\n"))
        self.assertIn("\n2,0x03FE\n100,0x03FF\n", text)
        self.assertEqual(s2r.parse_replay(text), [(2, 0x3FE), (100, 0x3FF)])

    def test_parse_accepts(self):
        text = "mra-keyinput-v1\r\n# c\r\n\r\n10,0x3fe\r\n11,0x3FF\n"
        self.assertEqual(s2r.parse_replay(text), [(10, 0x3FE), (11, 0x3FF)])
        self.assertEqual(s2r.parse_replay("mra-keyinput-v1\n"), [])
        self.assertEqual(s2r.parse_replay("mra-keyinput-v1\n4294967295,0x0\n"), [(4294967295, 0)])

    def test_parse_rejects(self):
        for text, msg in (("", ":1: the first line"),
                          ("# gbarecomp-keyinput-v1\n10,0x3FE\n", ":1: the first line"),
                          ("mra-keyinput-v1 \n", ":1: the first line"),
                          ("mra-keyinput-v1\n10, 0x3FE\n", ":2: expected FRAME,0xKEYS"),
                          ("mra-keyinput-v1\n10,0x03FE0\n", ":2: expected FRAME,0xKEYS"),
                          ("mra-keyinput-v1\n10,3FE\n", ":2: expected FRAME,0xKEYS"),
                          ("mra-keyinput-v1\n1,0x3FE\n", ":2: frame 1 is outside"),
                          ("mra-keyinput-v1\n4294967296,0x3FE\n", ":2: frame 4294967296 is outside"),
                          ("mra-keyinput-v1\n10,0x400\n", ":2: keys 0x400"),
                          ("mra-keyinput-v1\n10,0x3FE\n10,0x3FF\n", ":3: frame 10 does not come after"),
                          ("mra-keyinput-v1\n10,0x3FE\n9,0x3FF\n", ":3: frame 9 does not come after")):
            with self.subTest(text=text):
                with self.assertRaisesRegex(s2r.Error, msg):
                    s2r.parse_replay(text, "r")

    def test_gbarecomp_loader_would_refuse_the_header(self):
        # gbarecomp's GBARECOMP_INPUT_REPLAY loader skips only "#" lines and
        # rejects a line that does not parse as "%llu,0x%x".
        first = s2r.replay_text([], "x").split("\n")[0]
        self.assertFalse(first.startswith("#"))
        self.assertFalse(first[:1].isdigit())

    def test_keys_at(self):
        events = [(10, 0x3FE), (16, 0x3FF)]
        self.assertEqual([s2r.keys_at(events, f) for f in (1, 9, 10, 15, 16, 99)],
                         [0x3FF, 0x3FF, 0x3FE, 0x3FE, 0x3FF, 0x3FF])


class Check(unittest.TestCase):
    def trace(self, d, rows):
        path = os.path.join(d, "trace.tsv")
        with open(path, "w") as f:
            f.write("frame\tkeys\tDISPCNT\n")
            for frame, keys in rows:
                f.write("%d\t%03X\t0000\n" % (frame, keys))
        return path

    def test_check_against_trace(self):
        events = s2r.events_of(keys_of("until 4\ntap A\n"))
        with tempfile.TemporaryDirectory() as d:
            good = self.trace(d, [(f, A if 5 <= f <= 10 else 0) for f in range(1, 17)])
            out = io.StringIO()
            self.assertEqual(s2r.check_trace(events, good, out), 0)
            self.assertIn("16 frames checked, 0 differ", out.getvalue())
            # The same inputs one frame later in the trace: a wrong convention.
            late = self.trace(d, [(f, A if 6 <= f <= 11 else 0) for f in range(1, 17)])
            out = io.StringIO()
            self.assertEqual(s2r.check_trace(events, late, out), 2)
            self.assertIn("first at frame 5: replay 0x03FE, trace 0x03FF", out.getvalue())

    def test_check_cli(self):
        with tempfile.TemporaryDirectory() as d:
            script = os.path.join(d, "s.txt")
            with open(script, "w") as f:
                f.write("until 4\ntap A\n")
            replay = os.path.join(d, "r.csv")
            self.assertEqual(s2r.main([script, "-o", replay], io.StringIO(), io.StringIO()), 0)
            trace = self.trace(d, [(f, A if 5 <= f <= 10 else 0) for f in range(1, 17)])
            out = io.StringIO()
            self.assertEqual(s2r.main(["--check", replay, trace], out, io.StringIO()), 0)
            shifted = os.path.join(d, "r1.csv")
            self.assertEqual(s2r.main([script, "--offset", "1", "-o", shifted],
                                      io.StringIO(), io.StringIO()), 0)
            self.assertEqual(s2r.main(["--check", shifted, trace], io.StringIO(), io.StringIO()), 1)


class Embed(unittest.TestCase):
    def test_cpp_string_escapes(self):
        self.assertEqual(s2r.cpp_string('a"b\\c\n'), '    "a\\"b\\\\c\\n"')
        self.assertEqual(s2r.cpp_string(""), '    ""')

    def test_embed_scripts(self):
        with tempfile.TemporaryDirectory() as d:
            one = os.path.join(d, "one.txt")
            with open(one, "w") as f:
                f.write("until 4\ntap A\n")
            out = os.path.join(d, "routes.cpp")
            err = io.StringIO()
            self.assertEqual(s2r.main(["--embed", out, "--script", "first=" + one,
                                       "--script", "second=" + one], io.StringIO(), err), 0)
            self.assertIn("2 replays (first, second)", err.getvalue())
            src = read(out)
            self.assertIn('#include "replay_routes.h"', src)
            self.assertIn('{"first", kReplay0},', src)
            self.assertIn('{"second", kReplay1},', src)
            self.assertIn('"mra-keyinput-v1\\n"', src)
            self.assertIn('"5,0x03FE\\n"', src)
            mtime = os.stat(out).st_mtime_ns
            # Unchanged content: the file is not rewritten.
            s2r.main(["--embed", out, "--script", "first=" + one, "--script", "second=" + one],
                     io.StringIO(), io.StringIO())
            self.assertEqual(os.stat(out).st_mtime_ns, mtime)
            # A name given twice is refused, and nothing is written.
            err = io.StringIO()
            self.assertEqual(s2r.main(["--embed", out, "--script", "first=" + one,
                                       "--script", "first=" + one], io.StringIO(), err), 1)
            self.assertIn("--script: first given twice", err.getvalue())
            self.assertEqual(os.stat(out).st_mtime_ns, mtime)

    def test_embed_rejects(self):
        err = io.StringIO()
        self.assertEqual(s2r.main(["--embed", "x.cpp", "--script", "9bad=x"], io.StringIO(), err), 1)
        self.assertIn("NAME=SCRIPT", err.getvalue())
        err = io.StringIO()
        self.assertEqual(s2r.main(["--embed", "x.cpp", "--offset", "1"], io.StringIO(), err), 1)

    @unittest.skipIf(sys.version_info < (3, 11), "the manifest needs tomllib")
    def test_embed_manifest(self):
        manifest = textwrap.dedent("""\
            schema = 1
            rom_sha1 = "1111111111111111111111111111111111111111"
            bios_sha1 = "2222222222222222222222222222222222222222"
            [fields.DISPCNT]
            io = "DISPCNT"
            note = "test"
            [routes.short]
            script = "%(script)s"
            frames = 30
            [[routes.short.checkpoints]]
            event = "on"
            when = "DISPCNT == 0"
            frame = 1
            [routes.held]
            script = "%(held)s"
            frames = 8
            [[routes.held.checkpoints]]
            event = "on"
            when = "DISPCNT == 0"
            frame = 1
            """)
        with tempfile.TemporaryDirectory() as d:
            script = os.path.join(d, "short.txt")
            with open(script, "w") as f:
                f.write("until 4\ntap A\n")
            held = os.path.join(d, "held.txt")
            with open(held, "w") as f:
                f.write("wait 3\nhold A\n")  # runs on to frame 8 with A held
            path = os.path.join(d, "routes.toml")
            with open(path, "w") as f:
                f.write(manifest % {"script": script, "held": held})
            out = os.path.join(d, "routes.cpp")
            self.assertEqual(s2r.main(["--embed", out, "--manifest", path], io.StringIO(),
                                      io.StringIO()), 0)
            src = read(out)
            self.assertIn('{"short", kReplay0},', src)
            self.assertIn('{"held", kReplay1},', src)
            self.assertIn('"4,0x03FE\\n"', src)
            # Routes by name; one given twice is refused, and nothing is written.
            self.assertEqual(s2r.main(["--embed", out, "--manifest", path, "--route", "held"],
                                      io.StringIO(), io.StringIO()), 0)
            self.assertIn('{"held", kReplay0},', read(out))
            self.assertNotIn('"short"', read(out))
            err = io.StringIO()
            self.assertEqual(s2r.main(["--embed", out, "--manifest", path, "--route", "short",
                                       "--route", "short"], io.StringIO(), err), 1)
            self.assertIn("--route: short given twice", err.getvalue())
            self.assertNotIn('"short"', read(out))
            # One route by name, with the manifest's frames.
            buf = io.StringIO()
            self.assertEqual(s2r.main(["--route", "held", "--manifest", path], buf, io.StringIO()), 0)
            self.assertEqual(s2r.parse_replay(buf.getvalue()), [(4, 0x03FE)])
            err = io.StringIO()
            self.assertEqual(s2r.main(["--route", "nope", "--manifest", path], io.StringIO(), err), 1)
            self.assertIn("unknown route 'nope'", err.getvalue())


class RepositoryScripts(unittest.TestCase):
    """The committed scripts convert (they hold inputs only, no game data)."""

    def test_boot_to_race(self):
        path = os.path.join(REPO_ROOT, "tools", "analysis", "input", "boot_to_race.txt")
        text, warnings = s2r.convert_script(path)
        self.assertEqual(warnings, [])
        events = s2r.parse_replay(text)
        # until 2450, tap START: START on frames 2451-2456 (README, frame numbering).
        self.assertEqual(events[:2], [(2451, 0x03F7), (2457, 0x03FF)])
        # wait 60, tap A (2523-2528), wait 180: the main menu's A lands on 2715,
        # where routes.toml's "before" frames put it.
        self.assertEqual(events[2:5], [(2523, 0x03FE), (2529, 0x03FF), (2715, 0x03FE)])
        self.assertEqual(events[-1], (4021, 0x03FE))  # RIGHT released, A still held

    def test_every_script_converts(self):
        input_dir = os.path.join(REPO_ROOT, "tools", "analysis", "input")
        for name in sorted(os.listdir(input_dir)):
            if name.endswith(".txt"):
                with self.subTest(script=name):
                    text, _ = s2r.convert_script(os.path.join(input_dir, name))
                    s2r.parse_replay(text)


if __name__ == "__main__":
    unittest.main()
