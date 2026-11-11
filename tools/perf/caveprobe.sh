#!/bin/bash
# caveprobe.sh — the cave kinds and their dressing (worlds W4): find a natural
# cave on a fresh save's home world, stand in it, read the kind, count the
# formations and marks, time cave_field + underground, photograph it with the
# helmet lamps, the torch, a flare and the HUD; with sweep=1 the same cave as
# each of the eight kinds.
#
#   caveprobe.sh <engine> <seed> [seed ...]
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh;
#        BENCH_PARAMS extra params, e.g. '("sweep", 1.0), ("carve", 1.0), ("columns", 30.0)'
#        BENCH_STRS='("gfx", "High"), ("kinds", "salt,vent")'   graphics level; the sweep's kinds (default all)
#        SHOTS=<dir>                    where the pictures go (default $WORK/shots/<TAG>)
#
# Splices caveprobe_modes.lua into a copy of perfbench.lua (before its main)
# and runs one `cave` mode per seed through bench.sh (which takes a lock from
# the pool, silent). A fresh save in the scratch project's slot 13, deleted
# after each run. Seeds whose home worlds' principal kinds differ (version 5):
# 1 karst (coral limestone), 13 lava tube (flood basalt), 9 chasm (granite).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-cave}
eng=${1:?usage: caveprobe.sh <engine> <seed> [seed ...]}; shift
SEEDS=${*:-1 13 9}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/caveprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "cave" then CV.run()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TAG0=${TAG:-cave-$(date +%m%d-%H%M)}
OUTS=${SHOTS:-$S/shots/$TAG0}; mkdir -p $OUTS
rc=0
for seed in $SEEDS; do
  rm -rf $S/proj/save/user/caveshots
  TAG=$TAG0-s$seed TMO=${TMO:-420} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S \
    BENCH_PARAMS="(\"seed\", $seed.0)${BENCH_PARAMS:+, $BENCH_PARAMS}" bash $S/tools/bench.sh $eng cave
  rc=$((rc + $?))
  grep -a "PB .*CV \|PB .*ERROR\|PB .*TIMEOUT\|cave_field\|cave_flares\|cave_kinds" $S/results/$TAG0-s$seed/cave.log 2>/dev/null | grep -v "^.*BENCHJSON" | cut -c1-600
  cp $S/proj/save/user/caveshots/*.png $OUTS/ 2>/dev/null
  rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
done
echo "pictures: $OUTS ($(ls $OUTS | wc -l))"
exit $rc
