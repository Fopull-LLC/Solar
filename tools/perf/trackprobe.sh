#!/bin/bash
# trackprobe.sh — the Tracking Station (the orbit map's STATION mode) and crew
# switching in the engine, with pictures (docs/tracking-station.md §11).
#
#   trackprobe.sh <engine> [modes]     modes: track (default)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (PATCHES=funds.patch:
#        a fresh save has $500 and the rover costs more)
#
# Splices trackprobe_modes.lua into a copy of perfbench.lua; the repo's
# perfbench is untouched. Pictures land in $WORK/proj/save/user/trackshots/.
# Look for `TP PASS|FAIL`, `TP PERF` and `TP RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-track}
eng=${1:?usage: trackprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/trackprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "track" then TP.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/trackshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-720} bash $S/tools/bench.sh $eng ${*:-track}
