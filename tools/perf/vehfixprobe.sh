#!/bin/bash
# vehfixprobe.sh — playtest 2026-11-12b's vehicle and physics jank
# (vehfixprobe_modes.lua): the bike let go of at speed, run-jumps on flat
# ground, crew walking into a piloted rover, the repair bay, ropes and
# cave-in rocks.
#
#   vehfixprobe.sh <engine> [modes]
#     modes: vcoast vcoastslope runjump crewshove bayfix ropekit rocks
#   env: BIKE   the craft file (default ~/.local/share/solar/user/library/slot1/bike_1.json)
#        WORK LOCK TMO BENCH_PARAMS as bench.sh
# Builds a snapshot of the Solar tree under $WORK/solar (assets linked; scripts,
# scenes, prefabs, project.ron copied), splices ivaprobe, verifyprobe,
# jumpprobe and vehfixprobe modes into a copy of perfbench.lua and runs
# bench.sh on it. `VF ` lines, `VP PASS|FAIL`; pictures in
# $WORK/proj/save/user/vehfix/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:?WORK}
eng=${1:?usage: vehfixprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/solar $S/proj/save/user
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|.claude|tools) ;; *) if [ -L "$SN/$d" ] || [ ! -e "$SN/$d" ]; then ln -sfn "$SOL/$d" "$SN/$d"; fi ;; esac
done
if [ -L "$SN/tools" ] || [ ! -e "$SN/tools" ]; then ln -sfn "$SOL/tools" "$SN/tools"; fi
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
BIKE=${BIKE:-$HOME/.local/share/solar/user/library/slot1/bike_1.json}
cp "$BIKE" $S/proj/save/user/probe_dirtbike.json || exit 2
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" "$HERE/verifyprobe_modes.lua" "$HERE/jumpprobe_modes.lua" "$HERE/vehfixprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "\n".join(open(f).read() for f in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + "do\n" + m + "\nend\n" + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif VF_RUN[MODE] then VF_RUN[MODE]()')
s = s.replace('function fixedUpdate(node, dt)\n', 'function fixedUpdate(node, dt)\n  if JP_TICK then JP_TICK(dt) end\n  if VF_TICK then VF_TICK(dt) end\n', 1)
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-340} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${*:-vcoast}
rc=$?
for m in ${*:-vcoast}; do grep -a "VF \|VP \|JP reset\|JP bike\|ERROR\|error\|crew: " $(ls -td $S/results/*/ | head -1)$m.log 2>/dev/null | cut -c1-500 | tail -120; done
rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
exit $rc
