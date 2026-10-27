#!/bin/bash
# targetprobe.sh — Set target, SAS Target and the docking alignment
# (scripts/targeting.lua) in the engine.
#
#   targetprobe.sh <engine> [modes]     modes: tdock (default)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS BENCH_STRS as bench.sh, e.g.
#        BENCH_PARAMS='("gap", 40.0), ("holdsecs", 30.0), ("antisecs", 15.0)'
#
# It splices targetprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `TP` lines; pictures land in $WORK/proj/save/user/targetshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-target}
eng=${1:?usage: targetprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/targetprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "tdock" then run_tdock()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-tdock}
