#!/bin/bash
# ivaprobe.sh — the crew strip, the interiors (first person in every crew part)
# and the crew alerts (docs/crew-and-items.md §4.4, §3.4, §2.3; WS2).
#
#   ivaprobe.sh <engine> [modes]   modes: ivapod2 ivapod1 ivacabin ivajet ivaseat ivasaddle ivaalerts
#   env: WORK LOCK TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#        HEADFILES="a b" files taken from git HEAD instead of the working tree (another
#        agent's half-done edits: scenes, a panel), so the probe runs on a coherent tree
#
# It builds a snapshot of the Solar tree under $WORK/solar (assets linked; scripts,
# scenes, prefabs, project.ron copied; HEADFILES from HEAD), splices
# ivaprobe_modes.lua into a copy of perfbench.lua (before its main) and runs
# bench.sh on that snapshot; the repo's perfbench is untouched. Look for
# `IV PASS|FAIL` and `IV RESULT` lines; pictures land in
# $WORK/proj/save/user/ivashots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-crew}
eng=${1:?usage: ivaprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/solar
# ── the snapshot ──
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) [ -e $SN/$d ] || ln -s $SOL/$d $SN/$d ;; esac
done
[ -e $SN/tools ] || ln -s $SOL/tools $SN/tools
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
if [ -n "${USERSAVE:-}" ]; then
  cp $SOL/save/slot1.ron $SN/save/slot1.ron; cp $SOL/save/settings.ron $SN/save/settings.ron 2>/dev/null
  rm -rf $SN/saves/slot1; cp -r $SOL/saves/slot1 $SN/saves/slot1
fi
for f in ${HEADFILES:-}; do (cd $SOL && git show HEAD:$f) > $SN/$f 2>/dev/null || rm -f $SN/$f; done
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
modes = ('ivapod2', 'ivapod1', 'ivacabin', 'ivajet', 'ivaseat', 'ivasaddle', 'ivaalerts')
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()' + ''.join('\n    elseif MODE == "%s" then run_%s()' % (m, m) for m in modes))
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-300} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${*:-ivapod2 ivapod1 ivacabin ivajet ivaseat ivaalerts}
rc=$?
# the player's save copy goes (the probe never writes Solar's own)
rm -f $SN/save/slot1.ron $SN/save/settings.ron; rm -rf $SN/saves/slot1
exit $rc
