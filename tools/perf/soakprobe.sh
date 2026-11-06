#!/bin/bash
# soakprobe.sh — does a long session get slower? (the 2026-11 perf pass)
#
#   soakprobe.sh <engine> [segments]       segments: how many plays (default 3)
#   env: WORK LOCK SOLAR TAG PATCHES ENVX as bench.sh; SECS (seconds of loop a
#        segment, default 280: each play stays under the 6-minute lock rule
#        with the boot), BENCH_PARAMS extra perfbench params
#
# Each segment is one `floptle play` (bench.sh, so one lock hold each). The
# first makes a fresh save in slot 14 (new-save path, as perfbench boot());
# the rest CONTINUE that save, so what a save carries across sessions (the
# fleet, comms, cuts) grows segment to segment, and each segment shows what
# grows inside one run. soakprobe_modes.lua is spliced into a copy of
# perfbench.lua; the repo's perfbench is untouched. Look for `SOAK` lines;
# `SOAKJSON` rows go to $WORK/results/<TAG>/soak.jsonl and soaktable.py
# tabulates them. The probe's slot 14 is deleted at the end (KEEPSAVE=1 keeps it).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-soak}
eng=${1:?usage: soakprobe.sh <engine> [segments]}; NSEG=${2:-3}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/soakprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('defaults = { slot = 13,',
              'defaults = { soak_route = 0, soak_walksecs = 360, soak_drivesecs = 180, soak_walk2 = 90, soak_secs = 280, soak_every = 60, soak_walk = 14, soak_digs = 6, soak_warp = 8, soak_fly = 10, soak_rover = 2, soak_drive = 14, soak_park = 0, soak_save = 1, soak_menu = 3, soak_seg = 0,\n             slot = 13,')
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "soak" then run_soak()')
s = s.replace('function update(node, dt)\n  measure()', 'function update(node, dt)\n  measure()\n  if soak_tick then soak_tick() end')
open(p, 'w').write(s)
PY
TAG=${TAG:-soak-$(date +%m%d-%H%M)}
SECS=${SECS:-280}
# ROUTE=1: the route soak (one long play: walk WALK s, drive DRIVE s, walk
# WALK2 s on a NEW save, a sample every EVERY (10) s; soakprobe_modes.lua
# run_route). HOMEW=alien starts on an alien home world (HOMESEED, default 1).
if [ -n "${ROUTE:-}" ]; then
  NSEG=1
  RP="(\"soak_route\", 1.0), (\"pb_frames\", 3.0), (\"soak_every\", ${EVERY:-10}.0), (\"soak_walksecs\", ${WALK:-360}.0), (\"soak_drivesecs\", ${DRIVE:-180}.0), (\"soak_walk2\", ${WALK2:-90}.0)"
  # RETURN=1: walk back to where the walk began and stand STAND (25) s there
  [ -n "${RETURN:-}" ] && RP="$RP, (\"soak_return\", 1.0), (\"soak_stand\", ${STAND:-25}.0)"
  [ "${HOMEW:-}" = alien ] && RP="$RP, (\"homealien\", 1.0), (\"homeseed\", ${HOMESEED:-1}.0)"
  BENCH_PARAMS="$RP${BENCH_PARAMS:+, $BENCH_PARAMS}"
  # WEATHER=rain (any weather.force kind) holds that weather; unset it runs free
  [ -n "${WEATHER:-}" ] && export BENCH_STRS="(\"soak_weather\", \"$WEATHER\")${BENCH_STRS:+, $BENCH_STRS}"
  WK=${WALK:-360}; [ -n "${RETURN:-}" ] && WK=$(( WK * 5 / 2 + ${STAND:-25} ))
  TMO=${TMO:-$(( WK + ${DRIVE:-180} + ${WALK2:-90} + 330 ))}
fi
OUT=$S/results/$TAG
for k in $(seq 0 $((NSEG - 1))); do
  if [ $k -eq 0 ]; then CONT=""; rm -f $S/proj/save/user/settings.json; else CONT='("usersave", 1.0), '; fi
  SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TAG=$TAG TMO=${TMO:-345} \
    BENCH_PARAMS="${CONT}(\"slot\", 14.0), (\"soak_seg\", $k.0), (\"soak_secs\", $SECS.0)${BENCH_PARAMS:+, $BENCH_PARAMS}" \
    bash $S/tools/bench.sh $eng soak > /dev/null
  cp $OUT/soak.log $OUT/soak_seg$k.log
  grep -a "SOAK \|RT \|RESULT \[soak_w.*\] p50\|ERROR\|TIMEOUT" $OUT/soak.log | grep -v "SOAK w.. scripts\|SOAK w.. buckets" | cut -c1-400
  grep -a "SOAKJSON " $OUT/soak.log | sed "s/.*SOAKJSON {/{\"seg\": $k, /" >> $OUT/soak.jsonl
  echo "segment $k: exit $(cat $OUT/soak.exit); load $(head -1 $OUT/soak.uptime | sed 's/.*load average: //')"
  sleep 5
done
[ -n "${KEEPSAVE:-}" ] || { rm -f $S/proj/save/slot14.ron; rm -rf $S/proj/saves/slot14; }
if [ -n "${ROUTE:-}" ]; then python3 $HERE/rttable.py $OUT/soak.jsonl | tee $OUT/rttable.md; else python3 $HERE/soaktable.py $OUT/soak.jsonl | tee $OUT/soaktable.md; fi
