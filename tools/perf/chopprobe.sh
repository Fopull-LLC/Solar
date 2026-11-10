#!/bin/bash
# chopprobe.sh — playtest 11-10: "choppy frame rates the second I started
# placing my first base plate". The Build Kit on the home world: idle, the
# ghost, the first Pad Plate by a click, a 40-piece base, the steady state
# after, every frame over `chopms` (25) ms printed with its culprits.
# `cam`: the full builder's camera at a Base Hub (flat, slope, cliff edge).
#
#   chopprobe.sh <engine> [modes]     modes: chop (default), cam
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS BENCH_STRS as bench.sh
#
# Splices vfxprobe_modes.lua, buildkitprobe_modes.lua, kitprobe_modes.lua,
# chopprobe_modes.lua and camprobe_modes.lua into a copy of perfbench.lua.
# Look for `CHOP` / `CAMP` lines; pictures in $WORK/proj/save/user/buildshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-chop}
eng=${1:?usage: chopprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/kitprobe_modes.lua" "$HERE/chopprobe_modes.lua" "$HERE/camprobe_modes.lua" <<'PY'
import sys, os
p = sys.argv[1]
m = "".join(open(a).read() for a in sys.argv[2:] if os.path.exists(a))
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "chop" then CHOP.run()\n    elseif MODE == "chopab" then CHOP.run_ab()\n    elseif MODE == "cam" then CAMP.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/buildshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng ${*:-chop}
