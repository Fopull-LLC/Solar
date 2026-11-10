#!/bin/bash
# framefix.sh — the 2026-11-10 playtest's "indicators lagging behind slightly
# and slight world jitter and plants flickering": every camera.worldToScreen
# call checked against the camera as it rendered (LAG), a planet-fixed ground
# point and the crew through the rendered camera (JIT), and plant flicker.
#
#   framefix.sh <engine> [modes]   modes: lag lagrover lagflora (pictures: $WORK/proj/save/user/ffshots/)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#
# It splices framefix_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `FF LAG`, `FF JIT` and `FF FLORA` lines.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-framefix}
eng=${1:?usage: framefix.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/framefix_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "lag" then run_lag()\n'
              '    elseif MODE == "lagrover" then run_lagrover()\n'
              '    elseif MODE == "lagflora" then run_lagflora()\n'
              '    elseif MODE == "lagshadow" then run_lagshadow()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-lag}
