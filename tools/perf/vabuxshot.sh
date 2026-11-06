#!/bin/bash
# vabuxshot.sh — the VAB's direct-manipulation pass (tools/perf/vabuxprobe.lua):
# a stage dragged by its grip, a part clicked to inspect (ABOUT scrolled), the
# crew's portraits, a card dragged onto a seat, a medkit bought into a rover's
# locker and found there after launch. Pictures: $WORK/vabux/*.png.
#
#   vabuxshot.sh <engine>
#   env: WORK (scratch dir), LOCK (the shared engine lock), PATCHES (unified
#        diffs applied to the scratch copy, -p1), ALSA (the silent config)
#
# A NEW save in slot 15 of a scratch project with REAL save/ and saves/
# folders: Solar's own saves are never touched. The slot is deleted after.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
PJ=$S/vabuxproj
LOCK=${LOCK:-/mnt/disks/3tb/.floptle-shared/engine.lock}
OUTD=$S/vabux; mkdir -p $OUTD
eng=${1:?usage}
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
ALSA=${ALSA:-/mnt/disks/3tb/.floptle-shared/silent-alsa.conf}
[ -f $ALSA ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > $ALSA
mkdir -p $PJ/save $PJ/saves $PJ/.floptle
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf $PJ/scripts $PJ/scenes $PJ/prefabs
mkdir -p $PJ/scripts $PJ/scenes
cp $SOL/scripts/*.lua $PJ/scripts/; cp -r $SOL/prefabs $PJ/prefabs; cp $SOL/scenes/*.ron $PJ/scenes/
cp $SOL/.floptle/textures.ron $PJ/.floptle/ 2>/dev/null; cp -r $SOL/.floptle/library $PJ/.floptle/ 2>/dev/null
cp $SOL/project.ron $PJ/project.ron
cp $HERE/vabuxprobe.lua $PJ/scripts/
for p in ${PATCHES:-}; do (cd $PJ && patch -p1 --no-backup-if-mismatch -s < $p) || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/vabuxprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
cat > $PJ/scenes/vabuxprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "VabUx Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "vabuxprobe", enabled: true, params: [("slot", 15.0)] ) ] ),
    ],
)
RON
LOG=$OUTD/vabux.log
rm -rf $PJ/save/user/vabux; rm -f $OUTD/*.png
flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$ALSA timeout ${TMO:-360} $F play $PJ > $LOG 2>&1; echo exit \$?"
cp $PJ/save/user/vabux/*.png $OUTD/ 2>/dev/null
rm -rf $PJ/save/user/vabux
rm -f $PJ/save/slot15.ron; rm -rf $PJ/saves/slot15
grep -a "VABUX \|ERROR\|error\[\|panic" $LOG | grep -v "^warning" | cut -c1-400 | tail -60
ls $OUTD
