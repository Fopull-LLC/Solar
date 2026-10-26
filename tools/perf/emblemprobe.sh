#!/bin/bash
# emblemprobe.sh — time the agency emblem + flag generator in the engine and
# write its pictures (tools/perf/emblemprobe.lua), silent, under the shared
# lock, on the main menu (no save is made).
#
#   WORK=$SCRATCH/emblem LOCK=$SCRATCH/engine.lock tools/perf/emblemprobe.sh <engine> [TAG] [emblem.lua]
#
# The third argument replaces the scratch copy's scripts/emblem.lua (to
# compare a before and an after). Pictures land in $WORK/shots/<TAG>/, the log
# in $WORK/shots/<TAG>/run.log ("EMB " lines).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/embproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: emblemprobe.sh <engine> [TAG] [emblem.lua]}; TAG=${2:-$(date +%H%M%S)}
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
cp "$HERE/emblemprobe.lua" "$PJ/scripts/"
[ -n "${3:-}" ] && cp "$3" "$PJ/scripts/emblem.lua"
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/emblemprobe.ron\")#" "$PJ/project.ron"
sed -i "s#vsync: [A-Za-z]*#vsync: ${VSYNC:-Off}#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/emblemshots" "$PJ/save/user/agency"
cat > "$PJ/scenes/emblemprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Emblem Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "emblemprobe", enabled: true, params: [${EMB_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/shots/$TAG; mkdir -p "$OUT"
if [ "${XW:-1}" = 1 ]; then UNW="env -u WAYLAND_DISPLAY"; else UNW=env; fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; $UNW ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-240} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
cp "$PJ"/save/user/emblemshots/*.png "$OUT/" 2>/dev/null
rm -rf "$PJ/save/user/emblemshots" "$PJ/save/user/agency"
ls "$PJ/save" | grep -v '^user$' | sed 's/^/left in save: /'
grep -a "EMB \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-400 | tail -40
