#!/bin/bash
# shot.sh — a picture of the tools' marks on the player's save, through the game's camera.
#
#   shot.sh <engine> <case> [after-seconds]
#     case : 1 the gravity gun aimed at a plant   2 the plant being pulled (tether)
#            3 a scattered rock aimed at          4 a loose prop held on the tether
#   env: WORK, LOCK, SOLAR as bench.sh; OUT (png dir, default $WORK/shots)
#
# Builds the same scratch project as bench.sh (perfbench.lua in mode "shot" on a
# copy of save/slot1), then `floptle shot --after N` plays it that long on the
# fixed clock and draws the frame. Solar's own save is never written.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:-${TMPDIR:-/tmp}/solar-perf}
PJ=$S/proj
LOCK=${LOCK:-$S/engine.lock}
OUTD=${OUT:-$S/shots}; mkdir -p $OUTD
eng=${1:?usage: shot.sh <engine> <case> [after]}; CASE=${2:?case 1..4}; AFTER=${3:-45}
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
[ -x "$F" ] || { echo "no engine binary at $F"; exit 2; }
[ -f $S/silent-alsa.conf ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > $S/silent-alsa.conf
mkdir -p $PJ/save $PJ/saves $PJ/.floptle
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e $PJ/$d ] || ln -s $SOL/$d $PJ/$d
done
rm -rf $PJ/scripts $PJ/scenes $PJ/prefabs
mkdir -p $PJ/scripts $PJ/scenes
cp $SOL/scripts/*.lua $PJ/scripts/; cp -r $SOL/prefabs $PJ/prefabs; cp $SOL/scenes/*.ron $PJ/scenes/
cp $SOL/.floptle/textures.ron $PJ/.floptle/ 2>/dev/null; cp -r $SOL/.floptle/library $PJ/.floptle/ 2>/dev/null
cp $SOL/project.ron $PJ/project.ron
cp $HERE/perfbench.lua $PJ/scripts/
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/perfbench.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
rm -f $PJ/save/slot1.ron; rm -rf $PJ/saves/slot1
cp $SOL/save/slot1.ron $PJ/save/slot1.ron; cp $SOL/save/settings.ron $PJ/save/settings.ron 2>/dev/null; cp -r $SOL/saves/slot1 $PJ/saves/slot1
cat > $PJ/scenes/perfbench.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Perf Bench", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "perfbench", enabled: true, params: [("usersave", 1.0), ("slot", 1.0), ("shotcase", $CASE.0), ("quit", 0.0)${BENCH_PARAMS:+, $BENCH_PARAMS}], strs: [ ("mode", "shot") ] ) ] ),
    ],
)
RON
PNG=$OUTD/$VER-case$CASE.png
flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$S/silent-alsa.conf timeout 400 $F shot $PJ --scene perfbench --after ${AFTER}s --size 1280x720 --out $PNG > $OUTD/$VER-case$CASE.log 2>&1; echo exit \$?"
grep -a "PB .*SHOT\|error\|Error" $OUTD/$VER-case$CASE.log | tail -12
rm -f $PJ/save/slot1.ron; rm -rf $PJ/saves/slot1
echo "shot: $PNG"
