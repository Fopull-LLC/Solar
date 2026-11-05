#!/bin/bash
# fairprobe.sh — the fairing redesign (deep-space proposal §6, E1–E6): the
# VAB's handles, FIT, the menu, three pieces, an open top, the stage card; a
# launch with the boosters on, the fairing fired: the unlatch, the hinge and
# the release in pictures, and every piece's box against the payload and the
# boosters for 6 s.
#
#   fairprobe.sh <engine> [modes]     modes: fairvab fairfly (default both)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh, e.g.
#        BENCH_PARAMS='("pieces", 3.0)'   (fairfly with a three-piece shell)
#
# Splices vfxprobe_modes.lua (its cameras) and fairprobe_modes.lua into a copy
# of perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/fairshots/. Look for `FP PASS|FAIL` and `FP RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-fair}
eng=${1:?usage: fairprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/fairprobe_modes.lua" <<'PY'
import sys
p, m1, m2 = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m1 + m2 + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "fairvab" then FP.run_vab()\n'
              '    elseif MODE == "fairfly" then FP.run_fly()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/fairshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-fairvab fairfly}
