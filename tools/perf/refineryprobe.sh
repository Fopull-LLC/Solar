#!/bin/bash
# refineryprobe.sh — expansion X6 (refineries, the Fabricator, RP) in the engine (docs/base-building.md §24).
# One structure on flat ground: a Hopper of Hematite Earth, a Crusher, a
# Furnace (20 % with no cooling, 100 % with two Jacket Radiators), a
# Fabricator, a spoil Hopper, a Kiln, a Regocrete Mixer and an Electrolyser
# with their tanks; RP spent on the research; a crate made and in reach; the
# RECIPE panel; the LOGISTICS overlay; costs idle and running.
#
#   refineryprobe.sh <engine> [modes]   modes: refinery (default)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (PATCHES=funds.patch)
#
# Splices vfxprobe_modes.lua, buildkitprobe_modes.lua, standeditprobe_modes.lua,
# runprobe_modes.lua (the helpers) and refineryprobe_modes.lua into a copy of
# perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/refineryshots/. Look for `RX PASS|FAIL` and `RX RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-refinery}
eng=${1:?usage: refineryprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/standeditprobe_modes.lua" "$HERE/runprobe_modes.lua" "$HERE/refineryprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "refinery" then RX.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/refineryshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng ${*:-refinery}
