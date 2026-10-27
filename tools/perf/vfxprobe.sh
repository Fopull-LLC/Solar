#!/bin/bash
# vfxprobe.sh — the vehicle feedback effects (scripts/vehicle_fx.lua,
# docs/vfx-feedback.md): pictures and costs of the jet, the rover's marks,
# the rocket's heat and reentry, a damaged rover.
#
#   vfxprobe.sh <engine> [modes]     modes: vfxjet vfxrover vfxrocket vfxdamage (default all)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh, e.g.
#        BENCH_PARAMS='("ralt", 0.35), ("rspeed", 150.0), ("rangle", 25.0)'   (reentry start)
#
# It splices vfxprobe_modes.lua into a copy of perfbench.lua (before its main)
# and runs that copy through bench.sh; the repo's perfbench is untouched.
# Pictures land in $WORK/proj/save/user/vfxshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-vfx}
eng=${1:?usage: vfxprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "vfxjet" then VP.run_jet()\n'
              '    elseif MODE == "vfxrover" then VP.run_rover()\n    elseif MODE == "vfxrocket" then VP.run_rocket()\n'
              '    elseif MODE == "vfxdamage" then VP.run_damage()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-vfxjet vfxrover vfxrocket vfxdamage}
