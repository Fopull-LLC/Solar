#!/bin/bash
# covprobe.sh — sustained relay coverage
# (tools/perf/covprobe.lua), in the real game.
#
#   covprobe.sh <engine> <stop> [after-seconds]
#     stop : all   — every step, `floptle run` (no picture), RESULT lines
#            map   — the same with the map open, pictures (camera.capture)
#                    copied to $OUT/cov_one.png, cov_three.png
#   env: WORK (scratch dir), LOCK (the shared engine lock), PATCHES (diffs
#        applied to the scratch copy)
#
# The scratch project gets REAL save/ and saves/ folders: Solar's own saves
# are never touched. The probe deletes its slot (15) when it finishes a full
# run; delete $WORK/covproj/save* after a shot run.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
PJ=$S/covproj-${2:-all}
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
cp $HERE/covprobe.lua $PJ/scripts/
for p in ${PATCHES:-}; do (cd $PJ && patch -p1 --no-backup-if-mismatch -s < $p) || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/covprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
Q=1
cat > $PJ/scenes/covprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Cov Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "covprobe", enabled: true, params: [("slot", 15.0), ("quit", $Q.0)], strs: [ ("stop", "$STOP") ] ) ] ),
    ],
)
RON
LOG=$OUTD/cov-$STOP.log
# (map: `play`, a real window, so camera.capture has a picture to take)
if [ "$STOP" = all ]; then CMD="run $PJ --scene covprobe --seconds $AFTER"; else CMD="play $PJ"; fi
flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout 360 $F $CMD > $LOG 2>&1; echo exit \$?"
for f in $PJ/save/user/screenshots/cov_*.png; do [ -f "$f" ] && cp "$f" $OUTD/ && echo "shot: $OUTD/$(basename $f)"; done
rm -f $PJ/save/slot15.ron; rm -rf $PJ/saves/slot15
grep -a "COV \|error\|Error\|comms" $LOG | grep -v "^warning" | tail -80
