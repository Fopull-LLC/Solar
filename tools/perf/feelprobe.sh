#!/bin/bash
# feelprobe.sh — the 2026-10-27 playtest's feel items in the real game: the
# rifle scope's zoom and picture, the suited swim, the walker's push on light
# and heavy craft, the gravity gun's power, and the plant marks.
#
#   feelprobe.sh <engine> [modes]   modes: feelscope feelswim feelpush feelheavy feelplants
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#
# It splices feelprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `FEEL RESULT` lines; pictures land in $WORK/proj/save/user/feelshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-feel}
eng=${1:?usage: feelprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/feelprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "feelscope" then run_feelscope()\n    elseif MODE == "feelswim" then run_feelswim()\n'
              '    elseif MODE == "feelpush" then run_feelpush()\n    elseif MODE == "feelheavy" then run_feelheavy()\n'
              '    elseif MODE == "feelplants" then run_feelplants()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-feelscope feelswim feelpush feelheavy feelplants}
