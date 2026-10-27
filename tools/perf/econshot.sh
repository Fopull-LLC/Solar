#!/bin/bash
# econshot.sh — a picture of an economy panel (Ops Board, depot, catalogue).
#
#   econshot.sh <engine> <case> [after-seconds] [fresh]
#     case : board depot catalog (tools/perf/econprobe.lua)
#     fresh: 1 makes slot 13 a new save first (the new-save panel's way)
#   env: WORK (scratch dir), LOCK (the shared engine lock), PATCHES (unified
#        diffs applied to the scratch copy, e.g. vessel_controller.patch)
#
# The scratch project gets REAL save/ and saves/ folders: Solar's own saves
# are never touched. Delete $WORK/proj/save* when done.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
PJ=$S/proj
LOCK=${LOCK:-$S/engine.lock}
OUTD=${OUT:-$S/shots}; mkdir -p $OUTD
eng=${1:?usage}; CASE=${2:?case}; AFTER=${3:-200}; FRESH=${4:-0}
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
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
cp $HERE/econprobe.lua $PJ/scripts/
[ -f $SOL/scripts/suit.lua ] || { cp $HERE/ctx_suitstub.lua $PJ/scripts/suit.lua
  printf '[ ( name: "SuitStub", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ), matter: Empty, scripts: [ ( kind: "suit", enabled: true, params: [] ) ] ) ]\n' > $PJ/prefabs/SuitStub.prefab.ron; }
for p in ${PATCHES:-}; do (cd $PJ && patch -p1 --no-backup-if-mismatch -s < $p) || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/econprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
cat > $PJ/scenes/econprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Econ Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "econprobe", enabled: true, params: [("slot", 13.0), ("fresh", $FRESH.0)], strs: [ ("case", "$CASE") ] ) ] ),
    ],
)
RON
PNG=$OUTD/econ-$CASE.png
flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$S/silent-alsa.conf timeout 420 $F shot $PJ --scene econprobe --after ${AFTER}s --size 1280x720 --out $PNG > $OUTD/econ-$CASE.log 2>&1; echo exit \$?"
grep -a "ECON \|error\|Error\|context:" $OUTD/econ-$CASE.log | grep -v "^warning" | tail -30
echo "shot: $PNG"
