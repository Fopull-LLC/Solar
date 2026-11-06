#!/bin/bash
# popprobe.sh — do plants pop in and out round the base while nothing moves?
# (tools/perf/popprobe.lua, pop.py; 2026-11-03). A NEW Career save, silent,
# under the shared engine lock; the player's settings.json COPIED in
# (fullscreen off).
#
#   WORK=$SCRATCH/pop LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/popprobe.sh <engine> [TAG]
#   env: USERSAVE=1 (a COPY of Solar/save/slot1.ron + saves/slot1, with POP_PARAMS '("usersave", 1.0)'),
#        POP_PARAMS (e.g. '("phases", 6.0), ("secs", 40.0)'), PATCHES (applied to the scratch copy),
#        SETTINGS (default ~/.local/share/solar/user/settings.json), TMO (s, default 340), KEEP=1 keeps the frames
#
# Lines "POP " in $WORK/pop/<TAG>/run.log; frames under frames/, pop.py's table in pops.txt.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/popproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: popprobe.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
if [ -x "$eng" ]; then F=$eng; else F=$HOME/.local/share/floptle/versions/$eng/floptle; fi
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$HERE/popprobe.lua" "$PJ/scripts/"
mkdir -p "$PJ/save/user"
python3 - "${SETTINGS:-$HOME/.local/share/solar/user/settings.json}" "$PJ/save/user/settings.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
d["opt_fullscreen"] = False
json.dump(d, open(sys.argv[2], "w"))
PY
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/popprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/pop"
rm -f "$PJ/save/slot1.ron"; rm -rf "$PJ/saves/slot1"
# (USERSRC, USERSLOT: whose save, default Solar's slot1; the exported build's is ~/.local/share/solar)
if [ "${USERSAVE:-0}" = 1 ]; then US=${USERSRC:-$SOL}; UL=${USERSLOT:-slot1}
  cp "$US/save/$UL.ron" "$PJ/save/slot1.ron"; [ -d "$US/saves/$UL" ] && cp -r "$US/saves/$UL" "$PJ/saves/slot1"; fi
cat > "$PJ/scenes/popprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Pop Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "popprobe", enabled: true, params: [${POP_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/pop/$TAG; mkdir -p "$OUT"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-340} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
rm -rf "$OUT/frames"; [ -d "$PJ/save/user/pop" ] && mv "$PJ/save/user/pop" "$OUT/frames"
# the probe's save goes: its slot file, its terrain, the copied settings
rm -f "$PJ"/save/slot18.ron "$PJ/save/user/settings.json" "$PJ/save/slot1.ron"; rm -rf "$PJ/saves/slot18" "$PJ/save/user/farlod/slot18" "$PJ/saves/slot1" "$PJ/save/user/farlod/slot1"
grep -a "POP \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-500 | tail -150
[ -d "$OUT/frames" ] && python3 "$HERE/pop.py" "$OUT/frames" > "$OUT/pops.txt" && cat "$OUT/pops.txt"
