# tools/perf — Solar's frame benchmark, stutter probes and gameplay smoke

Everything that measures Solar on a real engine lives here, in the repo, because
the session scratchpad is tmpfs and is wiped on every reboot (twice in October
2026, taking the probes and every result with it). Results go in `results/<rc>.md`.

## bench.sh — one `floptle play` per mode, silent, under the shared engine lock

    WORK=$SCRATCH/perf LOCK=$SCRATCH/engine.lock tools/perf/bench.sh <engine> [modes]

`<engine>` is a version under `~/.local/share/floptle/versions` or a binary path.
It builds a scratch project (assets symlinked; scripts, scenes, prefabs and
project.ron copied; `perfbench.lua` as the entry scene's script), runs each mode
as its own play, and writes `$WORK/results/<TAG>/{<mode>.log,bench.jsonl,table.md}`
plus `<mode>.uptime` (the machine's load before and after: always quote it).
XWayland and vsync Off by default (KWin paces a native Wayland window at 20 fps
while the screen is locked; see card 0528).

Modes (`perfbench.lua`, strs `mode`):

| mode | save | what |
|---|---|---|
| base | fresh | load, 30 s on foot, 20 laser bites on a meadow and on rock, the orbit map |
| rocket | fresh | the two-stage Skipper→Anvil from the pad to orbit, throttle changes, the map |
| plane | fresh | the 27-part jet: take-off roll (with the 0526 **BURST** capture) and low flight |
| rover | fresh | a 6-part rover driven from the runway past 110 m |
| builder | fresh | the in-VAB builder at 300/1,000/3,000 parts, then a ~1,000-part launch and its settling (`loads=1` lets it break up) |
| foot | player's | stand 20 s, walk 40 s at the spawn |
| meadow | player's | 220 m out to the grassiest spot, stand 8 s, walk 40 s (the turf-wash relay, 0525) |
| digmeadow | player's | 100 laser bites on that meadow |
| park | either | a 6-wheel rover rolled out, released, brakes on: time to `node.asleep`, the wake reason, physics ms/frame (0527/0531) |
| bigpark | either | the 1,002-part finned spine released on the pad with no throttle: sleep and physics before/after (0509/0531) |
| gameplay | either | the gameplay smoke: in-VAB rover rollout + 100 m drive, two-stage to orbit, starter rocket to apex + revert to launch, jet take-off, 1,002-part rollout and release. One `RESULT SMOKE <step>: PASS/FAIL` line a step |
| quick | either | 15 s idle with the 0528 pacing readout (`app.refreshRate`, `perf.pacing`); `cap=1` then caps at the refresh |

`USERSAVE=1` copies `save/slot1.ron`, `save/settings.ron` and `saves/slot1` into
the scratch project before every mode and boots from that copy as the menu's
CONTINUE would (slot 1, nothing written). Solar's own save folders are never
written. `BENCH_PARAMS='("sleepsecs", 30.0), ("loads", 1.0)'` passes probe params.

Every scenario prints `PB RESULT [...]` lines (frame stats, the engine's own
buckets/parts/bodies per frame, the fields: `fieldChunks`/`fieldEdited`/
`fieldStandIns`, decalRelay) and one `BENCHJSON` row; `table.py` tabulates them.
On the player's save the probe also prints `GROUND96`: 96 ground radii round the
base summed, at the reveal and after the scenario — the same number on two
engines means the same ground.

## shot.sh — a picture of the tools' marks

    tools/perf/shot.sh <engine> <case> [after-seconds]

Cases: 1 the gravity gun aimed at a plant, 2 the plant being pulled (tether), 3 a
scattered rock aimed at, 4 a loose prop held on the tether. The probe (mode
`shot`) stands the crew before the target, faces it and drives the tool belt's
`sim` hook; `floptle shot --after N` plays that long on the fixed clock and
draws the game's camera to `$WORK/shots/<ver>-case<N>.png`.

## Rules that cost time when broken

- Never write `base.*` or `g_played` as false in a probe save (it reads as an old
  scale-1 world). `boot()` makes a new save exactly as the new-save panel does.
- Rover and drive probes start on the runway, 90 m+ from the pad: the pad deck
  and the facility walls wedge rovers.
- Compare engines only in pairs taken at similar load; the Hub repainted at
  80–99 % CPU under a running game before rc25.
- Delete probe saves (bench.sh removes its own slot 13 and the slot-1 copy).
