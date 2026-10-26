#!/bin/bash
# toolstand.sh — the hand tools on a bench (toolstand.lua): one silent
# `floptle play` of an empty scene under the shared engine lock, no save.
#   WORK=$SCRATCH/x LOCK=$SCRATCH/engine.lock tools/perf/toolstand.sh <engine> [TAG]
# Pictures land in $WORK/toolstand/<TAG>/.
#   PROTOS=DIR   the laser design sheet instead: DIR is `gen_tools.py --protos DIR`'s
#                output (ToolLaser<V>[FP] for V in TL7 A B C), shot side by side
#                with the gravity gun under one light (toolstand.lua protos=1)
#   STAND_PARAMS='("charge", 0.8)'   extra probe params (see toolstand.lua)
#   XWAYLAND=   run on native Wayland (the default is XWayland, for frame timing;
#               XWayland would not make a GPU device while the screen was locked)
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:-stand}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/standproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
# models/ and models/tools are real folders of links, so PROTOS can add designs
[ -L "$PJ/models" ] && rm "$PJ/models"
rm -rf "$PJ/models"; mkdir -p "$PJ/models/tools"
for e in "$SOL/models"/*; do [ "$(basename "$e")" = tools ] || ln -s "$e" "$PJ/models/$(basename "$e")"; done
for e in "$SOL/models/tools"/*; do ln -s "$e" "$PJ/models/tools/$(basename "$e")"; done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$SOL/tools/perf/toolstand.lua" "$PJ/scripts/"
if [ -n "${PROTOS:-}" ]; then
  for e in "$PROTOS"/models/tools/*; do ln -sf "$e" "$PJ/models/tools/$(basename "$e")"; done
  cp "$PROTOS"/prefabs/*.prefab.ron "$PJ/prefabs/"
  STAND_PARAMS="(\"protos\", 1.0)${STAND_PARAMS:+, $STAND_PARAMS}"
fi
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/toolstand.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
# tool_belt's framing numbers, as the game has them
TB=$SOL/scripts/tool_belt.lua
num() { grep -o "$1" "$TB" | head -1 | grep -oE -- '-?[0-9.]+' | tr '\n' ' '; }
read VAX VAY VAZ <<< "$(num 'local VIEW_AT = {[^}]*}')"
read VMF <<< "$(num 'local VM_FOV = [0-9.]*')"
read TOE <<< "$(num 'local VIEW_TOE = [0-9.]*')"
read CANT <<< "$(num 'local VIEW_CANT = -*[0-9.]*')"
read GGX GGY GGZ <<< "$(awk '/^RIG_FP = /{f=1} f&&/gravgun/{print; exit}' "$TB" | grep -o 'grip = {[^}]*}' | grep -oE -- '-?[0-9.]+' | tr '\n' ' ')"
read LGX LGY LGZ <<< "$(awk '/^RIG_FP = /{f=1} f&&/laser/{print; exit}' "$TB" | grep -o 'grip = {[^}]*}' | grep -oE -- '-?[0-9.]+' | tr '\n' ' ')"
P="(\"toe\", ${TOE:-7.0}), (\"cant\", ${CANT:-0.0}), (\"vax\", $VAX), (\"vay\", $VAY), (\"vaz\", $VAZ), (\"vmfov\", $VMF), (\"ggx\", $GGX), (\"ggy\", $GGY), (\"ggz\", $GGZ), (\"lgx\", $LGX), (\"lgy\", $LGY), (\"lgz\", $LGZ)${STAND_PARAMS:+, $STAND_PARAMS}"
cat > "$PJ/scenes/toolstand.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 0.6, active: true ), scripts: [] ),
        ( name: "Tool Stand", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "toolstand", enabled: true, params: [$P] ) ] ),
    ],
)
RON
OUT=$WORK/toolstand/$TAG; mkdir -p "$OUT"
rm -rf "$PJ/save/user/toolstand"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env ${XWAYLAND-"-u WAYLAND_DISPLAY"} ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-180} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
cp "$PJ"/save/user/toolstand/*.png "$OUT/" 2>/dev/null
rm -rf "$PJ/save/user/toolstand"
grep -a "TS \|ERROR\|error\|warn" "$OUT/run.log" | cut -c1-300 | tail -60
echo "pictures: $OUT"
