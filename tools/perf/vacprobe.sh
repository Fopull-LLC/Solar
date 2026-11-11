#!/bin/bash
# vacprobe.sh — Hard Vacuum's freighter in the engine (scenarios/hard_vacuum):
# the craft built in the VAB from the records in vacprobe_modes.lua and written
# as user://ansel.json (copy it to scenarios/hard_vacuum/ansel.json), then
# flown to orbit and its cabin modules, doors and reactor read back.
#
#   vacprobe.sh <engine> [modes]   modes: anselbuild
#   env: WORK LOCK TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#
# It snapshots the Solar tree under $WORK/solar (assets linked; scripts, scenes,
# prefabs, project.ron copied), splices vacprobe_modes.lua into a copy of
# perfbench.lua and runs bench.sh on it. Look for `VP PASS|FAIL` and `VP RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-vac}
eng=${1:?usage: vacprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/solar
# ── the snapshot ──
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) if [ -L "$SN/$d" ] || [ ! -e "$SN/$d" ]; then ln -sfn "$SOL/$d" "$SN/$d"; fi ;; esac
done
if [ -L "$SN/tools" ] || [ ! -e "$SN/tools" ]; then ln -sfn "$SOL/tools" "$SN/tools"; fi
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vacprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
modes = ('anselbuild',)
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()' + ''.join('\n    elseif MODE == "%s" then run_%s()' % (m, m) for m in modes))
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-300} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${*:-anselbuild}
rc=$?
exit $rc
