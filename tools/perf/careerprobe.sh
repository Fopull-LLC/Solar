#!/bin/bash
# careerprobe.sh — career missions E1 (work/missions/PLAN.md §6) in the engine:
# two contracts on the books, the advance on signing and its claw-back, ground
# work earning standing; the Ops Board and the objectives card pictured.
#
#   careerprobe.sh <engine> [modes]   modes: career (default), careerold (the
#        player's save: USERSAVE=1 and SOLAR=<a copy holding it as save/slot1.ron>,
#        BENCH_PARAMS='("cpfunds", <its co.funds>)' to check the funds stand)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh
#
# Splices careerprobe_modes.lua into a copy of perfbench.lua; the repo's
# perfbench is untouched. Pictures land in $WORK/proj/save/user/careershots/.
# Look for `CP PASS|FAIL` and `CP RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-career}
eng=${1:?usage: careerprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/careerprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "career" then CP.career()\n    elseif MODE == "careerold" then CP.old()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/careershots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-360} bash $S/tools/bench.sh $eng ${*:-career}
