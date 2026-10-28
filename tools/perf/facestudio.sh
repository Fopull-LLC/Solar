#!/bin/bash
# facestudio.sh — the crew's faces on a plain stage, no world (tools/perf/facestudio.lua).
#   WORK=$SCRATCH/faces tools/perf/facestudio.sh <engine> <case> [n]
#   case: lineup | expr | rig | perf.  Pictures: $WORK/facestudio/<case>/*.png
#   env: LOCK (the shared engine lock), ALSA (the silent config), ACTOR (expr/rig)
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine}; CASE=${2:-lineup}; N=${3:-8}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:-/mnt/disks/3tb/.floptle-shared/engine.lock}
ALSA=${ALSA:-/mnt/disks/3tb/.floptle-shared/silent-alsa.conf}
[ -f $ALSA ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > $ALSA
PJ=$WORK/facestudioproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in models textures animation_controllers animations audio docs fonts materials shaders terrain tests tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"; mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"; cp "$SOL/tools/perf/facestudio.lua" "$PJ/scripts/"
python3 "$SOL/tools/perf/facestudio_scene.py" "$PJ/scenes/facestudio.ron" "$N" "$CASE" >/dev/null || exit 1
[ -n "${ACTOR:-}" ] && sed -i "s/(\"n\", $N.0)/(\"n\", $N.0), (\"actor\", $ACTOR.0)/" "$PJ/scenes/facestudio.ron"
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/facestudio.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/facestudio"
OUT=$WORK/facestudio/$CASE; mkdir -p "$OUT"; rm -f "$OUT"/*.png
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-240} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'"
cp "$PJ"/save/user/facestudio/*.png "$OUT/" 2>/dev/null
rm -rf "$PJ/save/user/facestudio"
grep -a "FACE \|ERROR\|error\|panick\|warn" "$OUT/run.log" | cut -c1-300 | tail -60
ls "$OUT"
