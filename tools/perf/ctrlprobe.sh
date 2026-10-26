#!/bin/bash
# ctrlprobe.sh — the craft control-mode probe (2026-10-26 playtest: "landing
# gear as a rover wheel", "rover wheels as a plane's gear", and a mode the
# player can just pick: Auto, Rover, Aircraft, Rocket).
#
#   ctrlprobe.sh <engine> [modes]   modes: ctrlrover ctrljet ctrljetwheels ctrlrevert (default all four)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 360 s a mode here)
#
# It splices ctrlprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `CP PASS|FAIL` and `CP RESULT` lines; pictures land in
# $WORK/proj/save/user/ctrlshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-ctrl}
eng=${1:?usage: ctrlprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ctrlprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "ctrlrover" then run_ctrlrover()\n    elseif MODE == "ctrljet" then run_ctrljet()'
              '\n    elseif MODE == "ctrljetwheels" then run_ctrljetwheels()\n    elseif MODE == "ctrlrevert" then run_ctrlrevert()')
open(p, 'w').write(s)
PY
TMO=${TMO:-360} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-ctrlrover ctrljet ctrljetwheels ctrlrevert}
