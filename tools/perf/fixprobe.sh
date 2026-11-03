#!/bin/bash
# fixprobe.sh — the 2026-11-03 playtest's flight and VAB fixes, in pictures:
#
#   fixprobe.sh <engine> [modes]   modes: mnvhud stageui symwing roverball (default all four)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#
#   mnvhud     a node planned in the map, then the flight view: the MANEUVER
#              readout (burn start, Δv left falling as it burns, duration) and
#              the ◆ on the navball, held by SAS NODE (the ◆ must sit on the
#              ball's centre cross once the hold has the nose on it)
#   stageui    the STAGE tab: engines as stage items, the four Skippers one
#              group ×4; the group dragged into stage 1; split; then a flight:
#              an upper engine given a stage of its own ignites only on it
#   symwing    the player's plane (crafts/plane_wings.json, wings a ×2 ring
#              round the fuselage), its gear taken off, Landing Gear M put
#              under ONE wing with ×2 on: both under, both pointing down; and
#              ×2 on the fuselage's flank: a low left/right pair. Shots from below
#   roverball  the 6-part rover on the runway: the navball looks along the
#              drive front (pitch ≈ 0), not up its command part
# Splices fixprobe_modes.lua into a copy of perfbench.lua and runs it through
# bench.sh. Look for `FX PASS|FAIL` and `FX RESULT`; pictures in $WORK/proj/save/user/fixshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-fix}
eng=${1:?usage: fixprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
cp $HERE/crafts/deepspace_mission.json $S/proj/save/user/probe_deepspace.json
cp $HERE/crafts/plane_wings.json $S/proj/save/user/probe_plane.json
python3 - "$S/tools/perfbench.lua" "$HERE/fixprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "mnvhud" then run_mnvhud()\n    elseif MODE == "stageui" then run_stageui()'
              '\n    elseif MODE == "symwing" then run_symwing()\n    elseif MODE == "roverball" then run_roverball()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-mnvhud stageui symwing roverball}
