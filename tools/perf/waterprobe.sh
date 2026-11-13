#!/bin/bash
# waterprobe.sh — there is no set water level (the water pass, S1): a pit dug
# inland under the sea's radius stays dry, a trench from the waterline floods,
# a pit beside a lake seeps full; shots of the shore, the pits and the lake;
# climate.lua's frame cost.
#
#   waterprobe.sh <engine>               mode: water
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# It splices waterprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `WATER RESULT`, `PIT`, `TRENCH`, `LAKEPIT`, `PERF` and `REACH`
# lines; pictures in $WORK/proj/save/user/watershots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-water}
eng=${1:?usage: waterprobe.sh <engine>}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/waterprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "water" then run_water()\n    elseif MODE == "sealook" then run_sealook()\n    elseif MODE == "tysea" then run_tysea()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng ${*:-water}
