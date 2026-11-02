#!/bin/bash
# splitprobe.sh — the control mode of crafts made of crafts (2026-11: "a ship
# that deploys a rover ... a jet that detaches a ship?"): sections, per-section
# choices, and each piece's own mode after a split.
#
#   splitprobe.sh <engine> [modes]   modes: splitrover splitjet (default both)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 360 s a mode)
#
# Splices ctrlprobe_modes.lua (the CP helpers) and splitprobe_modes.lua into a
# copy of perfbench.lua (before its main) and runs that copy through bench.sh.
# Look for `CP PASS|FAIL` and `CP RESULT`; pictures in $WORK/proj/save/user/ctrlshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-split}
eng=${1:?usage: splitprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ctrlprobe_modes.lua" "$HERE/splitprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = open(sys.argv[2]).read() + "\n" + open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "splitrover" then SP.run_rover()\n    elseif MODE == "splitjet" then SP.run_jet()')
open(p, 'w').write(s)
PY
TMO=${TMO:-360} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-splitrover splitjet}
