#!/bin/bash
# demo.sh — a whole player session (tools/perf/demo_probe.lua), silent, under
# the shared engine lock, in a scratch copy of Solar.
#
#   WORK=$SCRATCH/qa LOCK=$SCRATCH/engine.lock tools/perf/demo.sh <engine> [TAG]
#   env: USERSAVE=1   the player's save (a COPY of save/slot1.ron, save/settings.ron
#                     and saves/slot1), loaded as CONTINUE does; otherwise a NEW
#                     save made from the main menu's new-save panel (slot 3)
#        PATCHES      unified diffs applied to the scratch copy
#        DEMO_PARAMS  extra probe params, e.g. '("flysecs", 12.0)'
#        TMO          seconds (default 340)
#
# Pictures in $WORK/demo/<TAG>/png, the log in run.log ("DEMO " lines: RESULT,
# HITCH, LOAD, STATE, MENU). The probe's slot and the save copy are deleted
# afterwards; Solar's own save folders are never written.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/demoproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: demo.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
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
cp "$HERE/demo_probe.lua" "$PJ/scripts/"
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/demoprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
# a clean slate: no slot, no settings (a new player), no pictures
rm -f "$PJ"/save/slot*.ron "$PJ/save/settings.ron"; rm -rf "$PJ"/saves/slot* "$PJ/save/user"
PARAMS="${DEMO_PARAMS:-}"
if [ -n "${USERSAVE:-}" ]; then
  cp "$SOL/save/slot1.ron" "$PJ/save/slot1.ron"
  cp "$SOL/save/settings.ron" "$PJ/save/settings.ron" 2>/dev/null
  cp -r "$SOL/saves/slot1" "$PJ/saves/slot1"
  PARAMS="(\"usersave\", 1.0)${PARAMS:+, $PARAMS}"
fi
cat > "$PJ/scenes/demoprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Demo Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "demo_probe", enabled: true, params: [$PARAMS] ) ] ),
    ],
)
RON
OUT=$WORK/demo/$TAG; mkdir -p "$OUT"
if [ "${XW:-1}" = 1 ]; then UNW="env -u WAYLAND_DISPLAY"; else UNW=env; fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; $UNW ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-340} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/demoshots/*.png "$OUT/png/" 2>/dev/null
# the probe's saves go (slot files, terrain, pictures, flag photos, emblem caches)
rm -f "$PJ"/save/slot*.ron "$PJ/save/settings.ron"; rm -rf "$PJ"/saves/slot* "$PJ/save/user"
grep -a "RESULT\|HITCHES\|TIMES\|LOAD \|ERROR\|TIMEOUT" "$OUT/run.log" | cut -c1-400
echo "--- script errors:"
grep -a -i "error\|attempt to\|stack traceback\|nil value" "$OUT/run.log" | grep -v "ALSA lib\|DEMO.*RESULT" | sort | uniq -c | sort -rn | head -20
