#!/bin/bash
# tileprobe.sh — the environment textures' tiling, photographed (tools/perf/tileprobe.lua):
# paving, walls, the VAB, home ground and a slope, at 2 / 15 m and further.
# A NEW Career save (slot 19, seed 5150) with the player's graphics settings,
# silent, under the shared lock.
#
#   WORK=$SCRATCH/tiles LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/tileprobe.sh <engine> [TAG]
#   env: PATCHES (unified diffs applied to the scratch copy), TLP_PARAMS, TMO (s, default 300),
#        SETTINGS (a settings.json; default the exported game's)
#
# Pictures land in $WORK/tiles/<TAG>/png, the log in run.log ("TLP " lines).
# The scratch project has its own save/ and saves/; its probe slot is deleted
# afterwards. Solar's own saves are never touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/tlpproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: tileprobe.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
if [ -x "$eng" ]; then F=$eng; else F=$HOME/.local/share/floptle/versions/$eng/floptle; fi
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
[ -f "$ALSA" ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > "$ALSA"
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders tests textures tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
# the palettes are copied (PATCHES may change them); the terrain fields stay Solar's
rm -rf "$PJ/terrain" "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/terrain" "$PJ/scripts" "$PJ/scenes"
for f in "$SOL"/terrain/*; do case "$f" in *.palette) cp "$f" "$PJ/terrain/";; *) ln -s "$f" "$PJ/terrain/";; esac; done
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$HERE/tileprobe.lua" "$PJ/scripts/"
mkdir -p "$PJ/save/user"
python3 - "${SETTINGS:-$HOME/.local/share/solar/user/settings.json}" "$PJ/save/user/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["opt_fullscreen"] = False
json.dump(d, open(sys.argv[2], "w"))
PY
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/tileprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/tiles"
cat > "$PJ/scenes/tileprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Tile Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "tileprobe", enabled: true, params: [${TLP_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/tiles/$TAG; mkdir -p "$OUT"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-300} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/tiles/*.png "$OUT/png/" 2>/dev/null
# the probe's save goes: its slot file, its terrain, the pictures' copies
rm -f "$PJ"/save/slot19.ron; rm -rf "$PJ/saves/slot19" "$PJ/save/user/tiles" "$PJ/save/user/farlod/slot19"
grep -a "TLP \|ERROR\|panicked" "$OUT/run.log" | cut -c1-300 | tail -70
