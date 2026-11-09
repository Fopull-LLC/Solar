#!/bin/bash
# fullbuildprobe.sh — the full freecam builder for bases (the Base Hub), the
# playtest 11-09 builder fixes, and player-style creations, in the engine.
#
#   fullbuildprobe.sh <engine> [modes]   modes: fbdiag (the tower's placement
#                                        reasons near the spaceport and far out),
#                                        fbfix (floating floors held through
#                                        what they touch, snaps exact, the
#                                        search field keeping its keys, the
#                                        tower placed), fbhub (a Base Hub placed,
#                                        the full builder opened on it with
#                                        every section, kit pieces, a strut and
#                                        a cockpit placed and committed as base
#                                        structure and live parts), fbmake (the
#                                        five creations, pictures, blueprints)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# Splices vfxprobe_modes.lua, buildkitprobe_modes.lua, kitprobe_modes.lua and
# fullbuildprobe_modes.lua into a copy of perfbench.lua. Pictures land in
# $WORK/proj/save/user/buildshots/. Look for `BK PASS|FAIL`, `FB` lines and
# `BK RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-fullbuild}
eng=${1:?usage: fullbuildprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/kitprobe_modes.lua" "$HERE/fullbuildprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(a).read() for a in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "fbdiag" then FB.run_diag()\n    elseif MODE == "fbfix" then FB.run_fix()\n    elseif MODE == "fbhub" then FB.run_hub()\n    elseif MODE == "fbmake" then FB.run_make()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/buildshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-900} bash $S/tools/bench.sh $eng ${*:-fbdiag}
