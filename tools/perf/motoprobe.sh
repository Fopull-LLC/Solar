#!/bin/bash
# motoprobe.sh — the auto-engineering parts in the engine (docs/auto-engineering.md):
# a motorcycle, a car on coil-over struts (and the stock rover over the same
# bumps), a trike on through-axle wheels, and builder pictures.
#
#   motoprobe.sh <engine> [modes]   modes: bike bikegyro car car_rigid trike motoshop (default: all)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#        PATCHES='…/moto_vessel_controller.patch …/moto_builder.patch …/moto_builder_attach.patch'
#        until those land in the scripts.
#
# It splices motoprobe_modes.lua into a copy of perfbench.lua (before its main)
# and runs that copy through bench.sh; the repo's perfbench is untouched. Look
# for `MP RESULT` lines; pictures land in $WORK/proj/save/user/motoshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-moto}
eng=${1:?usage: motoprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/motoprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "bike" then run_bike()\n'
              '    elseif MODE == "bikegyro" then params.gyro = 1; run_bike()\n'
              '    elseif MODE == "car" then run_car(false)\n'
              '    elseif MODE == "car_rigid" then run_car(true)\n'
              '    elseif MODE == "trike" then run_trike()\n'
              '    elseif MODE == "motoshop" then run_motoshop()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-bike bikegyro car car_rigid trike motoshop}
