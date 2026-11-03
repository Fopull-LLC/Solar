#!/bin/bash
# procprobe.sh — builder_proc's meshes over VAB visits and a menu round trip
# (procprobe_modes.lua, mode procsoak; engine card 0606, owner lifetimes).
#
#   procprobe.sh <engine>
#   env: WORK LOCK TAG PATCHES BENCH_PARAMS as bench.sh (PATCHES=a reverse
#        patch of scripts/builder_proc.lua gives the "before")
#
# Look for `PROC` lines: perf.counts().scriptMeshes and builder_proc's own
# count in perf.resources() after each visit and after the scene load.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-proc}
eng=${1:?usage: procprobe.sh <engine>}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/procprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "procsoak" then run_procsoak()')
open(p, 'w').write(s)
PY
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-procsoak}
