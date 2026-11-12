#!/bin/bash
# boardevaprobe.sh — boarding and EVA in the player's hands
# (tools/perf/boardevaprobe.lua), in the real game.
#
#   boardevaprobe.sh <engine> <stop> [at] [seconds]
#     stop : jitter | orbit | ground   (see the probe's header)
#     at   : empty — `floptle run` (no picture), RESULT lines
#            <tag> — `floptle shot` holding at that step (shots/<stop>-<tag>.png)
#   env: WORK (scratch dir), LOCK (the shared engine lock), PATCHES (diffs
#        applied to the scratch copy), TAG (a name for the log)
#
# The scratch project gets REAL save/ and saves/ folders: Solar's own saves
# are never touched. Slot 14 is deleted after every run.
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
eng=${1:?usage}; STOP=${2:?stop}; AT=${3:-}; AFTER=${4:-400}
PJ=$S/beproj-$STOP${AT:+-$AT}
LOCK=${LOCK:-$S/engine.lock}
OUTD=${OUT:-$S/shots}; mkdir -p $OUTD
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
ALSA=${ALSA:-/mnt/disks/3tb/.floptle-shared/silent-alsa.conf}
mkdir -p $PJ/save $PJ/saves $PJ/.floptle
for d in animation_controllers animations audio docs fonts materials models scenarios shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf $PJ/scripts $PJ/scenes $PJ/prefabs
mkdir -p $PJ/scripts $PJ/scenes
cp $SOL/scripts/*.lua $PJ/scripts/; cp -r $SOL/prefabs $PJ/prefabs; cp $SOL/scenes/*.ron $PJ/scenes/
cp $SOL/.floptle/textures.ron $PJ/.floptle/ 2>/dev/null; cp -r $SOL/.floptle/library $PJ/.floptle/ 2>/dev/null
cp $SOL/project.ron $PJ/project.ron
cp $HERE/boardevaprobe.lua $PJ/scripts/
for p in ${PATCHES:-}; do (cd $PJ && patch -p1 --no-backup-if-mismatch -s < $p) || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/boardevaprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
Q=1; [ -z "$AT" ] || Q=0
cat > $PJ/scenes/boardevaprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "BoardEva Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "boardevaprobe", enabled: true, params: [("slot", 14.0), ("quit", $Q.0)], strs: [ ("stop", "$STOP"), ("at", "$AT") ] ) ] ),
    ],
)
RON
LOG=$OUTD/be-$STOP${AT:+-$AT}${TAG:+-$TAG}.log
if [ -z "$AT" ]; then
  flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout 420 $F run $PJ --scene boardevaprobe --seconds $AFTER ${FPS:+--fps $FPS} > $LOG 2>&1; echo exit \$?"
else
  PNG=$OUTD/$STOP-$AT${TAG:+-$TAG}.png
  flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout 420 $F shot $PJ --scene boardevaprobe --after ${AFTER}s ${FPS:+--fps $FPS} --size 1280x720 --out $PNG > $LOG 2>&1; echo exit \$?"
  echo "shot: $PNG"
fi
rm -f $PJ/save/slot14.ron; rm -rf $PJ/saves/slot14
grep -a "^BE \|error\|Error" $LOG | grep -v "^warning" | grep -v " JF " | tail -60
