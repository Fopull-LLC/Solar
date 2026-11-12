#!/bin/bash
# medprobe.sh — the Medical Bay (missions plan M1, with S0's career beats and
# N1's carrying) in the engine, a FRESH career:
#   med       the bay and its link stand; walk in from the lab; talk to Dr Rao
#             (a say, a choice, a shot); healed hp 0.4 → 1.0; a survivor carried
#             in and admitted; a mission_story run; pictures
#   medrover  a rover driven up Road West and the alley into the bay
#
#   medprobe.sh <engine> [modes]       env: WORK LOCK SOLAR TAG PATCHES as bench.sh
#
# Splices medprobe_modes.lua into a copy of perfbench.lua; the repo's
# perfbench is untouched. Pictures land in $WORK/proj/save/user/medshots/.
# Look for `MED PASS|FAIL` and `MED RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-med}
eng=${1:?usage: medprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/medprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "med" then MED.med()\n    elseif MODE == "medrover" then MED.rover()\n    elseif MODE == "medbike" then MED.bike()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/medshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-360} bash $S/tools/bench.sh $eng ${*:-med}
