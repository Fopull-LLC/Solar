#!/bin/bash
# gfxshot.sh — the Graphics tab and what each preset costs (2026-11 perf pass)
#
#   gfxshot.sh <engine>        env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh;
#                              BENCH_PARAMS='("gfx_ab", 1.0)' adds the option-by-option GPU sweep;
#                              BENCH_STRS='("res", "1920x1080")' the window size
#
# Splices gfxshot_modes.lua into a copy of perfbench.lua (before its main) and
# runs mode "gfxshots" through bench.sh (one locked play). `GS` lines; pictures
# in $WORK/proj/save/user/gfxshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-gfxshot}
eng=${1:?usage: gfxshot.sh <engine>}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/gfxshot_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "gfxshots" then run_gfxshots()')
open(p, 'w').write(s)
PY
# a fresh player: no settings file left by an earlier run (settings.lua keeps them in user://settings.json)
rm -f $S/proj/save/user/settings.json
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng gfxshots
grep -a "GS \|ERROR" $S/results/${TAG:-*}/gfxshots.log 2>/dev/null | cut -c1-400 | tail -40
