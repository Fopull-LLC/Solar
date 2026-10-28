#!/bin/bash
# quitprobe.sh — does an EXPORTED build exit when the player quits? (engine
# card 0564). Copies the build (binary + assets), adds quitprobe.lua as a node
# in the build's own menu scene, and launches the build's binary the way a
# player does (no project argument), with XDG_DATA_HOME in scratch so no real
# player data is read or written. Each stdout line is stamped with the wall
# clock; the exit is timed against the probe's CLICK line.
#   WORK=$SCRATCH/quit LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock \
#     tools/perf/quitprobe.sh <build dir> [title|pause] [binary name]
#   pause: CONTINUE on a COPY of the player's save/slot1 (put in the scratch data dir).
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${1:?build dir}; MODE=${2:-title}; BIN=${3:-Solar}
WORK=${WORK:?WORK}; LOCK=${LOCK:?LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
B=$WORK/qp-$MODE; rm -rf "$B"; mkdir -p "$B"
cp -r "$BUILD/." "$B/"
A=$B/assets
cp "$SOL/tools/perf/quitprobe.lua" "$A/scripts/"
python3 - "$A/scenes/menu.ron" "$MODE" <<'PY'
import sys
p, mode = sys.argv[1], sys.argv[2]
s = open(p).read()
i = s.index('nodes: [') + len('nodes: [')
node = '''
        ( name: "Quit Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "quitprobe", enabled: true, params: [], strs: [ ("mode", "%s") ] ) ] ),''' % mode
# appended at the END of the list so no parent index moves
j = s.rindex(']')
s = s[:j] + node[1:] + '\n    ' + s[j:]
open(p, 'w').write(s)
PY
X=$WORK/xdg-$MODE; rm -rf "$X"; mkdir -p "$X"
if [ "$MODE" = pause ]; then
  # the build keeps its saves under the data dir (data_id); seeded by a title run
  D=$X/${DATA_ID:-solar}
  mkdir -p "$D/save" "$D/saves"
  cp "$SOL/save/slot1.ron" "$SOL/save/settings.ron" "$D/save/"; cp -r "$SOL/saves/slot1" "$D/saves/slot1"
fi
LOG=$WORK/qp-$MODE.log
flock "$LOCK" bash -c "uptime; cd '$B'; env -u WAYLAND_DISPLAY XDG_DATA_HOME='$X' ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-240} './$BIN' 2>&1 | python3 -u -c '
import sys, time
for l in sys.stdin: sys.stdout.write(\"%.3f %s\" % (time.time(), l)); sys.stdout.flush()
'; echo \"\$(python3 -c \"import time; print(\\\"%.3f\\\" % time.time())\") EXIT \${PIPESTATUS[0]}\"" > "$LOG" 2>&1
grep -a "QP \|EXIT\|rror\|anic" "$LOG" | tail -30
python3 - "$LOG" <<'PY'
import sys, re
c = e = None
for l in open(sys.argv[1], errors='replace'):
    m = re.match(r'([0-9.]+) ', l)
    if not m: continue
    if 'QP' in l and 'CLICK' in l and c is None: c = float(m.group(1))
    if ' EXIT ' in l: e = float(m.group(1)); code = l.split()[-1]
print("QUIT RESULT: click %s, exit %s, %s" % (c, e, ("%.2f s after the click, code %s" % (e - c, code)) if c and e else "no click/exit pair"))
PY
# the save copies go
rm -rf "$X"
