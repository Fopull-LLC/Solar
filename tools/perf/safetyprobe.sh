#!/bin/bash
# safetyprobe.sh — the 2026-11-04 playtest: revert after a crash (sandbox),
# CREW SAFETY "rescue" (hurt and brought home, not invincible), FUNDS in the VAB.
#
#   safetyprobe.sh <engine> [modes]   modes: crashrevert rescuecrash vabfunds (default: all)
#   env: WORK LOCK TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#
# Builds a snapshot of the Solar tree under $WORK/solar (assets linked; scripts,
# scenes, prefabs, project.ron copied), splices safetyprobe_modes.lua into a copy
# of perfbench.lua (before its main) and runs bench.sh on that snapshot. Look for
# `SF PASS|FAIL` and `SF RESULT`; pictures land in $WORK/proj/save/user/sfshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-safety}
eng=${1:?usage: safetyprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/solar
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) if [ -L "$SN/$d" ] || [ ! -e "$SN/$d" ]; then ln -sfn "$SOL/$d" "$SN/$d"; fi ;; esac
done
if [ -L "$SN/tools" ] || [ ! -e "$SN/tools" ]; then ln -sfn "$SOL/tools" "$SN/tools"; fi
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/safetyprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
modes = ('crashrevert', 'rescuecrash', 'vabfunds')
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()' + ''.join('\n    elseif MODE == "%s" then run_%s()' % (m, m) for m in modes))
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-300} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${*:-crashrevert rescuecrash vabfunds}
