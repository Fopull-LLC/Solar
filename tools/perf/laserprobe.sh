#!/bin/bash
# laserprobe.sh — expansion X9 (Energy weapons I) in the engine (docs/base-building.md §27).
#   laser   a 10-bank laser and a 1-stage laser on a base grid: charging, pulses
#           at steel / concrete / glass / regocrete walls through the targeting
#           feature, the amplifier's share, a crater, a CW burn, logic fire, the
#           cinematic rule at X11 scale, costs (CPU and GPU with the beam on/off)
#   turret  a craft with a Laser Turret breaks a derelict's tank, AUTO fires on
#           its pod, a kit laser finishes it; costs
#
#   laserprobe.sh <engine> [modes]   modes: laser (default) turret
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (PATCHES=funds.patch)
#
# Splices vfxprobe_modes.lua (its freecam), buildkitprobe_modes.lua (BK) and
# laserprobe_modes.lua into a copy of perfbench.lua; the repo's perfbench is
# untouched. Pictures land in $WORK/proj/save/user/lasershots/. Look for
# `LZ PASS|FAIL`, `LZ …` lines and `LZ RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-laser}
eng=${1:?usage: laserprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/laserprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "laser" then LZP.run()\n    elseif MODE == "turret" then LZP.run_turret()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/lasershots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-420} bash $S/tools/bench.sh $eng ${*:-laser}
