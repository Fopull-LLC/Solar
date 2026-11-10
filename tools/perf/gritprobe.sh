#!/bin/bash
# gritprobe.sh — the gritty-realism pass (2026-11-10): the Terrain Laser's dig,
# a cave, alien skies and an airless night, a fog bank. Pictures and costs.
#
#   gritprobe.sh <engine> [modes]     modes: gritdig gritcave gritsky gritfog gritdigshot (default the first four)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS BENCH_STRS as bench.sh, e.g.
#        BENCH_STRS='("gfx", "High")'          the graphics level (default High)
#        SHOTS=<dir>                            where the pictures are copied (default $WORK/shots/<TAG>)
#
# It splices vfxprobe_modes.lua (the freecam) and gritprobe_modes.lua into a
# copy of perfbench.lua (before its main) and runs that copy through bench.sh;
# the repo's perfbench is untouched. A fresh save in the scratch project's
# slot 13, deleted after each mode (bench.sh).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-grit}
eng=${1:?usage: gritprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/gritprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "\n".join(open(f).read() for f in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "gritdig" then GR.run_dig()\n'
              '    elseif MODE == "gritcave" then GR.run_cave()\n    elseif MODE == "gritsky" then GR.run_sky()\n'
              '    elseif MODE == "gritfog" then GR.run_fog()\n    elseif MODE == "gritdigshot" then GR.run_digshot()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TAG=${TAG:-grit-$(date +%m%d-%H%M)}
rm -rf $S/proj/save/user/gritshots
TAG=$TAG TMO=${TMO:-420} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-gritdig gritcave gritsky gritfog}
rc=$?
for m in ${*:-gritdig gritcave gritsky gritfog}; do grep -a "PB .*GR \|PB .*ERROR\|PB .*TIMEOUT" $S/results/$TAG/$m.log 2>/dev/null | cut -c1-400; done
OUTS=${SHOTS:-$S/shots/$TAG}; mkdir -p $OUTS
cp $S/proj/save/user/gritshots/*.png $OUTS/ 2>/dev/null
echo "pictures: $OUTS ($(ls $OUTS | wc -l))"
rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
exit $rc
