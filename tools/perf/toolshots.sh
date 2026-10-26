#!/bin/bash
# toolshots.sh — one silent `floptle play` of toolshots.lua on a COPY of the player's
# save, under the shared engine lock. Pictures land in $WORK/look/<TAG>/png.
#   WORK=$SCRATCH/ground LOCK=$SCRATCH/engine.lock tools/perf/look.sh <engine> [TAG]
#   SHOT_PARAMS='("occl", 0.0), ("weather", 1.0)'   probe params (see toolshots.lua)
#   BEFORE=1   the tools as committed (HEAD's models/tools, Tool* prefabs, tool_belt.lua, textures/tools)
#   EDITOR=1   run `floptle <proj> --auto-play` (the editor, as the player plays) instead of `play`
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:-look}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/toolshotsproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
# models/ and textures/ are real folders of links, so BEFORE=1 can swap the tools in
for d in models textures; do
  [ -L "$PJ/$d" ] && rm "$PJ/$d"
  rm -rf "$PJ/$d"; mkdir -p "$PJ/$d"
  for e in "$SOL/$d"/*; do ln -s "$e" "$PJ/$d/$(basename "$e")"; done
done
for d in animation_controllers animations audio docs fonts materials shaders terrain tests tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$SOL/tools/perf/toolshots.lua" "$PJ/scripts/"
if [ "${BEFORE:-0}" = 1 ]; then
  rm "$PJ/models/tools"; mkdir -p "$PJ/models/tools"
  (cd "$SOL" && git ls-tree --name-only HEAD models/tools/) | while read f; do (cd "$SOL" && git show "HEAD:$f") > "$PJ/$f"; done
  for f in ToolGravGun ToolLaser ToolGravGunFP ToolLaserFP; do (cd "$SOL" && git show "HEAD:prefabs/$f.prefab.ron") > "$PJ/prefabs/$f.prefab.ron"; done
  (cd "$SOL" && git show HEAD:scripts/tool_belt.lua) > "$PJ/scripts/tool_belt.lua"
  rm -f "$PJ/textures/tools"
fi
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/toolshots.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/toolshots"
cp "$SOL/save/slot1.ron" "$PJ/save/slot1.ron"; cp -r "$SOL/saves/slot1" "$PJ/saves/slot1"
[ "${NOSETTINGS:-0}" = 1 ] || cp "$SOL/save/settings.ron" "$PJ/save/settings.ron"
cat > "$PJ/scenes/toolshots.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Tool Shots", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "toolshots", enabled: true, params: [${SHOT_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/toolshots/$TAG; mkdir -p "$OUT"
if [ "${EDITOR:-0}" = 1 ]; then CMD="$F $PJ --auto-play"; else CMD="$F play $PJ"; fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-240} $CMD > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/toolshots/*.png "$OUT/png/" 2>/dev/null
# the probe's save copies go: nothing of the player's is kept in the scratch project
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/toolshots"
grep -a "TSG \|ERROR\|error" "$OUT/run.log" | cut -c1-400 | tail -60
