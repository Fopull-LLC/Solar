#!/bin/bash
# stripprobe.sh — the crew strip as a scroll view (tools/perf/stripprobe_modes.lua).
#   WORK=$SCRATCH/strip tools/perf/stripprobe.sh <engine> [strip1 strip4 strip8]
# As ivaprobe.sh: a snapshot of the tree under $WORK/solar, perfbench.lua with
# ivaprobe_modes.lua and stripprobe_modes.lua spliced in, run by bench.sh (which
# takes the shared lock); SIZE=1280x720 plays it offscreen at that screen. Pictures: $WORK/proj/save/user/ivashots/strip<n>_*.png.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:?WORK}
eng=${1:?usage: stripprobe.sh <engine> [modes]}; shift
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
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" "$HERE/stripprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = open(sys.argv[2]).read() + "\n" + open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
modes = ('strip1', 'strip4', 'strip8')
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()' + ''.join('\n    elseif MODE == "%s" then run_%s()' % (m, m) for m in modes))
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
# SIZE=WxH: play it offscreen at exactly that screen (`floptle shot --size`,
# through a stand-in binary bench.sh runs as `floptle play`): a maximised
# window ignores app.setDisplayMode, and the strip's cap depends on the screen.
if [ -n "${SIZE:-}" ]; then
  if [ -x "$eng" ]; then REAL=$eng; VER=$(basename $(dirname $eng)); else REAL=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
  mkdir -p $S/wrap/$VER
  cat > $S/wrap/$VER/floptle <<SH
#!/bin/bash
exec $REAL shot "\$2" --scene perfbench --after ${AFTER:-150}s --size $SIZE --out $S/last_$SIZE.png
SH
  chmod +x $S/wrap/$VER/floptle
  eng=$S/wrap/$VER/floptle
fi
TMO=${TMO:-300} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${*:-strip1 strip4 strip8}
