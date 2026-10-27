#!/bin/bash
# seaprobe.sh — the sea's Water Volume (engine card 0551: density 0 = look and
# water.at only, no buoyancy, no warnings) and stale node handles (card 0552).
#
#   seaprobe.sh <engine>                 mode: sea (handle repro, crew under and on the sea, a rover dropped in)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# It splices seaprobe_modes.lua into a copy of perfbench.lua (before its main)
# and runs that copy through bench.sh; the repo's perfbench is untouched. Look
# for `SH RESULT`, `SEA` lines and the engine's `≈ ... density` warnings;
# pictures in $WORK/proj/save/user/seashots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-sea}
eng=${1:?usage: seaprobe.sh <engine>}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/seaprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "sea" then run_sea()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-sea}
