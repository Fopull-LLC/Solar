#!/bin/bash
# fleetprobe.sh — what each idle craft in the world costs a frame (the 2026-11 perf pass)
#
#   fleetprobe.sh <engine>
#   env: WORK LOCK SOLAR TAG PATCHES ENVX as bench.sh; BENCH_PARAMS extra perfbench params
#        (fleet_settle, fleet_secs, fleet_fly)
#
# One `floptle play` (bench.sh, one lock hold) on a fresh save: a rover rolled
# out and left on the runway, then 4, 9 and 19 copies written into the fleet
# (parked near the crew or coasting in orbit) and rebuilt by flight_ops.
# fleetprobe_modes.lua is spliced into a copy of perfbench.lua; the repo's
# perfbench is untouched. Look for `FLEET` lines; `FLEETJSON` rows go to
# $WORK/results/<TAG>/fleet.jsonl.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-fleet}
eng=${1:?usage: fleetprobe.sh <engine>}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/fleetprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('defaults = { slot = 13,',
              'defaults = { fleet_settle = 15, fleet_secs = 20, fleet_fly = 1,\n             slot = 13,')
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "fleet" then run_fleet()')
open(p, 'w').write(s)
PY
TAG=${TAG:-fleet-$(date +%m%d-%H%M)}
OUT=$S/results/$TAG
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TAG=$TAG TMO=${TMO:-345} bash $S/tools/bench.sh $eng fleet > /dev/null
grep -a "FLEET \|ERROR\|TIMEOUT\|revert\|fleet:" $OUT/fleet.log | cut -c1-600
grep -a "FLEETJSON " $OUT/fleet.log | sed "s/.*FLEETJSON //" > $OUT/fleet.jsonl
echo "exit $(cat $OUT/fleet.exit); load $(head -1 $OUT/fleet.uptime | sed 's/.*load average: //')"
