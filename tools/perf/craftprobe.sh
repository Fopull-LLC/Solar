#!/bin/bash
# craftprobe.sh — the craft-physics probes (2026-10-26 playtest: the jet that
# sank into the runway, the rover that rolled right in the air).
#
#   craftprobe.sh <engine> <jetfile.json|-> [modes]     modes: userjet jump (default both)
#     jetfile : a craft-library file (save/user/library/<slot>/<name>.json) for
#               userjet, COPIED into the scratch project as user://probe_jet.json
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh, e.g.
#        BENCH_PARAMS='("pod", 1.0), ("bury", 1.5)'   pod: a pod rover (a real
#        reaction wheel); bury: raise the ground under the held jet by N m;
#        notail: drop the jet's tail gear (uid 31)
#
# It splices craftprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-craft}
eng=${1:?usage: craftprobe.sh <engine> <jetfile|-> [modes]}; jet=${2:--}; shift 2 || shift $#
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/craftprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "userjet" then run_userjet()\n    elseif MODE == "jump" then run_jump()')
open(p, 'w').write(s)
PY
[ "$jet" != "-" ] && cp "$jet" $S/proj/save/user/probe_jet.json
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-userjet jump}
