#!/bin/bash
# flora.sh — one silent `floptle play` of floraprobe.lua on a COPY of the player's
# save, under the shared engine lock. Pictures land in $WORK/flora/<TAG>/png.
#   WORK=$SCRATCH/foliage LOCK=$SCRATCH/engine.lock tools/perf/flora.sh <engine> [TAG]
#   FLORA_PARAMS='("levels", 23.0), ("forest", 300.0)'   probe params (see floraprobe.lua)
#   PATCHES="a.patch b.patch"   applied to the scratch copy (A/B a change without touching Solar)
#   EDITOR=1   run `floptle <proj> --auto-play` (the editor, as the player plays) instead of `play`
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:-flora}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/floraproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$SOL/tools/perf/floraprobe.lua" "$PJ/scripts/"
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/floraprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/flora"
cp "$SOL/save/slot1.ron" "$PJ/save/slot1.ron"; cp -r "$SOL/saves/slot1" "$PJ/saves/slot1"
[ "${NOSETTINGS:-0}" = 1 ] || cp "$SOL/save/settings.ron" "$PJ/save/settings.ron"
cat > "$PJ/scenes/floraprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Flora Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "floraprobe", enabled: true, params: [${FLORA_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/flora/$TAG; mkdir -p "$OUT"
if [ "${EDITOR:-0}" = 1 ]; then CMD="$F $PJ --auto-play"; else CMD="$F play $PJ"; fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-240} $CMD > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/flora/*.png "$OUT/png/" 2>/dev/null
# the probe's save copies go: nothing of the player's is kept in the scratch project
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/flora"
grep -a "FP \|ERROR\|error" "$OUT/run.log" | cut -c1-400 | tail -60
