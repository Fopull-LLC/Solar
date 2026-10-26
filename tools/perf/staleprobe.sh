#!/bin/bash
# staleprobe.sh — a handle kept from a node that is gone (engine card 0552:
# a script's node handle is the engine's bare slot number, and a destroyed
# node's slot is handed to the next node spawned).
#
#   staleprobe.sh <engine>                 mode: stale (laser chunks stowed, their slots reused, then evicted)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# It splices staleprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `SP RESULT` (PASS / FAIL / INCONCLUSIVE) and `SP` lines.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-stale}
eng=${1:?usage: staleprobe.sh <engine>}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/staleprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "stale" then run_stale()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-stale}
