#!/bin/bash
# faceprobe.sh — the crew's faces in the game (tools/perf/faceprobe_modes.lua).
#   WORK=$SCRATCH/faces tools/perf/faceprobe.sh <engine> [facepod facefoot]
# As ivaprobe.sh: a snapshot of the tree under $WORK/solar, perfbench.lua with
# ivaprobe_modes.lua and faceprobe_modes.lua spliced in, run by bench.sh (which
# takes the shared lock). Pictures: $WORK/proj/save/user/ivashots/face_*.png.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:?WORK}
eng=${1:?usage: faceprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/solar
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) [ -e $SN/$d ] || ln -s $SOL/$d $SN/$d ;; esac
done
[ -e $SN/tools ] || ln -s $SOL/tools $SN/tools
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" "$HERE/faceprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = open(sys.argv[2]).read() + "\n" + open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
modes = ('facepod', 'facefoot', 'facestrip')
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()' + ''.join('\n    elseif MODE == "%s" then run_%s()' % (m, m) for m in modes))
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-300} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${*:-facepod facefoot facestrip}
