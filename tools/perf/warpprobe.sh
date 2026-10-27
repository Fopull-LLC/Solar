#!/bin/bash
# warpprobe.sh — time warp parked and on foot (2026-10-27 playtest: the warp
# was forced down a step at 50-100× with a craft parked on the ground, and
# there was no warp on foot).
#
#   warpprobe.sh <engine> [modes]     modes: warprover warpfoot (default both)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS BENCH_STRS as bench.sh, e.g.
#        BENCH_PARAMS='("warpsecs", 60.0)'   BENCH_STRS='("res", "1280x720")'
#
# It splices warpprobe_modes.lua into a copy of perfbench.lua (before its main)
# and runs that copy through bench.sh; the repo's perfbench is untouched. Look
# for `WP` lines; pictures land in $WORK/proj/save/user/warpshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-warp}
eng=${1:?usage: warpprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/warpprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "warprover" then run_warprover()\n'
              '    elseif MODE == "warpfoot" then run_warpfoot()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-warprover warpfoot}
