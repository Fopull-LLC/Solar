#!/bin/bash
# renderfix.sh — Ty's 2026-11-12 render issues: fog brightness, light/fog flicker, rover
# lights, floating rocks (tools/perf/renderfix.lua). A NEW Career save, silent, under the
# shared lock pool.
#
#   WORK=$SCRATCH LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/renderfix.sh <engine> <mode> [TAG]
#   modes: fog | flick | lights | rocks
#   env: RF_PARAMS   extra probe params, e.g. '("shadowmap", 0.0), ("secs", 30.0)'
#        RF_STRS     text params, e.g. '("sweep", "fogLight=0.75,0.3")'
#        DUMP=1      (flick) dump the WINDOW's frames between the probe's DUMP ON / DUMP OFF
#                    lines (FLOPTLE_FRAME_DUMP, gated: the dump folder only exists while the
#                    probe asks for it), then rf_frames.py tabulates frame-to-frame luma
#        SETTINGS    settings.json to copy in (default ~/.local/share/solar/user/settings.json)
#        TMO         seconds (default 340)
# Pictures land in $WORK/rf/<TAG>/shots/, the log in run.log.
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/rfproj${RF_PJ:-}
LOCK=${LOCK:-/mnt/disks/3tb/.floptle-shared/engine.lock}
eng=${1:?usage: renderfix.sh <engine> <mode> [TAG]}; MODE=${2:?mode}; TAG=${3:-$MODE-$(date +%H%M%S)}
if [ -x "$eng" ]; then F=$eng; else F=$HOME/.local/share/floptle/versions/$eng/floptle; fi
ALSA=/mnt/disks/3tb/.floptle-shared/silent-alsa.conf
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json scenarios; do
  [ -e "$SOL/$d" ] || continue
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$HERE/renderfix.lua" "$PJ/scripts/"
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
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/rf.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/rf"
cat > "$PJ/scenes/rf.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "RF Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "renderfix", enabled: true, params: [${RF_PARAMS:-}], strs: [ ("mode", "$MODE"), ${RF_STRS:-} ] ) ] ),
    ],
)
RON
OUT=$WORK/rf/$TAG; rm -rf "$OUT"; mkdir -p "$OUT"
DENV=""; GATE=$OUT/gate
if [ "${DUMP:-0}" = 1 ]; then
  # the gate: a FILE where the dump's folder would be, so every frame's save fails, until
  # the probe logs DUMP ON (the folder is made) and DUMP OFF (a file again)
  : > "$GATE"; DENV="FLOPTLE_FRAME_DUMP=$GATE/frames"
fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY $DENV ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-340} $F play $PJ > '$OUT/run.log' 2>&1 & pid=\$!
  if [ '${DUMP:-0}' = 1 ]; then
    on=0
    while kill -0 \$pid 2>/dev/null; do
      if [ \$on = 0 ] && grep -aq 'DUMP ON' '$OUT/run.log'; then rm -f '$GATE'; mkdir -p '$GATE'; on=1; fi
      if [ \$on = 1 ] && grep -aq 'DUMP OFF' '$OUT/run.log'; then mv '$GATE' '$OUT/dump'; : > '$GATE'; on=2; fi
      sleep 0.2
    done
  fi
  wait \$pid; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
[ -f "$OUT/gate" ] && rm -f "$OUT/gate"
[ -d "$OUT/gate" ] && mv "$OUT/gate" "$OUT/dump"
[ -d "$PJ/save/user/rf/$MODE" ] && mv "$PJ/save/user/rf/$MODE" "$OUT/shots"
# the probe's save goes: its slot file, its terrain, the copied settings
rm -f "$PJ"/save/slot23.ron "$PJ/save/user/settings.json"; rm -rf "$PJ/saves/slot23" "$PJ/save/user/farlod/slot23"
grep -a "RF \|ERROR\|panick" "$OUT/run.log" | grep -v "RF .*LW f" | cut -c1-600 | tail -120
if [ -d "$OUT/dump/frames" ] && [ -f "$HERE/rf_frames.py" ]; then python3 "$HERE/rf_frames.py" "$OUT/dump/frames" "$OUT/run.log" | tee "$OUT/frames.txt"; fi
