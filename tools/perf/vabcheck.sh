#!/bin/bash
# vabcheck.sh — the VAB's craft check in the real Vehicle Assembly
# (scripts/craft_check.lua; work/vabcheck/PLAN.md §5.2): each craft loaded
# on the stand, its CRAFT CHECK rows printed and photographed with the CHECK
# chip, then the pointer on the first row (its parts outlined).
#
#   vabcheck.sh <engine> [crafts]     crafts: comma list, default
#     jet_nointake,jet_upright,bike125,rocket_heavy (also jet, jet_oneintake,
#     bike500, rover_tall; see vabcheck_modes.lua)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (a scratch project: Solar's
#        saves are never touched; bench.sh deletes the probe's slot after)
#
# Splices tests/fixtures/check/crafts.lua (VCK.CRAFTS), the bike fixtures
# (VCK.FIX) and vabcheck_modes.lua into a copy of perfbench.lua; the repo's
# perfbench is untouched. Pictures land in $WORK/proj/save/user/vabshots/.
# Look for `VCK ROW`, `VCK PASS|FAIL` and `VCK RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:-${TMPDIR:-/tmp}/solar-vabcheck}
eng=${1:?usage: vabcheck.sh <engine> [crafts]}; crafts=${2:-}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vabcheck_modes.lua" "$SOL/tests/fixtures/check" <<'PY'
import sys, os
p, modes, fx = sys.argv[1], open(sys.argv[2]).read(), sys.argv[3]
crafts = open(os.path.join(fx, "crafts.lua")).read()
fix = []
for nm in ("bike125", "bike500", "bike_elec"):
    body = open(os.path.join(fx, nm + ".lua")).read()
    fix.append("VCK.FIX[%r] = (function()\n%s\nend)()\n" % (nm, body))
block = modes + "\nVCK.CRAFTS = (function()\n" + crafts + "\nend)()\nVCK.FIX = {}\n" + "".join(fix)
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + block + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "vabcheck" then VCK.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/vabshots
[ -n "$crafts" ] && export BENCH_STRS="(\"crafts\", \"$crafts\")${BENCH_STRS:+, $BENCH_STRS}"
SOLAR=$SOL WORK=$S bash $S/tools/bench.sh $eng vabcheck
echo "pictures: $S/proj/save/user/vabshots/"
