#!/bin/bash
# exporttools.sh — in an EXPORTED build's player, does the crew hold a tool you
# can see? (playtest 2026-10-28: "the astronaut holds nothing"). Copies the
# build's assets/ to a scratch project, adds exporttools.lua as its entry scene
# and a COPY of the player's save, and plays it with the build's own binary
# (`<build>/<Title> <project>`), XDG_DATA_HOME in scratch so no real player data
# is read or written. `XT PASS|FAIL` lines and `XT RESULT`; pictures in
# $WORK/xt-png/.
#   WORK=$SCRATCH LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/exporttools.sh <build dir> [binary name]
#   (tools/perf/exportcheck.sh with KEEP=1 leaves a build in $WORK/xc-out)
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${1:?build dir}; BIN=${2:-Solar}
WORK=${WORK:?WORK}; LOCK=${LOCK:?LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
SAVESRC=${SAVESRC:-$SOL}
PJ=$WORK/xt-proj; rm -rf "$PJ" "$WORK/xt-png" "$WORK/xt-xdg"; mkdir -p "$PJ" "$WORK/xt-png" "$WORK/xt-xdg"
cp -r "$BUILD/assets/." "$PJ/"
cp "$SOL/tools/perf/exporttools.lua" "$PJ/scripts/"
mkdir -p "$PJ/save" "$PJ/saves"
cp "$SAVESRC/save/slot1.ron" "$SAVESRC/save/settings.ron" "$PJ/save/"; cp -r "$SAVESRC/saves/slot1" "$PJ/saves/slot1"
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/exporttools.ron\")#" "$PJ/project.ron"
cat > "$PJ/scenes/exporttools.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Export Tools", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "exporttools", enabled: true, params: [], strs: [] ) ] ),
    ],
)
RON
flock "$LOCK" bash -c "uptime; env -u WAYLAND_DISPLAY XDG_DATA_HOME='$WORK/xt-xdg' ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-300} '$BUILD/$BIN' '$PJ' > '$WORK/xt.log' 2>&1; echo exit \$?"
find "$PJ" "$WORK/xt-xdg" -path '*exporttools/*.png' -exec cp {} "$WORK/xt-png/" \;
grep -a "XT \|rror" "$WORK/xt.log" | head -30
# the save copies go
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$WORK/xt-xdg"
grep -aq "XT .*RESULT PASS" "$WORK/xt.log"
