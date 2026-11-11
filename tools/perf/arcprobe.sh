#!/bin/bash
# arcprobe.sh — progression P2 (docs/progression.md §3): the career's arc in
# the engine. A fresh career walks First Steps → Homestead (the ruin near
# home claimed → solar) → Lights On (a grid served, a cable, a night held) →
# Shelter (a sealed hut, its own air, a night inside), the grants checked and
# the milestone card pictured at each step; or an old save keeps its unlocks.
#
#   arcprobe.sh <engine> [modes]   modes: arc (default), arcold (an old save:
#        USERSAVE=1 and SOLAR=<a copy holding the save as save/slot1.ron>)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (PATCHES=funds.patch);
#        BENCH_PARAMS='("arcwarp", 50.0), ("arcnight", 150.0)' the night's warp
#        and its real-seconds budget
#
# Splices vfxprobe_modes.lua, ruinprobe_modes.lua and arcprobe_modes.lua into a
# copy of perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/arcshots/. Look for `AR PASS|FAIL` and `AR RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-arc}
eng=${1:?usage: arcprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/ruinprobe_modes.lua" "$HERE/arcprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "arc" then AR.arc()\n    elseif MODE == "arcold" then AR.old()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/arcshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-380} bash $S/tools/bench.sh $eng ${*:-arc}
