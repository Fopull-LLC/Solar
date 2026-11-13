#!/bin/bash
# cpuprobe.sh — Ty's 2026-11-12b playtest: the CPU pegged on all cores in long
# sessions (bike exploring, the ruins and repairs), and the run's jitter at
# the base (cpuprobe_modes.lua).
#
#   cpuprobe.sh <engine> [mode]     modes: bikesoak idle sprint (default bikesoak)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh;
#        USERSRC=dir  a player's data dir (…/save/slot1.ron and …/saves/slot1),
#                     COPIED into the scratch project and booted as slot 1
#                     (the original is only read); unset: a new save
#        SECS (cp_secs, default 240), EVERY (s a row, default 10)
# A thread sampler (thrmon.py) runs beside the engine: $WORK/results/<TAG>/thr.jsonl
# (per-thread-name CPU %, threads, RSS, load). RT rows: SOAKJSON in the log.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:?WORK}
eng=${1:?usage: cpuprobe.sh <engine> [mode]}; shift
MODE=${1:-bikesoak}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $HERE/thrmon.py $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/soakprobe_modes.lua" "$HERE/cpuprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + open(sys.argv[2]).read() + "\n" + open(sys.argv[3]).read() + "\n" + s[i:]
s = s.replace('defaults = { slot = 13,',
              'defaults = { cp_secs = 240, cp_frames = 0, cp_heads = 6, cp_runsecs = 4, soak_route = 0, soak_walksecs = 360, soak_drivesecs = 180, soak_walk2 = 90, soak_secs = 280, soak_every = 10, soak_walk = 14, soak_digs = 6, soak_warp = 8, soak_fly = 10, soak_rover = 2, soak_drive = 14, soak_park = 0, soak_save = 1, soak_menu = 3, soak_seg = 0,\n             slot = 13,')
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif CP[MODE] then CP[MODE]()')
s = s.replace('function update(node, dt)\n  measure()', 'function update(node, dt)\n  measure()\n  if soak_tick then soak_tick() end')
s = s.replace('        xt, xtf = (xt or 0) + (f.ticks or 0), xtf + 1', '        xt, xtf = (xt or 0) + (f.ticks or 0), xtf + 1\n        CP_DROP = (CP_DROP or 0) + (f.ticksDropped or 0)')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TAG=${TAG:-cpu-$MODE-$(date +%m%d-%H%M)}
OUT=$S/results/$TAG; mkdir -p $OUT
BP="(\"cp_secs\", ${SECS:-240}.0), (\"soak_every\", ${EVERY:-10}.0), (\"pb_frames\", 3.0)"
if [ -n "${USERSRC:-}" ]; then
  mkdir -p $S/proj/save $S/proj/saves
  rm -f $S/proj/save/slot1.ron; rm -rf $S/proj/saves/slot1
  cp "$USERSRC/save/slot1.ron" $S/proj/save/slot1.ron
  cp -r "$USERSRC/saves/slot1" $S/proj/saves/slot1
  BP="(\"usersave\", 1.0), (\"slot\", 1.0), $BP"
fi
python3 $S/tools/thrmon.py $S/proj $OUT/thr.jsonl ${PERIOD:-5} &
MON=$!
TMO=${TMO:-$(( ${SECS:-240} + 200 ))} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TAG=$TAG \
  BENCH_PARAMS="$BP${BENCH_PARAMS:+, $BENCH_PARAMS}" bash $S/tools/bench.sh $eng $MODE > $OUT/bench.out 2>&1
rc=$?
sleep 6; kill $MON 2>/dev/null
grep -a "PB .*\(CP \|RT w[0-9]* t=\|ERROR\|error\)" $OUT/$MODE.log | grep -v "CP F " | cut -c1-330 | tail -60
python3 $HERE/cputable.py $OUT 2>/dev/null
rm -f $S/proj/save/slot1.ron; rm -rf $S/proj/saves/slot1
exit $rc
