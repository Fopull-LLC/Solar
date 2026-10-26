#!/bin/bash
# fall.sh — does the crew fall through the planet? (tools/perf/fallprobe.lua)
#
#   fall.sh <engine> [net 0|1] [usersave 0|1] [shot-after-seconds]
#   env: WORK (scratch dir), LOCK (the shared engine lock)
# Scratch project with REAL save/ and saves/; the player's slot1 is COPIED in
# for usersave=1 (and loaded read-only by the probe's scene), slot15 otherwise
# (deleted by the probe).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
eng=${1:?usage}; NET=${2:-0}; US=${3:-0}; SHOT=${4:-}
PJ=$S/fallproj-$NET-$US
LOCK=${LOCK:-$S/engine.lock}
OUTD=${OUT:-$S/shots}; mkdir -p $OUTD
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
cp $HERE/fallprobe.lua $PJ/scripts/
SLOT=15
if [ "$US" = 1 ]; then
  SLOT=1
  rm -rf $PJ/saves/slot1; cp $SOL/save/slot1.ron $SOL/save/settings.ron $PJ/save/ 2>/dev/null; cp -r $SOL/saves/slot1 $PJ/saves/slot1
fi
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/fallprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
Q=1; [ -n "$SHOT" ] && Q=0
cat > $PJ/scenes/fallprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Fall Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "fallprobe", enabled: true, params: [("slot", $SLOT.0), ("usersave", $US.0), ("net", $NET.0), ("notint", ${NOTINT:-0}.0), ("quit", $Q.0)], strs: [] ) ] ),
    ],
)
RON
LOG=$OUTD/fall-$VER-net$NET-us$US${FPS:+-fps$FPS}.log
if [ -z "$SHOT" ]; then
  flock $LOCK bash -c "date; uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout 360 $F run $PJ --scene fallprobe --seconds 300 ${FPS:+--fps $FPS} > $LOG 2>&1; echo exit \$?"
else
  PNG=$OUTD/fall-$VER-net$NET-us$US.png
  flock $LOCK bash -c "date; uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout 360 $F shot $PJ --scene fallprobe --after ${SHOT}s --size 1280x720 --out $PNG > $LOG 2>&1; echo exit \$?"
  echo "shot: $PNG"
fi
rm -f $PJ/save/slot15.ron; rm -rf $PJ/saves/slot15
echo "log: $LOG"
grep -a "FALL \|WALKER NET\|ERROR\|error" $LOG | grep -v "^warning" | grep -a -v " s cave-run\| s drop\| s idle" | tail -70
