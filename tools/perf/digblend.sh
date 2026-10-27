#!/bin/bash
# digblend.sh — one silent `floptle play` of digblendprobe.lua on a COPY of the player's
# save, under the shared engine lock. Pictures land in $WORK/digblend/<TAG>/png.
#   WORK=$SCRATCH/vis LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/digblend.sh <engine> [TAG]
#   DB_PARAMS='("out", 200.0)'   probe params (see digblendprobe.lua)
#   PATCHES="a.patch b.patch"   applied to the scratch copy (A/B a change without touching Solar)
#   EDITOR=1   run `floptle <proj> --auto-play` (the editor, as the player plays) instead of `play`
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:-digblend}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/digblendproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$SOL/tools/perf/digblendprobe.lua" "$PJ/scripts/"
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/digblendprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/digblend"
# SAVE_SRC: whose save to copy (default Solar's own; the exported build keeps
# its in ~/.local/share/solar). Only ever read.
SV=${SAVE_SRC:-$SOL}
cp "$SV/save/slot1.ron" "$PJ/save/slot1.ron"; cp -r "$SV/saves/slot1" "$PJ/saves/slot1"
[ "${NOSETTINGS:-0}" = 1 ] || cp "$SV/save/settings.ron" "$PJ/save/settings.ron"
cat > "$PJ/scenes/digblendprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Dig Blend Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "digblendprobe", enabled: true, params: [${DB_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/digblend/$TAG; mkdir -p "$OUT"
if [ "${EDITOR:-0}" = 1 ]; then CMD="$F $PJ --auto-play"; else CMD="$F play $PJ"; fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-240} $CMD > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/digblend/*.png "$OUT/png/" 2>/dev/null
# the probe's save copies go: nothing of the player's is kept in the scratch project
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/digblend"
grep -a "DB \|ERROR\|error" "$OUT/run.log" | cut -c1-400 | tail -60
