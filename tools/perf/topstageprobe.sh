#!/bin/bash
# topstageprobe.sh — the upper stage's engine after an axial decoupler fires
# (2026-11-03 playtest: "after decoupling my top stage (the decoupler was right
# below the engine) my top stage was not able to use the engine at all").
#
#   topstageprobe.sh <engine> [modes]   modes: topuser topsimple topcabin (default all three)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode here)
#
# Splices topstageprobe_modes.lua into a copy of perfbench.lua (before its main)
# and runs that copy through bench.sh. The player's craft (crafts/deepspace_mission.json,
# a copy of their library file) is copied in as user://probe_deepspace.json.
# Look for `TS PASS|FAIL` and `TS RESULT`; pictures in $WORK/proj/save/user/topshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-topstage}
eng=${1:?usage: topstageprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
cp $HERE/crafts/deepspace_mission.json $S/proj/save/user/probe_deepspace.json
python3 - "$S/tools/perfbench.lua" "$HERE/topstageprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "topuser" then run_topuser()\n    elseif MODE == "topsimple" then run_topsimple()'
              '\n    elseif MODE == "topcabin" then run_topcabin()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-topuser topsimple topcabin}
