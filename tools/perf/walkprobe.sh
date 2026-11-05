#!/bin/bash
# walkprobe.sh — the walker against walls, a ledge, slopes, falls, a kerb and
# a low ceiling, on a yard of static boxes 130 m out from the base
# (walkprobe_modes.lua; playtest 2026-11-05 "super slidy … fall damage").
#
#   walkprobe.sh <engine> [modes]   modes: walk walkshots (pictures: $WORK/proj/save/user/walkshots/)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#
# It splices walkprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `WP R` lines (one per scenario) and `WP T` traces.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-walk}
eng=${1:?usage: walkprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/walkprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "walk" then run_walk()\n'
              '    elseif MODE == "walkshots" then run_walkshots()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-walk}
rc=$?
for m in ${*:-walk}; do grep -a "WP \|crew: #\|ERROR" $S/results/*/$m.log 2>/dev/null | grep -v "WP T " | cut -c1-400 | tail -80; done
rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
exit $rc
