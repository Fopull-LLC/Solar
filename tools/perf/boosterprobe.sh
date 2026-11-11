#!/bin/bash
# boosterprobe.sh — radial boosters: fuel gating, NEW STAGE and the charge
# (2026-11-11 playtest). See boosterprobe_modes.lua.
#
#   boosterprobe.sh <engine> [modes]   modes: boostvab boostfly (default both)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode here)
#
# It splices boosterprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `SP PASS|FAIL` and `SP RESULT` lines; pictures land in
# $WORK/proj/save/user/stageshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-booster}
eng=${1:?usage: boosterprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/boosterprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "boostvab" then run_boostvab()'
              '\n    elseif MODE == "boostfly" then run_boostfly()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-boostvab boostfly}
