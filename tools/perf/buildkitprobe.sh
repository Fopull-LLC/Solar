#!/bin/bash
# buildkitprobe.sh — deep-space step 4 (K1–K4, K8, K13, N1): the Build Kit on
# the home world. The Engineer gate, the kit opened with B (free cursor, the
# BASE column), a Pad Plate's ghost under the cursor, placed (price + shipping
# charged), undone (a full refund), placed again with an Equipment Shed, a red
# ghost, save and reload on the moving planet, the colliders, the costs.
#
#   buildkitprobe.sh <engine> [modes]     modes: buildkit (default), stand,
#                                         standedit, tower (step 7: the far side),
#                                         grid (step 8: the base grid, a night on
#                                         the battery, the Shield Wall, a cable)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# Splices vfxprobe_modes.lua (its freecam) and buildkitprobe_modes.lua into a
# copy of perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/buildshots/. Look for `BK PASS|FAIL` and `BK RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-buildkit}
eng=${1:?usage: buildkitprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/standeditprobe_modes.lua" "$HERE/gridprobe_modes.lua" <<'PY'
import sys
p, m1, m2 = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read() + open(sys.argv[4]).read() + open(sys.argv[5]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m1 + m2 + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "buildkit" then BK.run()\n    elseif MODE == "stand" then BK.run_stand()\n    elseif MODE == "standedit" then BK.run_standedit()\n    elseif MODE == "tower" then BK.run_tower()\n    elseif MODE == "grid" then BK.run_grid()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/buildshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng ${*:-buildkit}
