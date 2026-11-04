#!/bin/bash
# gasshots.sh — the gas loop end to end (tools/perf/gasprobe.lua): a gas bike on the
# builder stand, ridden, serviced (gas on the order), refuelled from a Gas Can, the can filled at the pump, reloaded.
# A NEW Career save, silent, under the shared lock.
#
#   WORK=$SCRATCH/econ LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/gasshots.sh <engine> [TAG]
#   env: PATCHES (unified diffs applied to the scratch copy), GSP_PARAMS, TMO (seconds, default 300)
#
# Pictures land in $WORK/gasshots/<TAG>/png, the log in run.log ("GSP " lines).
#   env: GASBIKE (the craft, default: tools/perf/gasbike.py on the player's bike1.json)
# "RESULT" lines). The scratch project gets REAL save/ and saves/ folders;
# its probe slot is deleted afterwards. Solar's own saves are never touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/gsproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: gasshots.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
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
cp "$HERE/gasprobe.lua" "$PJ/scripts/"
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/gasprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/gasshots"
mkdir -p "$PJ/save/user"
if [ -n "${GASBIKE:-}" ]; then cp "$GASBIKE" "$PJ/save/user/probe_gasbike.json"
else python3 "$HERE/gasbike.py" "$HOME/.local/share/solar/user/library/slot1/bike1.json" "$PJ/save/user/probe_gasbike.json" || exit 2; fi
cat > "$PJ/scenes/gasprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Works Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "gasprobe", enabled: true, params: [${GSP_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/gasshots/$TAG; mkdir -p "$OUT"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; date +start\ %s.%N >> '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-300} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; date +end\ %s.%N >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/gasshots/*.png "$OUT/png/" 2>/dev/null
# the probe's save goes: its slot file, its terrain, the pictures' copies
rm -f "$PJ"/save/slot18.ron; rm -rf "$PJ/saves/slot18" "$PJ/save/user/gasshots" "$PJ/save/user/farlod/slot18" "$PJ/save/user/probe_gasbike.json"
grep -a "GSP \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-600 | tail -80
