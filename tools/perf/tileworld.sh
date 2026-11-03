#!/bin/bash
# tileworld.sh — terrain textures' tiling on whole worlds (tools/perf/tileworld.lua),
# one silent `floptle play` under the shared engine lock. No save is read or
# written: the probe fills terrain 1 of its own scene from opts that
# alienprobe_dump.lua rolls offline (`before` = no alien formations).
#   WORK=<scratch> LOCK=<lock> tools/perf/tileworld.sh <engine> [TAG] [list]
#   list default: regolith:x:moon,steppe:x:home,alpine:x:home
#   PALETTE=<file>   the palette to draw with (default terrain/system.palette)
#   AP_PARAMS='("first", 1.0), ("last", 4.0)'   probe params (see tileworld.lua)
# Pictures land in $WORK/tworld/<TAG>/png, the log in $WORK/tworld/<TAG>/run.log.
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:-tw}; LIST=${3:-regolith:x:moon,steppe:x:home,alpine:x:home}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/tworldproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle" "$PJ/terrain"
for d in fonts materials models shaders textures input.ron; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
# the probe's own terrain folder: a field it fills is written here, never in Solar's
cp "${PALETTE:-$SOL/terrain/system.palette}" "$PJ/terrain/tileworld.palette"
rm -rf "$PJ/scripts" "$PJ/scenes"; mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/tileworld.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
luajit "$SOL/tools/perf/alienprobe_dump.lua" "$SOL" "$PJ/scripts/worlds.lua" before "$LIST" || exit 1
cat "$PJ/scripts/worlds.lua" "$SOL/tools/perf/tileworld.lua" > "$PJ/scripts/tileworld.lua"; rm "$PJ/scripts/worlds.lua"
cat > "$PJ/scenes/tileworld.ron" <<RON
(
    name: "tileworld",
    lighting: (
        direction: (0.4, 0.9, 0.45), stars: true, color: (1.0, 0.95, 0.88), ambient: (0.05, 0.05, 0.06),
        intensity: 1.0, shadows: true, shadow_softness: 0.35, shadow_strength: 1.0, shadow_distance: 500.0, shadow_map: true,
        fog_color: (0.55, 0.6, 0.7), fog_start: 250.0, fog_end: 1400.0, fog_density: 0.004, fog_height: 6.0, fog_falloff: 8.0,
    ),
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Planet", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Terrain( id: 1 ), scripts: [] ),
        ( name: "Alien Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "tileworld", enabled: true, params: [${AP_PARAMS:-}], strs: [ ("tag", "$TAG") ] ) ] ),
    ],
)
RON
OUT=$WORK/tworld/$TAG; mkdir -p "$OUT"
rm -rf "$PJ/save/user/tworld"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-360} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/tworld/*.png "$OUT/png/" 2>/dev/null
rm -rf "$PJ/save/user/tworld" "$PJ"/terrain/tileworld.*.cfield "$PJ"/terrain/tileworld.*.meta
grep -a "TW \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-300 | tail -80
