#!/bin/bash
# rain.sh — one silent `floptle play` of rainprobe.lua (the weather's haze, the rain on the
# ground, the depth of field) on a COPY of the player's save,
# under the shared engine lock. Pictures land in $WORK/rain/<TAG>/png.
#   WORK=$SCRATCH/rainfx LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/rain.sh <engine> [TAG]
#   RAIN_ONLY=info,wx,splash,dof,gpu,rover   which parts (see rainprobe.lua)
#   RAIN_PARAMS='("gpusecs", 4.0)'          probe params
#   OLD=1   the weather, atmosphere, graphics and sun_flare scripts, the system scene and the
#           shaders as committed (git HEAD): the look before this work, for before/after
#   NOSETTINGS=1 leaves the player's settings out (the graphics level then defaults)
#   PATCHES="a.patch b.patch"                 applied to the scratch copy only
#   EDITOR=1   run `floptle <proj> --auto-play` (the editor, as the player plays) instead of `play`
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:-rain}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/rainproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$SOL/tools/perf/rainprobe.lua" "$PJ/scripts/"
if [ "${OLD:-0}" = 1 ]; then
  for f in scripts/weather.lua scripts/atmosphere.lua scripts/graphics.lua scripts/sun_flare.lua scenes/system.ron; do
    git -C "$SOL" show "HEAD:$f" > "$PJ/$f"
  done
  rm -f "$PJ/scripts/rain_fx.lua"
fi
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/rainprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/rain"
cp "$SOL/save/slot1.ron" "$PJ/save/slot1.ron"; cp -r "$SOL/saves/slot1" "$PJ/saves/slot1"
[ "${NOSETTINGS:-0}" = 1 ] || cp "$SOL/save/settings.ron" "$PJ/save/settings.ron"
cat > "$PJ/scenes/rainprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Rain Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "rainprobe", enabled: true, params: [${RAIN_PARAMS:-}], strs: [ ("only", "${RAIN_ONLY:-info,wx,splash,dof,gpu}") ] ) ] ),
    ],
)
RON
OUT=$WORK/rain/$TAG; mkdir -p "$OUT"
if [ "${EDITOR:-0}" = 1 ]; then CMD="$F $PJ --auto-play"; else CMD="$F play $PJ"; fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-300} $CMD > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/rain/*.png "$OUT/png/" 2>/dev/null
# the probe's save copies go: nothing of the player's is kept in the scratch project
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/rain"
grep -a "RX \|ERROR\|error" "$OUT/run.log" | cut -c1-400 | tail -60
