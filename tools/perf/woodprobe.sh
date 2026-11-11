#!/bin/bash
# woodprobe.sh — progression W1 (work/progression/PLAN.md §3; docs/base-building.md §35):
# timber in the engine. A motorcycle ridden 150 m out, a gap dug ahead of it, a
# 6 m timber bridge built over it, ridden across, walked back across; a timber
# hut with a hinged plank door walked into; planks ordered, paid with, sawn.
#
#   woodprobe.sh <engine> [wood]
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# Splices vfxprobe_modes.lua (its freecam), buildkitprobe_modes.lua (BK),
# kitprobe_modes.lua (KIT) and woodprobe_modes.lua into a copy of perfbench.lua;
# the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/buildshots/wd*.png. Look for `BK PASS|FAIL` and `BK RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-wood}
eng=${1:?usage: woodprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/kitprobe_modes.lua" "$HERE/woodprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(a).read() for a in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "wood" then WD.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/buildshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-900} bash $S/tools/bench.sh $eng ${*:-wood}
