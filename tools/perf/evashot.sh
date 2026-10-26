#!/bin/bash
# evashot.sh — EVA in orbit, the RCS Pack and the held repair lock
# (tools/perf/evaprobe.lua), in the real game.
#
#   evashot.sh <engine> <stop> [after-seconds]
#     stop : all   — every step, `floptle run` (no picture), RESULT lines
#            warn | orbit | repair — `floptle shot` holding at that step
#   env: WORK (scratch dir), LOCK (the shared engine lock), PATCHES (diffs
#        applied to the scratch copy)
#
# The scratch project gets REAL save/ and saves/ folders: Solar's own saves
# are never touched. The probe deletes its slot (14) when it finishes a full
# run; delete $WORK/evaproj/save* after a shot run.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
PJ=$S/evaproj-${2:-all}
LOCK=${LOCK:-$S/engine.lock}
OUTD=${OUT:-$S/shots}; mkdir -p $OUTD
eng=${1:?usage}; STOP=${2:?stop}; AFTER=${3:-400}
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
ALSA=${ALSA:-$S/silent-alsa.conf}
[ -f $ALSA ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > $ALSA
mkdir -p $PJ/save $PJ/saves $PJ/.floptle
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e $PJ/$d ] || ln -s $SOL/$d $PJ/$d
done
rm -rf $PJ/scripts $PJ/scenes $PJ/prefabs
mkdir -p $PJ/scripts $PJ/scenes
cp $SOL/scripts/*.lua $PJ/scripts/; cp -r $SOL/prefabs $PJ/prefabs; cp $SOL/scenes/*.ron $PJ/scenes/
cp $SOL/.floptle/textures.ron $PJ/.floptle/ 2>/dev/null; cp -r $SOL/.floptle/library $PJ/.floptle/ 2>/dev/null
cp $SOL/project.ron $PJ/project.ron
cp $HERE/evaprobe.lua $PJ/scripts/
for p in ${PATCHES:-}; do (cd $PJ && patch -p1 --no-backup-if-mismatch -s < $p) || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/evaprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
Q=1; [ "$STOP" = all ] || Q=0
cat > $PJ/scenes/evaprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Eva Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "evaprobe", enabled: true, params: [("slot", 14.0), ("quit", $Q.0), ("sidecam", ${SIDECAM:-0}.0)], strs: [ ("stop", "$STOP") ] ) ] ),
    ],
)
RON
LOG=$OUTD/eva-$STOP.log
if [ "$STOP" = all ]; then
  flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout 420 $F run $PJ --scene evaprobe --seconds $AFTER > $LOG 2>&1; echo exit \$?"
else
  PNG=$OUTD/eva-$STOP${SIDECAM:+-side}.png
  flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout 420 $F shot $PJ --scene evaprobe --after ${AFTER}s --size 1280x720 --out $PNG > $LOG 2>&1; echo exit \$?"
  echo "shot: $PNG"
fi
rm -f $PJ/save/slot14.ron; rm -rf $PJ/saves/slot14
grep -a "EVA \|error\|Error\|crew\|RCS" $LOG | grep -v "^warning" | tail -60
