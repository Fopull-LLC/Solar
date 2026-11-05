#!/bin/bash
# servoprobe.sh — wheels on servo hinges (servoprobe_modes.lua: sservo).
#
#   servoprobe.sh <engine> [rig ...]       (rigs: none arm direct elec far; default: none arm)
#   env: BIKE   the craft file (default ~/.local/share/solar/user/library/slot1/untitled.json,
#               copied, never written)
#        BENCH_PARAMS e.g. '("ang", 25.0), ("vt", 8.0)'
#        WORK TMO as bench.sh; LOCK defaults to the shared engine lock
#        MODE   sservo (default), smid (servomid_modes.lua: pext curl seatp engs skid loader trailer hop nest loop spin)
#               or sair (servoair_modes.lua: gimbal tilt plane stage keep)
#               or sjf (jointframe_modes.lua: frames — a seat and a docking port on hinges)
#        SCRIPTS another scripts/ to run (an A/B against the tree's)
# Builds a snapshot of the Solar tree under $WORK/solar (assets linked; scripts,
# scenes, prefabs, project.ron copied), splices ivaprobe, verifyprobe,
# jumpprobe and servoprobe modes into a copy of perfbench.lua and runs
# bench.sh's sservo mode once per rig. `SP T|R` lines, `VP PASS|FAIL`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-servo}
eng=${1:?usage: servoprobe.sh <engine> [rigs]}; shift
mkdir -p $S/tools $S/solar $S/proj/save/user
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) [ -e $SN/$d ] || ln -s $SOL/$d $SN/$d ;; esac
done
[ -e $SN/tools ] || ln -s $SOL/tools $SN/tools
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r ${SCRIPTS:-$SOL/scripts} $SN/scripts; cp -r $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
BIKE=${BIKE:-$HOME/.local/share/solar/user/library/slot1/untitled.json}
cp "$BIKE" $S/proj/save/user/probe_dirtbike.json || exit 2
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" "$HERE/verifyprobe_modes.lua" "$HERE/jumpprobe_modes.lua" "$HERE/servoprobe_modes.lua" "$HERE/servomid_modes.lua" "$HERE/servoair_modes.lua" "$HERE/jointframe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "\n".join(open(f).read() for f in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + "do\n" + m + "\nend\n" + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif SP_RUN[MODE] then SP_RUN[MODE]()')
s = s.replace('function fixedUpdate(node, dt)\n', 'function fixedUpdate(node, dt)\n  if JP_TICK then JP_TICK(dt) end\n', 1)
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
rc=0
BP0=${BENCH_STRS:-}
for rig in ${*:-none arm}; do
  BENCH_STRS="(\"rig\", \"$rig\")${BP0:+, $BP0}" TAG=servo-$rig-$(date +%m%d-%H%M%S) LOCK=${LOCK:-/mnt/disks/3tb/.floptle-shared/engine.lock} \
    TMO=${TMO:-330} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${MODE:-sservo} > $S/last-$rig.txt 2>&1 || rc=$?
  log=$(ls -td $S/results/servo-$rig-*/ | head -1)${MODE:-sservo}.log
  echo "== rig $rig ($log)"
  grep -a "SP \|SM \|SA \|JF \|VP \|JP ACC\|JP GAS\|rover:\|ERROR\|error" $log 2>/dev/null | grep -v "SP T \|ALSA" | cut -c1-400
done
rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
exit $rc
