#!/bin/bash
# mapcamprobe.sh — the map's camera modes in a fresh career save (perfmap
# 2026-11-11). Boots as bench.sh does, then tools/perf/framemon.lua's MC
# sequence: the map opened, FREE / HORIZON / ORBIT BALL / FOLLOW held in turn
# on yourself and on the home world (with drags), a picture of each and its
# frame times. (In a scenario: scnprobe.sh with EXTRA_LUA=framemon.lua and
# BENCH_STRS='("fm_cam", "1")'.)
#
#   mapcamprobe.sh <engine>        env: WORK LOCK SOLAR TAG PATCHES as bench.sh
#
# Look for `MC SHOT`, `FM ACT mc|…`. Pictures: $WORK/proj/save/user/scnshots/map_*.png
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-mapcam}
eng=${1:?usage: mapcamprobe.sh <engine>}
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/framemon.lua" <<'PY'
import sys
p = sys.argv[1]
m = open(sys.argv[2]).read() + "\n"
s = open(p).read()
s = s.replace("function update(node, dt)\n  measure()", "function update(node, dt)\n  measure()\n  if MON_tick then MON_tick() end", 1)
s = s.replace('  P("DONE mode %s', '  if MON_total then MON_total() end\n  P("DONE mode %s', 1)
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    if MODE == "quick" then run_quick()', '    if MODE == "mapcam" then perf.enable(true); wait(2.0); while not MC.done do MC_step(); yield() end; wait(1.0)\n    elseif MODE == "quick" then run_quick()', 1)
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/scnshots
SOLAR=$SOL WORK=$S TMO=${TMO:-300} bash $S/tools/bench.sh $eng mapcam
