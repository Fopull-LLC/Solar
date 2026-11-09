#!/bin/bash
# matprobe.sh — expansion X4 ("Materials & items") in the engine: crated parts
# ordered at home with K into the Depot's supply crate (price + shipping), the
# crate's panel; then on the nearest moon: the reach rule (a supply drop and
# the pack), the cards and the preview plate's recipe, a red ghost with none
# in reach, a steel Wall placed out of its crate, undone back into it, placed
# again and taken down back into it; pictures from two angles while the moon
# moves; the kit's cost (docs/base-building.md §22).
#
#   matprobe.sh <engine> [modes]   modes: materials (default)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh
#
# Splices vfxprobe_modes.lua (its freecam), buildkitprobe_modes.lua (BK.click,
# BK.unlock) and matprobe_modes.lua into a copy of perfbench.lua; the repo's
# perfbench is untouched. Pictures land in $WORK/proj/save/user/matshots/.
# Look for `MX PASS|FAIL` and `MX RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-materials}
eng=${1:?usage: matprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/matprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "materials" then MX.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/matshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng ${*:-materials}
