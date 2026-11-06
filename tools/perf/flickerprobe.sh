#!/bin/bash
# flickerprobe.sh — does the picture flicker while nothing moves? (tools/perf/flickerprobe.lua, flicker.py;
# engine cards 0616/0617/0618, 2026-11-03). The crew and camera held still at spots in the lab, the depot
# yard, a far view; N consecutive frames each, under several graphics configs; then the per-pixel temporal
# standard deviation (mean, p99) and heat maps. The PLAYER's settings.json is COPIED in (fullscreen off).
# A NEW Career save, silent, under the shared lock.
#
#   WORK=$SCRATCH/flk LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/flickerprobe.sh <engine> [TAG]
#   env: FLK_PARAMS (e.g. '("scout", 1.0)'), SETTINGS (default ~/.local/share/solar/user/settings.json),
#        DUMP=<RAM-disk dir> (with FLK_PARAMS='("dump", 1.0)'): measure the window's frames instead,
#        TMO (seconds, default 340), KEEP=1 keeps the frames, FRAMES=<RAM-disk dir> to write them to
#
# Frames land in $WORK/flicker/<TAG>/frames/<cfg>/<spot>/, the table in table.txt, heat maps in heat/.
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/flkproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: flickerprobe.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
if [ -x "$eng" ]; then F=$eng; else F=$HOME/.local/share/floptle/versions/$eng/floptle; fi
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
[ -f "$ALSA" ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > "$ALSA"
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$HERE/flickerprobe.lua" "$PJ/scripts/"
if [ -d "$PJ/models" ] && [ ! -L "$PJ/models" ]; then rm -rf "$PJ/models"; ln -s "$SOL/models" "$PJ/models"; fi
mkdir -p "$PJ/save/user"
python3 - "${SETTINGS:-$HOME/.local/share/solar/user/settings.json}" "$PJ/save/user/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["opt_fullscreen"] = False
json.dump(d, open(sys.argv[2], "w"))
PY
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/flicker.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/flicker"
# FRAMES=<dir on a RAM disk>: the frames are written there (the game waits for each write to reach
# the disk, and 1,200 PNGs on a busy HDD outlast the run); the folder is linked in as user://flicker
if [ -n "${FRAMES:-}" ]; then rm -rf "$FRAMES"; mkdir -p "$FRAMES"; ln -sfn "$FRAMES" "$PJ/save/user/flicker"; fi
cat > "$PJ/scenes/flicker.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Works Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "flickerprobe", enabled: true, params: [${FLK_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/flicker/$TAG; mkdir -p "$OUT"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; date +start\ %s.%N >> '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ${DUMP:+FLOPTLE_FRAME_DUMP=$DUMP} ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-340} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; date +end\ %s.%N >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
rm -rf "$OUT/frames"
if [ -L "$PJ/save/user/flicker" ]; then rm -f "$PJ/save/user/flicker"; ln -sfn "$FRAMES" "$OUT/frames"
elif [ -d "$PJ/save/user/flicker" ]; then mv "$PJ/save/user/flicker" "$OUT/frames"; fi
# the probe's save goes: its slot file, its terrain, the copied settings
rm -f "$PJ"/save/slot19.ron "$PJ/save/user/settings.json"; rm -rf "$PJ/saves/slot19" "$PJ/save/user/farlod/slot19"
grep -a "FLK \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-400 | tail -80
# DUMP=<RAM-disk dir> with FLK_PARAMS='("dump", 1.0)': the window's own frames, cut into bursts by the DUMP lines
if [ -n "${DUMP:-}" ]; then
  python3 "$HERE/flicker.py" --dump "$DUMP" "$OUT/run.log" "$OUT" && [ "${KEEP:-0}" != 1 ] && rm -rf "$DUMP"
fi
if [ -d "$OUT/frames" ] && [ ! -d "$OUT/frames/scout" ]; then
  if python3 "$HERE/flicker.py" "$OUT/frames/" "$OUT" && [ "${KEEP:-0}" != 1 ]; then
    if [ -L "$OUT/frames" ]; then rm -rf "$FRAMES"; rm -f "$OUT/frames"; else rm -rf "$OUT/frames"; fi
  fi
fi
