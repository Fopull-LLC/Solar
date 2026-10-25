#!/bin/bash
# bench.sh — Solar's repeatable frame-time benchmark.
#
#   bench.sh <engine> [mode ...]
#     engine : a version under ~/.local/share/floptle/versions (e.g. 0.117.0-rc10)
#              or a path to a floptle binary
#     mode   : base rocket plane rover builder (default: all five, in that order);
#              park bigpark gameplay (fresh save or the player's);
#              foot meadow digmeadow (the player's save: set USERSAVE=1)
#   env: WORK (scratch dir, default $TMPDIR/solar-perf), LOCK (engine lock file),
#        TMO (per-run timeout s, default 330; gameplay 900), SOLAR (Solar checkout, default the repo),
#        TAG (results name, default the engine version + time), KEEP=1 keeps the probe slot,
#        USERSAVE=1 copies $SOLAR/save/slot1.ron, save/settings.ron and saves/slot1 into the
#        scratch project (Solar's own are never written) and boots from that copy (slot 1),
#        BENCH_PARAMS extra perfbench params, e.g. '("sleepsecs", 30.0), ("loads", 1.0)'
#        BENCH_STRS extra perfbench strs, e.g. '("where", "walk"), ("toggles", "contact0,flora0")'
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
if [ -n "${USERSAVE:-}" ]; then
  # the player's save, copied: the probe boots slot 1 as the menu's CONTINUE would
  [ -f $SOL/save/slot1.ron ] || { echo "no $SOL/save/slot1.ron"; exit 2; }
  mkdir -p $PJ/save $PJ/saves
  rm -f $PJ/save/slot1.ron; rm -rf $PJ/saves/slot1
  cp $SOL/save/slot1.ron $PJ/save/slot1.ron
  cp $SOL/save/settings.ron $PJ/save/settings.ron 2>/dev/null
  cp -r $SOL/saves/slot1 $PJ/saves/slot1
  BENCH_PARAMS="(\"usersave\", 1.0), (\"slot\", 1.0)${BENCH_PARAMS:+, $BENCH_PARAMS}"
fi
TAG=${TAG:-$VER${USERSAVE:+-user}-$(date +%m%d-%H%M)}
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
          matter: Empty, scripts: [ ( kind: "perfbench", enabled: true, params: [${BENCH_PARAMS:-}], strs: [ ("mode", "$m")${BENCH_STRS:+, $BENCH_STRS} ] ) ] ),
    ],
)
RON
  rm -f $PJ/save/slot13.ron; rm -rf $PJ/saves/slot13
  # a fresh save is a fresh player: no settings slot left over from a USERSAVE run
  # (graphics.lua would read its level instead of picking the screen's default)
  [ -n "${USERSAVE:-}" ] || rm -f $PJ/save/settings.ron
  if [ -n "${USERSAVE:-}" ]; then
    # a fresh copy for every mode: the probe plays on it (launches, digs) and must not carry that over
    rm -f $PJ/save/slot1.ron; rm -rf $PJ/saves/slot1
    cp $SOL/save/slot1.ron $PJ/save/slot1.ron; cp -r $SOL/saves/slot1 $PJ/saves/slot1
  fi
  tmo=${TMO:-330}; [ "$m" = gameplay ] && tmo=${TMO:-900}
  start=$(date +%s)
  flock $LOCK bash -c "uptime > $OUT/$m.uptime; $ENVX ALSA_CONFIG_PATH=$S/silent-alsa.conf timeout $tmo $F play $PJ > $OUT/$m.log 2>&1; echo \$? > $OUT/$m.exit; uptime >> $OUT/$m.uptime"
  echo "  $m: exit $(cat $OUT/$m.exit) after $(( $(date +%s) - start )) s (incl. lock wait); load $(head -1 $OUT/$m.uptime | sed 's/.*load average: //')"
  grep -a "PB .*\(RESULT \[\|RESULT SMOKE\|SETTLE\|SLEEP\|PACING\|TIMEOUT\|ERROR\|DONE\|ROCKET\|PLANE\|ROVER\|GPU\|ORBIT\|MECO\|DIG\|BIG\|GROUND96\|FIELDS\|MEADOW\|PARK\|usersave\)\|watchdog\|without returning" $OUT/$m.log | grep -v "worst #\|counts mean\|scripts/frame\|buckets/frame\|frames over" | head -60
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
[ -n "${KEEP:-}" ] || { rm -f $PJ/save/slot13.ron; rm -rf $PJ/saves/slot13; rm -f $PJ/save/slot1.ron; rm -rf $PJ/saves/slot1; }
python3 $HERE/table.py $OUT/bench.jsonl > $OUT/table.md && cat $OUT/table.md
