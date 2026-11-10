#!/bin/bash
# veinlook.sh — every ore laid as a seam with its outcrops and float, pictured
# at 5, 20 and 60 m, and the dosimeter over a real uranite vein (worlds W3,
# veinlook_modes.lua).
#
#   veinlook.sh <engine>
#   env: WORK LOCK TAG PATCHES as bench.sh (TMO defaults to 340 s);
#        BENCH_STRS '("ores", "iron,copper,…")' to choose the ores (read as params.ores).
#
# Builds a snapshot of the Solar tree under $WORK/solar (assets linked; scripts,
# scenes, prefabs, project.ron copied), splices ivaprobe, verifyprobe, fellprobe,
# mineprobe and veinlook modes into a copy of perfbench.lua (before its main)
# and runs bench.sh on that snapshot (a fresh save in its own scratch project).
# Look for `VP PASS|FAIL` and `VP RESULT`; pictures land in
# $WORK/proj/save/user/vshots/veinlook_*.png.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-veinlook}
eng=${1:?usage: veinlook.sh <engine>}; shift
mkdir -p $S/tools $S/solar $S/proj/save/user
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) if [ -L "$SN/$d" ] || [ ! -e "$SN/$d" ]; then ln -sfn "$SOL/$d" "$SN/$d"; fi ;; esac
done
if [ -L "$SN/tools" ] || [ ! -e "$SN/tools" ]; then ln -sfn "$SOL/tools" "$SN/tools"; fi
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
[ -f $HERE/lockpool.sh ] && cp $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" "$HERE/verifyprobe_modes.lua" "$HERE/fellprobe_modes.lua" "$HERE/mineprobe_modes.lua" "$HERE/veinlook_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "\n".join(open(f).read() for f in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "veinlook" then run_veinlook()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-340} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng veinlook
