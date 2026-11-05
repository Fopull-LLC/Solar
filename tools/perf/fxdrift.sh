#!/bin/bash
# fxdrift.sh — do a craft's effects stay with the ground on a world moving on
# its rails? (fxdrift_modes.lua): the jet clamped, rolling and flying, the
# rocket on the pad and climbing, seen from cameras fixed to the ground.
#
#   fxdrift.sh <engine> [modes]     modes: fxjet fxrocket fxgame fxpuff (default all)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# Splices vfxprobe_modes.lua (its cameras) and fxdrift_modes.lua into a copy
# of perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/vfxshots/ (fdjet_*, fdrocket_*).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-fxdrift}
eng=${1:?usage: fxdrift.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/fxdrift_modes.lua" <<'PY'
import sys
p, m1, m2 = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m1 + m2 + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "fxjet" then FD.run_jet()\n'
              '    elseif MODE == "fxrocket" then FD.run_rocket()\n'
              '    elseif MODE == "fxgame" then FD.run_game()\n'
              '    elseif MODE == "fxpuff" then FD.run_puff()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/vfxshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-fxjet fxrocket fxgame fxpuff}
