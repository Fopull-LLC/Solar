#!/bin/bash
# floorprobe.sh — the base's floors and foundations in the engine
# (base_facilities "the floor and its foundations"; floorprobe_modes.lua).
#
#   floorprobe.sh <engine> [modes]     modes: floors (default)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh, e.g.
#        PATCHES='…/tool_belt_dig_guard.patch …/funds.patch' until the hook lands.
#
# Splices floorprobe_modes.lua into a copy of perfbench.lua (before its main)
# and runs it through bench.sh on a fresh save; the repo's perfbench is
# untouched. Look for `FP` lines; pictures land in $WORK/proj/save/user/floorshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-floors}
eng=${1:?usage: floorprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/floorprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "floors" then run_floors()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-420} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-floors}
rc=$?
exit $rc
