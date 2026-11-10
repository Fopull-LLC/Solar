#!/bin/bash
# reachprobe.sh — expansion X7 (base roles, reach contracts, Survey II) in the
# engine (docs/base-building.md §25, docs/tracking-station.md §6).
# A base founded ~200 m out with an Electrolyser, a Fuel Tank and hose stand,
# hoppers, a Quarry Drive, a Crusher and a telescope: its roles, the station's
# BASES row, card and role key, the chart's label; the moon's swath grid and
# its res_map on the station's map; the reach contracts; the costs.
#
#   reachprobe.sh <engine> [modes]   modes: reach (default)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (PATCHES=funds.patch)
#
# Splices vfxprobe_modes.lua, buildkitprobe_modes.lua and reachprobe_modes.lua
# into a copy of perfbench.lua; the repo's perfbench is untouched. Pictures land
# in $WORK/proj/save/user/reachshots/. Look for `XR PASS|FAIL` and `XR RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-reach}
eng=${1:?usage: reachprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/reachprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "reach" then XR.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/reachshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng ${*:-reach}
