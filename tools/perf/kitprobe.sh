#!/bin/bash
# kitprobe.sh — sandbox plan S1/S2 (work/sandbox/PLAN.md §12): the modular
# structure kit and live placed parts on the home world, in the engine.
#
#   kitprobe.sh <engine> [modes]     modes: kit (default: a hab built from
#                                    pieces, walked into, a cockpit boarded, a
#                                    locker opened, a light switched, the Shed
#                                    and Hab prefabs entered, the stand's blue
#                                    display copy, save and reload), kitperf
#                                    (500 / 2,000 / 6,000 pieces in view: counts,
#                                    draws, the render bucket, script ms)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# Splices vfxprobe_modes.lua (its freecam), buildkitprobe_modes.lua (the BK
# helpers) and kitprobe_modes.lua into a copy of perfbench.lua; the repo's
# perfbench is untouched. Pictures land in $WORK/proj/save/user/buildshots/.
# Look for `BK PASS|FAIL`, `KIT` lines and `BK RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-kit}
eng=${1:?usage: kitprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/kitprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(a).read() for a in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "kit" then KIT.run()\n    elseif MODE == "kitperf" then KIT.run_perf()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/buildshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-900} bash $S/tools/bench.sh $eng ${*:-kit}
