#!/bin/bash
# visual6probe.sh — playtest 2026-11-06 visuals on a fresh home world: grass
# frame bursts (day, night, each suspect off) and a Power Cable laid over a Pad
# Plate on rolling ground, its settle checked against the terrain and shot in a
# high and a low sun (tools/perf/visual6probe_modes.lua).
#
#   visual6probe.sh <engine>
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#        (run with PATCHES=funds.patch: a fresh save has $500)
#
# Splices vfxprobe_modes.lua (its freecam), buildkitprobe_modes.lua,
# gridprobe_modes.lua and visual6probe_modes.lua into a copy of perfbench.lua.
# Pictures land in $WORK/proj/save/user/visual6/; `python3 tools/perf/flicker_diff.py
# <that folder>` measures the bursts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-visual6}
eng=${1:?usage: visual6probe.sh <engine>}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/gridprobe_modes.lua" "$HERE/visual6probe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
mods = "".join(open(f).read() for f in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + mods + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "visual6" then BK.run_visual6()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/visual6
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng visual6
