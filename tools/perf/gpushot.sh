#!/bin/bash
# gpushot.sh — a picture of one look at the base on a fresh save (or the player's),
# for before/after comparisons of the graphics dials.
#
#   gpushot.sh <engine> <look> [after-seconds]
#     look : "look" (untouched) or a perfbench gpu-mode toggle (fogsteps8, shadowdist150, …)
#   env: WORK, LOCK, SOLAR as bench.sh; OUT (png dir, default $WORK/shots); SIZE (default 1920x1052);
#        USERSAVE=1 the player's save at its spawn; BENCH_STRS extra strs, e.g. '("gfx", "Medium")'
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:-${TMPDIR:-/tmp}/solar-perf}
PJ=$S/proj
LOCK=${LOCK:-$S/engine.lock}
OUTD=${OUT:-$S/shots}; mkdir -p $OUTD
eng=${1:?usage: gpushot.sh <engine> <look> [after]}; LOOK=${2:?look}; AFTER=${3:-60}
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
rm -f $PJ/save/slot13.ron; rm -rf $PJ/saves/slot13; rm -f $PJ/save/slot1.ron; rm -rf $PJ/saves/slot1
if [ -n "${USERSAVE:-}" ]; then
  cp $SOL/save/slot1.ron $PJ/save/slot1.ron; cp $SOL/save/settings.ron $PJ/save/settings.ron 2>/dev/null; cp -r $SOL/saves/slot1 $PJ/saves/slot1
  PARAMS='("usersave", 1.0), ("slot", 1.0), ("quit", 0.0)'
else
  rm -f $PJ/save/settings.ron
  PARAMS='("quit", 0.0)'
fi
cat > $PJ/scenes/perfbench.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Perf Bench", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "perfbench", enabled: true, params: [$PARAMS${BENCH_PARAMS:+, $BENCH_PARAMS}], strs: [ ("mode", "gpu"), ("where", "${WHERE:-base}"), ("shotset", "$LOOK")${BENCH_STRS:+, $BENCH_STRS} ] ) ] ),
    ],
)
RON
PNG=$OUTD/$VER-${USERSAVE:+user-}$LOOK.png
flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$S/silent-alsa.conf timeout 400 $F shot $PJ --scene perfbench --after ${AFTER}s --size ${SIZE:-1920x1052} --out $PNG > $OUTD/$VER-$LOOK.log 2>&1; echo exit \$?"
grep -a "PB .*GPU\|error\|Error" $OUTD/$VER-$LOOK.log | cut -c1-300 | tail -6
rm -f $PJ/save/slot13.ron; rm -rf $PJ/saves/slot13; rm -f $PJ/save/slot1.ron; rm -rf $PJ/saves/slot1
echo "shot: $PNG"
