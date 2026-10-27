#!/bin/bash
# stageprobe.sh — multi-stage and multi-type craft (2026-10-26 playtest: "the
# stage menu is totally broken", and a jet on a rocket's radial decoupler that
# left its cockpit — and the controls — on the rocket).
#
#   stageprobe.sh <engine> [modes]   modes: stagejet stage3 stagelander stagevab (default all four)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode here)
#
# It splices stageprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# The player's craft (crafts/rocketjet.json) is copied into the scratch
# project as user://probe_rocketjet.json. Look for `SP PASS|FAIL` and
# `SP RESULT` lines; pictures land in $WORK/proj/save/user/stageshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-stage}
eng=${1:?usage: stageprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
cp $HERE/crafts/rocketjet.json $S/proj/save/user/probe_rocketjet.json
python3 - "$S/tools/perfbench.lua" "$HERE/stageprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "stagejet" then run_stagejet()\n    elseif MODE == "stage3" then run_stage3()'
              '\n    elseif MODE == "stagelander" then run_stagelander()\n    elseif MODE == "stagevab" then run_stagevab()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-stagejet stage3 stagelander stagevab}
