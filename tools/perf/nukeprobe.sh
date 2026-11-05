#!/bin/bash
# nukeprobe.sh — deep-space step 3 (B1 B2 B3 B5 B6 A4 A6): the heat and
# nuclear parts in the VAB (the radiation cone, the heat budget, a shielded
# and a bare seat) and in flight (rods loaded at rollout, the HEAT gauge, the
# radiators out, the Ember critical and settling, a SCRAM with them folded,
# the refused restart, the dose through the shield, the rod menu, fuel
# fabrication on the game clock, the heat loop's own cost).
#
#   nukeprobe.sh <engine> [modes]     modes: nukevab nukefly (default both)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# Splices vfxprobe_modes.lua (its cameras) and nukeprobe_modes.lua into a copy
# of perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/nukeshots/. Look for `NP PASS|FAIL` and `NP RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-nuke}
eng=${1:?usage: nukeprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/nukeprobe_modes.lua" <<'PY'
import sys
p, m1, m2 = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m1 + m2 + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "nukevab" then NP.run_vab()\n'
              '    elseif MODE == "nukefly" then NP.run_fly()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/nukeshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-nukevab nukefly}
