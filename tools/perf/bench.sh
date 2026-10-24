#!/bin/bash
# bench.sh — Solar's repeatable frame-time benchmark.
#
#   bench.sh <engine> [mode ...]
#     engine : a version under ~/.local/share/floptle/versions (e.g. 0.117.0-rc10)
#              or a path to a floptle binary
#     mode   : base rocket plane rover builder (default: all five, in that order)
#   env: WORK (scratch dir, default $TMPDIR/solar-perf), LOCK (engine lock file),
#        TMO (per-run timeout s, default 330), SOLAR (Solar checkout, default the repo),
#        TAG (results name, default the engine version + time), KEEP=1 keeps the probe slot
#
# Each mode is one `floptle play` of a scratch copy of Solar whose entry scene is
# perfbench.lua; each runs under the shared engine lock, silent. Results:
#   $H/results/<TAG>/<mode>.log    the full log
#   $H/results/<TAG>/bench.jsonl   one JSON object per scenario (+ uptime)
#   $H/results/<TAG>/table.md      the scenario table, buckets and top scripts
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
# WORK: where the scratch project and results live (never inside the repo).
# LOCK: a lock file shared by everything that runs the engine on this machine.
S=${WORK:-${TMPDIR:-/tmp}/solar-perf}
H=$S
PJ=$H/proj
LOCK=${LOCK:-$S/engine.lock}
mkdir -p $S
eng=${1:?usage: bench.sh <engine version or binary> [modes]}; shift
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
[ -x "$F" ] || { echo "no engine binary at $F"; exit 2; }
MODES=${*:-base rocket plane rover builder}
TAG=${TAG:-$VER-$(date +%m%d-%H%M)}
OUT=$H/results/$TAG; mkdir -p $OUT
[ -f $S/silent-alsa.conf ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > $S/silent-alsa.conf

# ── the scratch project: assets linked, scripts/scenes/prefabs/project.ron copied ──
mkdir -p $PJ/save $PJ/saves $PJ/.floptle
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  [ -e $PJ/$d ] || ln -s $SOL/$d $PJ/$d
done
rm -rf $PJ/scripts $PJ/scenes $PJ/prefabs
mkdir -p $PJ/scripts $PJ/scenes
cp $SOL/scripts/*.lua $PJ/scripts/
cp -r $SOL/prefabs $PJ/prefabs
cp $SOL/scenes/*.ron $PJ/scenes/
cp $SOL/.floptle/textures.ron $PJ/.floptle/ 2>/dev/null
cp -r $SOL/.floptle/library $PJ/.floptle/ 2>/dev/null
cp $SOL/project.ron $PJ/project.ron
cp $HERE/perfbench.lua $PJ/scripts/
# Solar-side patches under test (PATCHES="a.patch b.patch")
for p in ${PATCHES:-}; do (cd $PJ && patch -s -p1 --no-backup-if-mismatch < $p) || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/perfbench.ron\")#" $PJ/project.ron
# vsync Off by default: a measurement of the machine, not of the display's pacing (VSYNC=On to keep the game's)
sed -i "s#vsync: [A-Za-z]*#vsync: ${VSYNC:-Off}#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron

# ENVX: extra environment for the engine (e.g. "env -u WAYLAND_DISPLAY" for XWayland)
ENVX=${ENVX:-env -u WAYLAND_DISPLAY}   # XWayland: KWin throttles a Wayland window to 20 fps while the screen is locked
echo "bench: engine $VER ($F), modes: $MODES, results in $OUT"
for m in $MODES; do
  cat > $PJ/scenes/perfbench.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Perf Bench", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "perfbench", enabled: true, params: [${BENCH_PARAMS:-}], strs: [ ("mode", "$m") ] ) ] ),
    ],
)
RON
  rm -f $PJ/save/slot13.ron; rm -rf $PJ/saves/slot13
  start=$(date +%s)
  flock $LOCK bash -c "uptime > $OUT/$m.uptime; $ENVX ALSA_CONFIG_PATH=$S/silent-alsa.conf timeout ${TMO:-330} $F play $PJ > $OUT/$m.log 2>&1; echo \$? > $OUT/$m.exit; uptime >> $OUT/$m.uptime"
  echo "  $m: exit $(cat $OUT/$m.exit) after $(( $(date +%s) - start )) s (incl. lock wait); load $(head -1 $OUT/$m.uptime | sed 's/.*load average: //')"
  grep -a "PB .*\(RESULT \[\|TIMEOUT\|ERROR\|DONE\|ROCKET\|PLANE\|ROVER\|ORBIT\|MECO\|DIG\|BIG\)\|watchdog\|without returning" $OUT/$m.log | grep -v "worst #\|counts mean\|scripts/frame\|buckets/frame\|frames over" | head -40
  python3 - "$OUT" "$m" <<'PY'
import json, sys
out, m = sys.argv[1], sys.argv[2]
up = open(f"{out}/{m}.uptime").read().split("\n")
with open(f"{out}/bench.jsonl", "a") as f:
    for line in open(f"{out}/{m}.log", errors="replace"):
        i = line.find("BENCHJSON ")
        if i >= 0:
            try:
                d = json.loads(line[i + 10:])
            except Exception as e:
                print("bad json", e); continue
            d["uptime_before"] = up[0].split("load average:")[-1].strip()
            d["uptime_after"] = (up[1] if len(up) > 1 else "").split("load average:")[-1].strip()
            f.write(json.dumps(d) + "\n")
PY
done
[ -n "${KEEP:-}" ] || { rm -f $PJ/save/slot13.ron; rm -rf $PJ/saves/slot13; }
python3 $HERE/table.py $OUT/bench.jsonl > $OUT/table.md && cat $OUT/table.md
