#!/bin/bash
# exportshot.sh — pictures from an exported build's PLAYER (engine card 0550:
# textures sampled as in Play). Copies the build's assets/ to a scratch project,
# adds exportshot.lua as the entry scene and a COPY of the player's save, and
# plays it with the build's own binary (`<build>/<Title> <project>`), with
# XDG_DATA_HOME in scratch so no real player data is read or written. Runs
# twice: with the build's .floptle/textures.ron and without it (the old export).
#   WORK=$SCRATCH/export LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/exportshot.sh <build dir> <binary name>
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${1:?build dir}; BIN=${2:-Solar}
WORK=${WORK:?WORK}; LOCK=${LOCK:?LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
for v in with without; do
  PJ=$WORK/xs-$v; rm -rf "$PJ"; mkdir -p "$PJ"
  cp -r "$BUILD/assets/." "$PJ/"
  [ $v = without ] && rm -f "$PJ/.floptle/textures.ron"
  cp "$SOL/tools/perf/exportshot.lua" "$PJ/scripts/"
  mkdir -p "$PJ/save" "$PJ/saves" "$WORK/xdg-$v"
  cp "$SOL/save/slot1.ron" "$SOL/save/settings.ron" "$PJ/save/"; cp -r "$SOL/saves/slot1" "$PJ/saves/slot1"
  sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/exportshot.ron\")#" "$PJ/project.ron"
  cat > "$PJ/scenes/exportshot.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Export Shot", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "exportshot", enabled: true, params: [], strs: [] ) ] ),
    ],
)
RON
  flock "$LOCK" bash -c "uptime; env -u WAYLAND_DISPLAY XDG_DATA_HOME='$WORK/xdg-$v' ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-240} '$BUILD/$BIN' '$PJ' > '$WORK/xs-$v.log' 2>&1; echo exit \$?"
  mkdir -p "$WORK/png-$v"
  find "$PJ" "$WORK/xdg-$v" -path '*exportshot/*.png' -exec cp {} "$WORK/png-$v/" \;
  grep -a "XS \|rror" "$WORK/xs-$v.log" | head -20
  # the save copies go
  rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1"
done
