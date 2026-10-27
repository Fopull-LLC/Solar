#!/bin/bash
# crewuishot.sh — the crew presentation's panels (tools/perf/crewuiprobe.lua):
# the VAB CREW tab, the Astronaut Complex's ROSTER / APPLICANTS / MEMORIAL.
#
#   crewuishot.sh <engine> <case> [after-seconds]
#     case : vab | roster | applicants | memorial
#   env: WORK (scratch dir), LOCK (the shared engine lock), PATCHES (unified
#        diffs applied to the scratch copy, -p1), ALSA (the silent config)
#
# Every case makes a NEW save in slot 15 of a scratch project with REAL save/
# and saves/ folders: Solar's own saves are never touched. The slot is
# deleted after the run.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
PJ=$S/crewuiproj
LOCK=${LOCK:-/mnt/disks/3tb/.floptle-shared/engine.lock}
OUTD=${OUT:-$S/shots}; mkdir -p $OUTD
eng=${1:?usage}; CASE=${2:?case}; AFTER=${3:-240}
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
ALSA=${ALSA:-/mnt/disks/3tb/.floptle-shared/silent-alsa.conf}
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
cp $HERE/crewuiprobe.lua $PJ/scripts/
for p in ${PATCHES:-}; do (cd $PJ && patch -p1 --no-backup-if-mismatch -s < $p) || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/crewuiprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
cat > $PJ/scenes/crewuiprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "CrewUi Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "crewuiprobe", enabled: true, params: [("slot", 15.0)], strs: [ ("case", "$CASE") ] ) ] ),
    ],
)
RON
PNG=$OUTD/crewui-$CASE.png
LOG=$OUTD/crewui-$CASE.log
flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout 420 $F shot $PJ --scene crewuiprobe --after ${AFTER}s --size 1280x720 --out $PNG > $LOG 2>&1; echo exit \$?"
rm -f $PJ/save/slot15.ron; rm -rf $PJ/saves/slot15
grep -a "CREWUI \|error\|Error\|panic" $LOG | grep -v "^warning" | tail -30
echo "shot: $PNG"
