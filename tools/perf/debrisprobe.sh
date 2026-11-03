#!/bin/bash
# debrisprobe.sh — spent stages packed out of the scene (scripts/debris_pack.lua).
#
#   debrisprobe.sh <engine> [modes]   modes: debrisrevert debris (default both)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 360 s a mode here)
#
# It splices debrisprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `DB CHECK`, `DB RESULT` and the PB RESULT lines of d_debris_live,
# d_debris_packed and d_debris_live2 (the frame cost with the debris in the
# scene, packed, and back); pictures land in $WORK/proj/save/user/debrisshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-debris}
eng=${1:?usage: debrisprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/debrisprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "debris" then run_debris()\n    elseif MODE == "debrisrevert" then run_debrisrevert()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-360} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-debrisrevert debris}
