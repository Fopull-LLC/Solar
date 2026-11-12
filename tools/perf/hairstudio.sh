#!/bin/bash
# hairstudio.sh — the long hair styles on a plain stage, no world (tools/perf/hairstudio.lua).
#   WORK=$SCRATCH/hair tools/perf/hairstudio.sh <engine> <case> [n] [style]
#   case: styles | motion | perf | helmet.  Pictures: $WORK/hairstudio/<case>/*.png
#   env: LOCK (the shared engine lock), ALSA (the silent config), TMO
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine}; CASE=${2:-styles}; N=${3:-6}; STYLE=${4:-long}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:-/mnt/disks/3tb/.floptle-shared/engine.lock}
ALSA=${ALSA:-/mnt/disks/3tb/.floptle-shared/silent-alsa.conf}
[ -f $ALSA ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > $ALSA
PJ=$WORK/hairstudioproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in models textures animation_controllers animations audio docs fonts materials shaders terrain tests tools ui vfx input.ron .luarc.json; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"; mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"; cp "$SOL/tools/perf/hairstudio.lua" "$PJ/scripts/"
python3 "$SOL/tools/perf/facestudio_scene.py" "$PJ/scenes/hairstudio.ron" "$N" "$CASE" hairstudio >/dev/null || exit 1
sed -i "s/strs: \[(\"case\", \"$CASE\")\]/strs: [(\"case\", \"$CASE\"), (\"style\", \"$STYLE\")]/" "$PJ/scenes/hairstudio.ron"
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/hairstudio.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/hairstudio"
OUT=$WORK/hairstudio/$CASE; mkdir -p "$OUT"; rm -f "$OUT"/*.png
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-300} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'"
cp "$PJ"/save/user/hairstudio/*.png "$OUT/" 2>/dev/null
rm -rf "$PJ/save/user/hairstudio"
grep -a "HAIR \|ERROR\|error\|panick\|spring" "$OUT/run.log" | cut -c1-300 | tail -80
ls "$OUT" | head -50
