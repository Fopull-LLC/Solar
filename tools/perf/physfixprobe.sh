#!/bin/bash
# physfixprobe.sh — playtest 2026-11-12's physics, death and repair jank
# (physfixprobe_modes.lua): heavy-pack jumps on flat ground, deaths of every
# cause and the frame time across them, the held repair's stance.
#
#   physfixprobe.sh <engine> [modes]   modes: packjump deaths repair
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 330 s a mode)
# `PF ` lines; `PF PASS|FAIL <mode>`; pictures in $WORK/proj/save/user/physfix/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:?WORK}
eng=${1:?usage: physfixprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/physfixprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + "\n" + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif PF_RUN[MODE] then PF_RUN[MODE]()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-330} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-packjump}
rc=$?
for m in ${*:-packjump}; do grep -a "PF \|crew: \|ERROR\|error" $(ls -td $S/results/*/ | head -1)$m.log 2>/dev/null | cut -c1-400 | tail -90; done
rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
exit $rc
