#!/bin/bash
# neckshots.sh — the lab scientists' necks and the lab's ceiling (tools/perf/neckprobe.lua), playtest 2026-11-04.
# OLD=<git rev> runs the lab's coat, face script and interior prefab as they were at that revision (the "before").
# A NEW Career save, silent, under the shared lock.
#
#   WORK=$SCRATCH/neck LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/neckshots.sh <engine> [TAG]
#   env: NKP_PARAMS (e.g. "(\"diag\", 1.0)"), TMO (seconds, default 300)
#
# Pictures land in $WORK/neck/<TAG>/png, the log in run.log ("NKP " lines). The scratch project gets
# REAL save/ and saves/ folders; its probe slot is deleted afterwards. Solar's own saves are never touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/nkproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: neckshots.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
if [ -x "$eng" ]; then F=$eng; else F=$HOME/.local/share/floptle/versions/$eng/floptle; fi
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
[ -f "$ALSA" ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > "$ALSA"
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs" "$PJ/models"
mkdir -p "$PJ/scripts" "$PJ/scenes" "$PJ/models/lab"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$HERE/neckprobe.lua" "$PJ/scripts/"
for m in "$SOL"/models/*; do [ "$(basename "$m")" = lab ] || ln -sfn "$m" "$PJ/models/$(basename "$m")"; done
for m in "$SOL"/models/lab/*; do ln -sfn "$m" "$PJ/models/lab/$(basename "$m")"; done
if [ -n "${OLD:-}" ]; then
  for f in scripts/face.lua scripts/scientist.lua prefabs/LabInterior.prefab.ron prefabs/LabScientist.prefab.ron; do
    git -C "$SOL" show "$OLD:$f" > "$PJ/$f"
  done
  rm -f "$PJ/models/lab/scientist.glb"; git -C "$SOL" show "$OLD:models/lab/scientist.glb" > "$PJ/models/lab/scientist.glb"
fi
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/neckprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/neck"
cat > "$PJ/scenes/neckprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Works Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "neckprobe", enabled: true, params: [${NKP_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/neck/$TAG; mkdir -p "$OUT"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-300} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/neck/*.png "$OUT/png/" 2>/dev/null
# the probe's save goes: its slot file, its terrain, the pictures' copies
rm -f "$PJ"/save/slot19.ron; rm -rf "$PJ/saves/slot19" "$PJ/save/user/neck" "$PJ/save/user/farlod/slot19"
grep -a "NKP \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-600 | tail -80
