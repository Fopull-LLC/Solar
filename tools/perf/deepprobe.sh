#!/bin/bash
# deepprobe.sh — the player's 54-part deep-space craft that "goes ballistic as
# soon as I launch it" (2026-11-02): the build's thrust axes and torque in the
# VAB, then the first seconds off the pad, torque by torque.
#
#   deepprobe.sh <engine> <craft.json> [modes]    modes: deep (default)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh, e.g.
#        BENCH_PARAMS='("straight", 1.0)'   the boosters stood straight
#        BENCH_PARAMS='("sas", 0.0)'        SAS off
# The craft file is COPIED into the scratch project as user://probe_deep.json.
# Look for `DP VAB`, `DP ENG`, `DP T` and `DP RESULT` lines; pictures land in
# $WORK/proj/save/user/deepshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-deep}
eng=${1:?usage: deepprobe.sh <engine> <craft.json> [modes]}; craft=${2:?craft file}; shift 2
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
cp "$craft" $S/proj/save/user/probe_deep.json
python3 - "$S/tools/perfbench.lua" "$HERE/deepprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "deep" then run_deep()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-deep}
