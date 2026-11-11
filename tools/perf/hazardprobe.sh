#!/bin/bash
# hazardprobe.sh — the cave hazards and rewards (worlds W5): on a fresh save's
# home world, find a natural cave and walk into a CO2 sump (the suit's reading,
# the helmet), light a methane pocket with the laser, bring down a rockfall
# (photographed), take a dose by a pitchblende seam, dress the cave as a
# sulfur vent, and send the crew to a mine head's shaft and a sink camp to
# loot their caches. See hazardprobe_modes.lua.
#
#   hazardprobe.sh <engine> <seed> [seed ...]
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh;
#        BENCH_STRS='("only", "fall")'   one part only (air, ch4, fall, dose, vent, ruins)
#        SHOTS=<dir>                    where the pictures go (default $WORK/shots/<TAG>)
#
# Splices caveprobe_modes.lua and hazardprobe_modes.lua into a copy of
# perfbench.lua (before its main) and runs one `hazard` mode per seed through
# bench.sh (a lock from the pool, silent). A fresh save in the scratch
# project's slot 13, deleted after each run.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-hazard}
eng=${1:?usage: hazardprobe.sh <engine> <seed> [seed ...]}; shift
SEEDS=${*:-1}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/caveprobe_modes.lua" "$HERE/hazardprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = open(sys.argv[2]).read() + "\n" + open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "hazard" then HZ.run()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TAG0=${TAG:-hazard-$(date +%m%d-%H%M)}
OUTS=${SHOTS:-$S/shots/$TAG0}; mkdir -p $OUTS
rc=0
for seed in $SEEDS; do
  rm -rf $S/proj/save/user/caveshots
  TAG=$TAG0-s$seed TMO=${TMO:-480} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S \
    BENCH_PARAMS="(\"seed\", $seed.0)${BENCH_PARAMS:+, $BENCH_PARAMS}" bash $S/tools/bench.sh $eng hazard
  rc=$((rc + $?))
  grep -a "PB .*HZ \|PB .*CV \|PB .*ERROR\|PB .*TIMEOUT\|cave_hazards\|ruins:" $S/results/$TAG0-s$seed/hazard.log 2>/dev/null | grep -v "BENCHJSON" | cut -c1-700
  cp $S/proj/save/user/caveshots/*.png $OUTS/ 2>/dev/null
  rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
done
echo "pictures: $OUTS ($(ls $OUTS | wc -l))"
exit $rc
