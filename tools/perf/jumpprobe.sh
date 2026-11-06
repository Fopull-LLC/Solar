#!/bin/bash
# jumpprobe.sh — the player's bike over kickers, its brakes and its Floodlight at night
# (jumpprobe_modes.lua: vjump vride vbrake vlight vhill vlook vbump vload vnat).
#
#   jumpprobe.sh <engine> [modes]          (default: vjump)
#   env: BIKE   the craft file (default ~/.local/share/solar/user/library/slot1/bike1.json)
#        BENCH_PARAMS e.g. '("speeds", "8,12,15"), ("bigv", 12.0)' — strs need the
#                 scene's params; numbers: kg (kicker grade), bg (the big one's), night, nwarp
#        WORK LOCK TMO as bench.sh
# Builds a snapshot of the Solar tree under $WORK/solar (assets linked; scripts,
# scenes, prefabs, project.ron copied), splices ivaprobe, verifyprobe and
# jumpprobe modes into a copy of perfbench.lua and runs bench.sh on it.
# `JP T|R|B` lines, `VP PASS|FAIL`, pictures in $WORK/proj/save/user/vshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-jump}
eng=${1:?usage: jumpprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/solar $S/proj/save/user
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) if [ -L "$SN/$d" ] || [ ! -e "$SN/$d" ]; then ln -sfn "$SOL/$d" "$SN/$d"; fi ;; esac
done
if [ -L "$SN/tools" ] || [ ! -e "$SN/tools" ]; then ln -sfn "$SOL/tools" "$SN/tools"; fi
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
BIKE=${BIKE:-$HOME/.local/share/solar/user/library/slot1/bike1.json}
cp "$BIKE" $S/proj/save/user/probe_dirtbike.json || exit 2
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" "$HERE/verifyprobe_modes.lua" "$HERE/jumpprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "\n".join(open(f).read() for f in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + "do\n" + m + "\nJP_RUN = { vjump = run_vjump, vride = run_vride, vbrake = run_vbrake, vlight = run_vlight, vhill = run_vhill, vlook = run_vlook, vbump = run_vbump, vload = run_vload, vnat = run_vnat }\nend\n" + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif JP_RUN[MODE] then JP_RUN[MODE]()')
# (a mode's own tick: JP_TICK(dt) in perfbench's fixedUpdate, vbump's hold)
s = s.replace('function fixedUpdate(node, dt)\n', 'function fixedUpdate(node, dt)\n  if JP_TICK then JP_TICK(dt) end\n', 1)
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-330} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${*:-vjump}
rc=$?
for m in ${*:-vjump}; do grep -a "JP LOAD\|JP SAG\|JP MASS\|JP BUMP\|JP reset\|JP whoops\|JP ground pass\|JP GAS\|JP accel\|JP LOOK\|JP AT\|JP H \|JP HILL\|JP NAT\|JP N \|JP nat\|JP ACC\|JP hill\|JP R\|JP RIDE\|JP B\|JP kicker\|JP bike\|JP beam\|JP lamp\|JP lights\|JP night\|JP sun\|JP fell\|VP \|moto:" $S/results/*/$m.log 2>/dev/null | cut -c1-420; done
rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
exit $rc
