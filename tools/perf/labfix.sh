#!/bin/bash
# labfix.sh — the Research Lab's playtest fixes of 2026-11-03 in the real game (tools/perf/labfix.lua):
# walking in from the depot, walking into every solid thing, the scientists' look, poses, the talk camera.
# OLD=<git rev> runs the lab's files as they were at that revision (the "before"), the rest as now.
# A NEW Career save, silent, under the shared lock.
#
#   WORK=$SCRATCH/econ LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/labfix.sh <engine> [TAG]
#   env: PATCHES (unified diffs applied to the scratch copy), LFX_PARAMS, TMO (seconds, default 300)
#
# Pictures land in $WORK/labfix/<TAG>/png, the log in run.log ("LFX " lines).
# "RESULT" lines). The scratch project gets REAL save/ and saves/ folders;
# its probe slot is deleted afterwards. Solar's own saves are never touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/lbproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: labfix.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
if [ -x "$eng" ]; then F=$eng; else F=$HOME/.local/share/floptle/versions/$eng/floptle; fi
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
[ -f "$ALSA" ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > "$ALSA"
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$HERE/labfix.lua" "$PJ/scripts/"
if [ -n "${OLD:-}" ]; then
  for f in scripts/lab.lua scripts/scientist.lua scripts/lab_talk.lua scripts/face.lua prefabs/LabInterior.prefab.ron prefabs/LabScientist.prefab.ron; do
    git -C "$SOL" show "$OLD:$f" > "$PJ/$f"
  done
  # the old interior's hidden mesh collider: a models/ of links with it added
  rm -f "$PJ/models"; mkdir -p "$PJ/models/lab"
  for m in "$SOL"/models/*; do [ "$(basename "$m")" = lab ] || ln -sfn "$m" "$PJ/models/$(basename "$m")"; done
  for m in "$SOL"/models/lab/*; do ln -sfn "$m" "$PJ/models/lab/$(basename "$m")"; done
  git -C "$SOL" show "$OLD:models/lab/lab_walk.glb" > "$PJ/models/lab/lab_walk.glb"
elif [ -d "$PJ/models" ] && [ ! -L "$PJ/models" ]; then
  rm -rf "$PJ/models"; ln -s "$SOL/models" "$PJ/models"
fi
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/labfix.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/labfix"
cat > "$PJ/scenes/labfix.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Works Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "labfix", enabled: true, params: [${LFX_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/labfix/$TAG; mkdir -p "$OUT"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; date +start\ %s.%N >> '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-340} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; date +end\ %s.%N >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/labfix/*.png "$OUT/png/" 2>/dev/null
# the probe's save goes: its slot file, its terrain, the pictures' copies
rm -f "$PJ"/save/slot19.ron; rm -rf "$PJ/saves/slot19" "$PJ/save/user/labfix" "$PJ/save/user/farlod/slot19"
rm -rf "$PJ/save/user/labfix"
grep -a "LFX \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-600 | tail -80
