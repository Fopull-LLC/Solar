#!/bin/bash
# suitshots.sh — one silent `floptle play` of suitshots.lua on a NEW save in a
# scratch project, under the shared engine lock. Pictures land in
# $WORK/suitshots/<TAG>/png; the probe's save slot is deleted afterwards.
#   WORK=$SCRATCH/suit2 LOCK=$SCRATCH/engine.lock tools/perf/suitshots.sh <engine> [TAG]
#   SHOT_PARAMS='("sweep", 0.0)'   probe params (see suitshots.lua)
#   ASTRO=/path/to/dir   draw the astronaut glbs from this directory instead of
#                        models/astronaut (an A/B against an older suit)
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:-suit}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/suitshotsproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
rm -f "$PJ/models"; rm -rf "$PJ/models"
if [ -n "${ASTRO:-}" ]; then
  mkdir -p "$PJ/models"
  for m in "$SOL"/models/*; do [ "$(basename "$m")" = astronaut ] || ln -s "$m" "$PJ/models/$(basename "$m")"; done
  ln -s "$ASTRO" "$PJ/models/astronaut"
fi
for d in models textures animation_controllers animations audio docs fonts materials shaders terrain tests tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$SOL/tools/perf/suitshots.lua" "$PJ/scripts/"
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/suitshots.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/suitshots"
cat > "$PJ/scenes/suitshots.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Suit Shots", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "suitshots", enabled: true, params: [${SHOT_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/suitshots/$TAG; mkdir -p "$OUT"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-330} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/suitshots/*.png "$OUT/png/" 2>/dev/null
# the probe's save goes: its slot file, its terrain, and the pictures' copies
rm -f "$PJ"/save/slot7.ron; rm -rf "$PJ/saves/slot7" "$PJ/save/user/suitshots" "$PJ/save/user/farlod/slot7"
grep -a "SUS \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-400 | tail -80
