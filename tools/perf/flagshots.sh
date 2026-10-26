#!/bin/bash
# flagshots.sh — the agency's name and emblem, the new-save panel, flags and
# the Tracking Station in the real game (tools/perf/flagprobe.lua), on a NEW
# save, silent, under the shared lock. tools/perf/flag_logo.png goes into the
# scratch project's user://emblems/ as the "player's own picture".
#
#   WORK=$SCRATCH/ws4 LOCK=$SCRATCH/engine.lock tools/perf/flagshots.sh <engine> [TAG]
#   env: PATCHES (unified diffs applied to the scratch copy, e.g. tool_belt.patch),
#        FLAG_PARAMS ('("seed", 99.0)' …), TMO (seconds, default 360)
#
# Pictures land in $WORK/flagshots/<TAG>/png, the log in run.log ("FLG " and
# "RESULT" lines). The scratch project gets REAL save/ and saves/ folders;
# its probe slot is deleted afterwards. Solar's own saves are never touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/flagproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: flagshots.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
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
cp "$HERE/flagprobe.lua" "$PJ/scripts/"
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/flagprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/flagshots"
mkdir -p "$PJ/save/user/emblems"; cp "$HERE/flag_logo.png" "$PJ/save/user/emblems/flag_logo.png"
cat > "$PJ/scenes/flagprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Flag Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "flagprobe", enabled: true, params: [${FLAG_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/flagshots/$TAG; mkdir -p "$OUT"
# XWayland by default (frame timing); XW=0 keeps the native Wayland window
if [ "${XW:-1}" = 1 ]; then UNW="env -u WAYLAND_DISPLAY"; else UNW=env; fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; $UNW ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-360} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/flagshots/*.png "$OUT/png/" 2>/dev/null
cp "$PJ"/save/user/flags/slot15/*.jpg "$OUT/png/" 2>/dev/null   # the flags' own photos
# the probe's save goes: its slot file, its terrain, the pictures' copies
rm -f "$PJ"/save/slot15.ron; rm -rf "$PJ/saves/slot15" "$PJ/save/user/flagshots" "$PJ/save/user/farlod/slot15" "$PJ/save/user/flags/slot15" "$PJ/save/user/agency"
grep -a "FLG \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-600 | tail -80
