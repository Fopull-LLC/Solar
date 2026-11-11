#!/bin/bash
# ruinprobe.sh — expansion X8 (abandoned bases) in the engine
# (docs/base-building.md §26, docs/tracking-station.md §6.2).
# A home-world site moved to flat lit ground on the far side; the crew walked
# in (stamp, find); the five kinds pictured; the frame with no ruin, while
# one streams in and with the power hall standing; far: unstamped / unloaded;
# scanner and telescope discovery; the station's ruin entry and card; a crate,
# the core, the claim, restore, repair; the claimed base's card.
#
#   ruinprobe.sh <engine> [modes]   modes: ruins (default), near (progression R1:
#        the ruin near home on a fresh career; BENCH_PARAMS='("nearold", 1.0)' with USERSAVE=1
#        and SOLAR=<a copy holding a probe save> for an old save)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (PATCHES=funds.patch);
#        BENCH_PARAMS='("rkind", "camp")' to pick the kind of the main flow
#
# Splices vfxprobe_modes.lua and ruinprobe_modes.lua into a copy of
# perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/ruinshots/. Look for `RN PASS|FAIL` and `RN RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-ruins}
eng=${1:?usage: ruinprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/ruinprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "ruins" then RN.run()\n    elseif MODE == "near" then RN.near()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/ruinshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-420} bash $S/tools/bench.sh $eng ${*:-ruins}
