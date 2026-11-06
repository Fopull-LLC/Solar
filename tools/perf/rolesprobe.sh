#!/bin/bash
# rolesprobe.sh — deep-space step 9 (J4 the Pilot, J6 the Engineer): the SAS
# gate without a Pilot and with one, an Engineer's repair against a
# Scientist's, the level-2 wear tag, and the cable / wall / kit gates.
#
#   rolesprobe.sh <engine> [modes]       modes: roles9 (default)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO default 420 s)
#
# Splices crewprobe_modes.lua (CP.*, cp_launch) and rolesprobe_modes.lua into
# a copy of perfbench.lua; the repo's perfbench is untouched. Look for
# `CP PASS|FAIL` and `CP RESULT roles9`. Pictures land in
# $WORK/proj/save/user/crewshots/roles9_*.png.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-roles}
eng=${1:?usage: rolesprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/crewprobe_modes.lua" "$HERE/rolesprobe_modes.lua" <<'PY'
import sys
p, m1, m2 = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m1 + m2 + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "roles9" then RP.run()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
rm -rf $S/proj/save/user/crewshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-420} bash $S/tools/bench.sh $eng ${*:-roles9}
