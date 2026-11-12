#!/bin/bash
# farmesh.sh — the far-body impostor's mesh.build with lists and with buffers
# (engine 0698), and a picture of each (tools/perf/farmesh_modes.lua)
#
#   farmesh.sh <engine>      env: WORK LOCK SOLAR TAG PATCHES as bench.sh
#
# Splices farmesh_modes.lua into a copy of perfbench.lua and runs mode
# "farmesh" through bench.sh (one locked play). `FMB` lines; pictures in
# $WORK/proj/save/user/farmesh/ (compare lists*.png with buffers*.png).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-farmesh}
eng=${1:?usage: farmesh.sh <engine>}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/farmesh_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "farmesh" then run_farmesh()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/farmesh
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng farmesh
grep -a "FMB \|ERROR\|far_bodies" $S/results/${TAG:-*}/farmesh.log 2>/dev/null | cut -c1-400 | tail -40
