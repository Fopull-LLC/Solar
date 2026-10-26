#!/bin/bash
# wheelprobe.sh — the wheels-after-reboarding probe (2026-10-26 playtest:
# "wheels will often face the wrong direction when getting off and back on").
#
#   wheelprobe.sh <engine> [modes]        modes: wheels (default), planewheels (the jet's nose gear)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#        BENCH_PARAMS='("sleepwait", 40.0)'  seconds to wait for the chassis to sleep
#
# It splices wheelprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `WP RESULT` and `WP ... FAIL` lines; pictures land in
# $WORK/proj/save/user/wheelshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-wheels}
eng=${1:?usage: wheelprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/wheelprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "wheels" then run_wheels()\n    elseif MODE == "planewheels" then run_planewheels()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-wheels}
