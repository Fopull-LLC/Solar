#!/bin/bash
# sweepprobe.sh — what falling spent stages cost physics (sweepprobe_modes.lua).
#
#   sweepprobe.sh <engine> [modes]   modes: sweep (default)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 360 s a mode here)
#
# It splices sweepprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `DS` lines (sweeps and the pieces' body cost per frame, a variant
# each) and the PB RESULT lines of the s_* windows.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-sweep}
eng=${1:?usage: sweepprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/sweepprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "sweep" then run_sweep()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-360} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-sweep}
