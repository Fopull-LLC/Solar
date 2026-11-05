#!/bin/bash
# partshots.sh — craft parts and the lab in the real game, for the realistic-texture wave 3
# (textures/parts, textures/lab): the lab's interior, the VAB with a rocket on the stand,
# that rocket on the pad, a plane on the runway and a rover, each up close from fixed
# points in the craft's own frame (tools/perf/partshots_modes.lua). A NEW Career save,
# silent, under the shared lock.
#
#   WORK=$SCRATCH/parts LOCK=/mnt/disks/3tb/.floptle-shared/engine2.lock tools/perf/partshots.sh <engine> [TAG]
#   env: SOLAR (the checkout to shoot, default this one), PATCHES, TMO (default 600),
#        BENCH_PARAMS: '("vab", 1.0)' takes the VAB view alone (it can't share a run with the
#        launches), '("lab", 0.0)' skips the lab, '("crafts", 0.0)' the craft launches
#
# Pictures land in $WORK/partshots/<TAG>/png, the log in $WORK/results/<TAG>/partshots.log.
# It splices partshots_modes.lua into a copy of perfbench.lua (before its main) and runs
# that copy through bench.sh (which deletes the probe's save slot); the repo's perfbench
# is untouched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:?WORK}
eng=${1:?usage: partshots.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/partshots_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "partshots" then PSX.run_partshots()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/partshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TAG=$TAG TMO=${TMO:-600} bash $S/tools/bench.sh $eng partshots
OUT=$S/partshots/$TAG; mkdir -p $OUT/png
cp $S/proj/save/user/partshots/*.png $OUT/png/ 2>/dev/null
rm -rf $S/proj/save/user/partshots
grep -a "PS \|ERROR\|TIMEOUT" $S/results/$TAG/partshots.log | cut -c1-300 | tail -60
