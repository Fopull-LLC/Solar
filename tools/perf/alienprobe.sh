#!/bin/bash
# alienprobe.sh — the alien formations (system_generator ALIEN FORMATIONS)
# filled, timed and photographed, one silent `floptle play` under the shared
# engine lock. No save is read or written: the probe fills terrain 1 of its
# own scene from opts that alienprobe_dump.lua rolls offline.
#   WORK=<scratch> LOCK=<lock> tools/perf/alienprobe.sh <engine> <before|after> [TAG] [list]
#   AP_PARAMS='("first", 1.0), ("last", 4.0)'   probe params (see alienprobe.lua)
# Pictures land in $WORK/alien/<TAG>/png, the log in $WORK/alien/<TAG>/run.log.
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; WHEN=${2:-after}; TAG=${3:-$WHEN}; LIST=${4:-}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/alienproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle" "$PJ/terrain"
for d in fonts materials models shaders textures input.ron; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
# the probe's own terrain folder: a field it fills is written here, never in Solar's
cp "$SOL/terrain/system.palette" "$PJ/terrain/alienprobe.palette"
rm -rf "$PJ/scripts" "$PJ/scenes"; mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/alienprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
luajit "$SOL/tools/perf/alienprobe_dump.lua" "$SOL" "$PJ/scripts/worlds.lua" "$WHEN" $LIST || exit 1
cat "$PJ/scripts/worlds.lua" "$SOL/tools/perf/alienprobe.lua" > "$PJ/scripts/alienprobe.lua"; rm "$PJ/scripts/worlds.lua"
cat > "$PJ/scenes/alienprobe.ron" <<RON
(
    name: "alienprobe",
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
          matter: Empty, scripts: [ ( kind: "alienprobe", enabled: true, params: [${AP_PARAMS:-}], strs: [ ("tag", "$TAG") ] ) ] ),
    ],
)
RON
OUT=$WORK/alien/$TAG; mkdir -p "$OUT"
rm -rf "$PJ/save/user/alien"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-360} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/alien/*.png "$OUT/png/" 2>/dev/null
rm -rf "$PJ/save/user/alien" "$PJ"/terrain/alienprobe.*.cfield "$PJ"/terrain/alienprobe.*.meta
grep -a "AP \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-300 | tail -80
