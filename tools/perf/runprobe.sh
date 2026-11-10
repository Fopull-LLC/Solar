#!/bin/bash
# runprobe.sh — expansion X3 ("Runs I") in the engine: fly a cargo flight
# from a Build Stand, have it refused (ore dug by hand on a probe run) and
# then accepted (from the Depot's supply crate), Automate it from the stand's
# menu, and watch it run: the dwell on the stand, the legs, cycles under
# warp, the Tracking Station's RUNS entry, card and NEXT events, the cost,
# pause, save and reload, cancel (docs/base-building.md §21).
#
#   runprobe.sh <engine> [modes]   modes: runs (default)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (PATCHES=funds.patch: the
#        rover and the stand cost more than a fresh save's $500)
#
# Splices vfxprobe_modes.lua (its freecam), buildkitprobe_modes.lua and
# standeditprobe_modes.lua (the stand helpers) and runprobe_modes.lua into a
# copy of perfbench.lua; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/runshots/. Look for `RN PASS|FAIL` and `RN RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-runs}
eng=${1:?usage: runprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/standeditprobe_modes.lua" "$HERE/runprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() for x in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "runs" then RN.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/runshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-600} bash $S/tools/bench.sh $eng ${*:-runs}
