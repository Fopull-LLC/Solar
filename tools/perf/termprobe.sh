#!/bin/bash
# termprobe.sh — the base terminals in the engine (tools/perf/termprobe.lua):
# Graveyard Shift staged, the reactor console and the log desk opened with E,
# every page pictured, a breaker trip-tested and reset, MU-1 shut and opened,
# SCRAM, the airlock cycled, a door locked, the LOG read back, Esc, the cost.
#
#   termprobe.sh <engine> scn
#   env: WORK (scratch dir), LOCK (an engine slot: the pool takes either),
#        PATCHES (unified diffs applied to the scratch copy, -p1).
#
# The scratch project has its own save/ and saves/: delete $WORK/proj/save*
# when done. Look for `TP PASS|FAIL`, `TP COST`, `TP RESULT`.
# Pictures land in $WORK/proj/save/user/termshots/.
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
PJ=$S/proj
LOCK=${LOCK:-/mnt/disks/3tb/.floptle-shared/engine.lock}
eng=${1:?usage: termprobe.sh <engine> <case>}; CASE=${2:?case}
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
mkdir -p $S; [ -f $S/silent-alsa.conf ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > $S/silent-alsa.conf
mkdir -p $PJ/save $PJ/saves $PJ/.floptle $S/logs
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json scenarios; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf $PJ/scripts $PJ/scenes $PJ/prefabs
mkdir -p $PJ/scripts $PJ/scenes
cp $SOL/scripts/*.lua $PJ/scripts/; cp -r $SOL/prefabs $PJ/prefabs; cp $SOL/scenes/*.ron $PJ/scenes/
cp $SOL/.floptle/textures.ron $PJ/.floptle/ 2>/dev/null; cp -r $SOL/.floptle/library $PJ/.floptle/ 2>/dev/null
cp $SOL/project.ron $PJ/project.ron
cp $HERE/termprobe.lua $PJ/scripts/
# a patch may touch scenarios/: give the copy its own scenarios folder then
if [ -n "${PATCHES:-}" ]; then rm -f $PJ/scenarios; cp -r $SOL/scenarios $PJ/scenarios; fi
for p in ${PATCHES:-}; do (cd $PJ && patch -p1 --no-backup-if-mismatch -s < $p) || echo "PATCH FAILED $p"; done
if [ -n "${TYSAVE:-}" ]; then
  rm -rf $PJ/saves/slot1
  cp $HOME/.local/share/solar/save/slot1.ron $PJ/save/slot1.ron
  cp -r $HOME/.local/share/solar/saves/slot1 $PJ/saves/slot1
fi
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/termprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
cat > $PJ/scenes/termprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Ix Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "termprobe", enabled: true, params: [], strs: [ ("case", "$CASE") ] ) ] ),
    ],
)
RON
LOG=$S/logs/term-$CASE.log
flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$S/silent-alsa.conf timeout ${TMO:-360} $F play $PJ > $LOG 2>&1; echo exit \$?"
grep -a "TP \|terminal:\|ERROR\|error" $LOG | grep -av "^warning" | tail -${TAIL:-80}
echo "log: $LOG"
