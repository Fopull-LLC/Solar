#!/bin/bash
# verifyprobe.sh — the 2026-10-27 playtest fixes (commit 62e8dca) checked in the engine.
#
#   verifyprobe.sh <engine> [modes]   modes: vbike vvab vflora vplants vobj vjitter
#   env: WORK LOCK TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 330 s a mode)
#        USERSAVE=1 for vflora vplants vobj vjitter: the player's save, copied from
#        SAVESRC (default ~/.local/share/solar, else the repo's save/ and saves/) into the
#        scratch snapshot — never written where it came from.
#        BIKE=path the craft file for vbike (default ~/.local/share/solar/user/library/slot1/dirtbike.json)
#
# Builds a snapshot of the Solar tree under $WORK/solar (assets linked; scripts,
# scenes, prefabs, project.ron copied), splices ivaprobe_modes.lua and
# verifyprobe_modes.lua into a copy of perfbench.lua (before its main) and runs
# bench.sh on that snapshot. Look for `VP PASS|FAIL` and `VP RESULT`; pictures
# land in $WORK/proj/save/user/vshots/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-verify}
eng=${1:?usage: verifyprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools $S/solar $S/proj/save/user
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) [ -e $SN/$d ] || ln -s $SOL/$d $SN/$d ;; esac
done
[ -e $SN/tools ] || ln -s $SOL/tools $SN/tools
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
if [ -n "${USERSAVE:-}" ]; then
  SRC=${SAVESRC:-$HOME/.local/share/solar}
  [ -f $SRC/save/slot1.ron ] || SRC=$SOL
  cp $SRC/save/slot1.ron $SN/save/slot1.ron; cp $SRC/save/settings.ron $SN/save/settings.ron 2>/dev/null
  rm -rf $SN/saves/slot1; cp -r $SRC/saves/slot1 $SN/saves/slot1
  echo "verify: the player's save from $SRC (copied)"
fi
BIKE=${BIKE:-$HOME/.local/share/solar/user/library/slot1/dirtbike.json}
[ -f "$BIKE" ] && cp "$BIKE" $S/proj/save/user/probe_dirtbike.json
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" "$HERE/verifyprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = open(sys.argv[2]).read() + "\n" + open(sys.argv[3]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
modes = ('vbike', 'vvab', 'vflora', 'vplants', 'vobj', 'vjitter')
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()' + ''.join('\n    elseif MODE == "%s" then run_%s()' % (m, m) for m in modes))
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-330} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng ${*:-vbike vvab}
rc=$?
# the player's save copy goes (the probe never writes Solar's own)
rm -f $SN/save/slot1.ron $SN/save/settings.ron; rm -rf $SN/saves/slot1
exit $rc
