#!/bin/bash
# cloudshot.sh — the weather map the volumetric clouds read (card 0589)
#
#   cloudshot.sh <engine>      env: WORK LOCK SOLAR TAG PATCHES as bench.sh
#
# Splices cloudshot_modes.lua into a copy of perfbench.lua (before its main) and
# runs mode "cloudshots" through bench.sh (one locked play). `CS` lines; pictures
# in $WORK/proj/save/user/cloudshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-cloudshot}
eng=${1:?usage: cloudshot.sh <engine>}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/cloudshot_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "cloudshots" then run_cloudshots()')
open(p, 'w').write(s)
PY
# a fresh player: no settings file left by an earlier run (settings.lua keeps them in user://settings.json)
rm -f $S/proj/save/user/settings.json
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng cloudshots
grep -a "CS \|ERROR\|weather_map" $S/results/${TAG:-*}/cloudshots.log 2>/dev/null | cut -c1-400 | tail -40
