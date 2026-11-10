#!/bin/bash
# quarryprobe.sh — expansion X5 (quarry, belts, silo, chute) in the engine (docs/base-building.md §23).
# A Build Stand with the VAB's rover on it; beside it four Quarry Posts, a
# Quarry Drive, conveyors to a Hopper, a Silo and a Loading Chute over the
# stand: the survey, live digs, the belts' load, the hold filled from the
# silo, x20 warp, the LOGISTICS overlay, away 2 km and the catch-up, costs.
#
#   quarryprobe.sh <engine> [modes]   modes: logistics (default)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (PATCHES=funds.patch)
#
# Splices vfxprobe_modes.lua, buildkitprobe_modes.lua, standeditprobe_modes.lua,
# runprobe_modes.lua (the helpers) and quarryprobe_modes.lua into a copy of
# perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/quarryshots/. Look for `QX PASS|FAIL` and `QX RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-quarry}
eng=${1:?usage: runprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/standeditprobe_modes.lua" "$HERE/runprobe_modes.lua" "$HERE/quarryprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "logistics" then QX.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/quarryshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng ${*:-logistics}
