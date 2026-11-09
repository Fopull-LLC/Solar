#!/bin/bash
# gpusweep.sh — the GPU's time, pass by pass, for every graphics level at the
# scenes a player stands in (tools/perf/gpusweep_modes.lua), on a fresh save.
#
#   gpusweep.sh <engine> [TAG]
#   env: WORK LOCK SOLAR PATCHES as bench.sh;
#        RES      window size, e.g. 1920x1080 or 2560x1440 (default 1920x1080)
#        SCENES   e.g. "base,runway,meadow" | "forest,far,bigbase,vab" | "alien,alienfar"
#                 (alien*: the alien home, homeseed ALIENSEED, default 1)
#        PRESETS  default "Low,Medium,High,Ultra"
#        SECS     seconds measured per preset (default 8)
#        SCALE    every level at this render scale (e.g. 0.67), over the level's own
#        SHOTS=1  a 1920x1080 jpeg per scene and preset (in $WORK/results/<TAG>/shots)
#        COVER=1  a coverage grid + flora on/off pictures at High (gscover.py)
#        FOV      the settings' field of view (default 75, as Ty plays)
#        PALVAR   a terrain palette variant for the run: antitile0 | maps0 | hb0
#        TOGGLES  instead of the sweep: perfbench gpu mode at WHERE (walk|base)
#                 and GFX (default High) with these toggles (e.g. "fogvol0,flora0")
#        GSX      extra perfbench params, e.g. '("gpu_walk", 160.0)'
# Lines: GS RES (one per scene and preset), GSJSON (gstable.py makes the tables).
# OTHER engines running at the same time share the GPU and inflate its timers:
# $OUT/overlap.txt logs, every 2 s, the floptle play processes other than ours.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:?set WORK (a private folder)}
[ -e "$S/STOP" ] && { echo "stopped: $S/STOP"; exit 0; }
eng=${1:?usage: gpusweep.sh <engine> [TAG]}
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/gpusweep_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(a).read() for a in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "gpu" then run_gpu()',
              '    elseif MODE == "gpu" then run_gpu()\n    elseif MODE == "gpusweep" then GS.run()')
open(p, 'w').write(s)
PY
SC=${SCENES:-base,runway,meadow}
AL=""
case "$SC" in alien*) AL=", (\"homealien\", 1.0), (\"homeseed\", ${ALIENSEED:-1}.0)";; esac
TAG=${2:-gs-$(echo ${RES:-1920x1080} | tr x _)-$(echo $SC | tr , _)-$(date +%m%d-%H%M)}
OUT=$S/results/$TAG; mkdir -p $OUT
rm -rf $S/proj/save/user/gpusweep
# a palette variant: the scratch project's terrain folder becomes a copy for this run
PJ=$S/proj
mkdir -p $PJ
if [ -n "${PALVAR:-}" ]; then
  rm -rf $PJ/terrain; mkdir -p $PJ/terrain
  for f in $SOL/terrain/*; do
    case "$f" in
      *.palette)
        case "$PALVAR" in
          antitile0) sed -E 's/\|antitile=[0-9.]+/|antitile=0/g' "$f" ;;
          maps0) sed -E 's/\|(normal|orm|height)=[^|]*//g' "$f" ;;
          hb0) sed -E 's/\|heightblend=[0-9.]+/|heightblend=0/g' "$f" ;;
          *) cat "$f" ;;
        esac > $PJ/terrain/$(basename "$f") ;;
      *) ln -s "$f" $PJ/terrain/$(basename "$f") ;;
    esac
  done
  echo "palette variant $PALVAR: $(grep -c . $PJ/terrain/system.palette) slots"
else
  [ -L $PJ/terrain ] || rm -rf $PJ/terrain
fi
# the overlap log: other engines' play processes, every 2 s
( while :; do echo "$(date +%s) $(pgrep -a -x floptle | grep ' play ' | grep -vc "$PJ")"; sleep 2; done ) > $OUT/overlap.txt &
OVP=$!
if [ -n "${TOGGLES:-}" ]; then
  MODE=gpu
  BP="(\"gpusecs\", ${SECS:-6}.0), (\"fov\", ${FOV:-75}.0)${GSX:+, $GSX}"
  BS="(\"where\", \"${WHERE:-walk}\"), (\"gfx\", \"${GFX:-High}\"), (\"res\", \"${RES:-1920x1080}\"), (\"toggles\", \"$TOGGLES\")"
else
  MODE=gpusweep
  SCP=""; [ -n "${SCALE:-}" ] && SCP=", (\"gsscale\", $SCALE)"
  BP="(\"gssecs\", ${SECS:-8}.0), (\"gpusecs\", ${SECS:-6}.0), (\"shots\", ${SHOTS:-0}.0), (\"gsshots\", ${GSSHOTS:-0}.0), (\"coverage\", ${COVER:-0}.0), (\"fov\", ${FOV:-75}.0)$SCP$AL${GSX:+, $GSX}"
  [ -n "${GSV:-}" ] && GT=", (\"gsvariants\", \"$GSV\"), (\"gfx\", \"${GFX:-High}\")"
  [ -n "${GSV:-}" ] || GT=""; [ -n "${GSTOG:-}" ] && GT=", (\"gstoggles\", \"1\"), (\"toggles\", \"$GSTOG\"), (\"gfx\", \"${GFX:-High}\")"
  BS="(\"scenes\", \"$SC\")$GT, (\"presets\", \"${PRESETS:-Low,Medium,High,Ultra}\"), (\"res\", \"${RES:-1920x1080}\"), (\"tag\", \"$TAG\")"
fi
if [ "${EXCL:-0}" = 1 ]; then
  # the WHOLE GPU for a clean timing run: hold slot A here, bench.sh takes slot B
  # (LOCKPOOL=0: exactly that slot); both released when the run ends, then a pause
  # so the other agents get their turn before our next exclusive run
  echo "exclusive: waiting for both engine slots $(date +%T)"
  command flock /mnt/disks/3tb/.floptle-shared/engine.lock env LOCKPOOL=0 LOCK=/mnt/disks/3tb/.floptle-shared/engine2.lock \
    SOLAR=$SOL WORK=$S TAG=$TAG TMO=${TMO:-480} BENCH_PARAMS="$BP" BENCH_STRS="$BS" bash $S/tools/bench.sh $eng $MODE > $S/gs-last.out 2>&1
  echo "exclusive: released $(date +%T)"
  sleep ${EXCL_PAUSE:-60}
else
  SOLAR=$SOL WORK=$S TAG=$TAG TMO=${TMO:-480} BENCH_PARAMS="$BP" BENCH_STRS="$BS" bash $S/tools/bench.sh $eng $MODE > $S/gs-last.out 2>&1
fi
kill $OVP 2>/dev/null
[ -n "${PALVAR:-}" ] && { rm -rf $PJ/terrain; ln -sfn $SOL/terrain $PJ/terrain; }
grep -a 'GS \|GPU \[\|GPU DELTA\|ERROR\|TIMEOUT\|display mode\|GPU state at' $OUT/$MODE.log | cut -c1-460
echo "exit $(cat $OUT/$MODE.exit 2>/dev/null); load $(cat $OUT/$MODE.uptime 2>/dev/null | sed 's/.*load average: //' | tr '\n' ' '); other engines running in $(awk '$2>0' $OUT/overlap.txt | wc -l) of $(wc -l < $OUT/overlap.txt) samples"
mkdir -p $OUT/shots; cp $S/proj/save/user/gpusweep/* $OUT/shots/ 2>/dev/null
grep -a 'GSJSON' $OUT/$MODE.log | sed 's/.*GSJSON //' > $OUT/gs.jsonl
grep -a 'GSCOVER' $OUT/$MODE.log | sed 's/.*GSCOVER //' > $OUT/cover.txt
rm -rf $S/proj/save/user/gpusweep
echo "results: $OUT ($(wc -l < $OUT/gs.jsonl) measurements)"
