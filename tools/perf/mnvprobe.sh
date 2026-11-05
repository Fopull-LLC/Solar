#!/bin/bash
# mnvprobe.sh — the click-and-drag maneuver node (orbit_map.lua: the gizmo,
# its menu, warp to node) in the engine, with pictures.
#
#   mnvprobe.sh <engine> [modes]     modes: mnvnode (default)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS BENCH_STRS as bench.sh
#
# It splices mnvprobe_modes.lua into a copy of perfbench.lua (before its main)
# and runs that copy through bench.sh; the repo's perfbench is untouched. Look
# for `MP PASS|FAIL`, `MP LOCK` and `MP RESULT` in the mode's log; pictures
# land in $WORK/proj/save/user/mnvshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-mnv}
eng=${1:?usage: mnvprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/mnvprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "mnvnode" then MP.run()')
open(p, 'w').write(s)
PY
TMO=${TMO:-420} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-mnvnode}
