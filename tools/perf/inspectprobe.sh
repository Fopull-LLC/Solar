#!/bin/bash
# inspectprobe.sh — what an open context menu, terminal or loot panel costs a
# frame (tools/perf/inspectprobe.lua; Ty's playtest 2026-11-11).
#
#   inspectprobe.sh <engine> <case>       case: scn | hollis | base
#   env: WORK (scratch dir), LOCK (an engine slot: the pool takes either),
#        PATCHES (unified diffs applied to the scratch copy, -p1), HOLD (s per
#        panel, default 10), SAMPLE (s of script sampling per panel, 0 = off)
#
# The scratch project has its own save/ and saves/: delete $WORK/proj/save*
# when done. Look for `IP COST`, `IP HOT`, `IP TABLE` and `IP RESULT`.
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
S=${WORK:?WORK}
PJ=$S/proj
LOCK=${LOCK:-/mnt/disks/3tb/.floptle-shared/engine.lock}
eng=${1:?usage: inspectprobe.sh <engine> <case>}; CASE=${2:?case}
if [ -x "$eng" ]; then F=$eng; VER=$(basename $(dirname $eng)); else F=$HOME/.local/share/floptle/versions/$eng/floptle; VER=$eng; fi
mkdir -p $S; [ -f $S/silent-alsa.conf ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > $S/silent-alsa.conf
mkdir -p $PJ/save $PJ/saves $PJ/.floptle $S/logs
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json scenarios; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf $PJ/scripts $PJ/scenes $PJ/prefabs
mkdir -p $PJ/scripts $PJ/scenes
cp $SOL/scripts/*.lua $PJ/scripts/; cp -r $SOL/prefabs $PJ/prefabs; cp $SOL/scenes/*.ron $PJ/scenes/
cp $SOL/.floptle/textures.ron $PJ/.floptle/ 2>/dev/null; cp -r $SOL/.floptle/library $PJ/.floptle/ 2>/dev/null
cp $SOL/project.ron $PJ/project.ron
cp $HERE/inspectprobe.lua $PJ/scripts/
# a patch may touch scenarios/: give the copy its own scenarios folder then
if [ -n "${PATCHES:-}" ]; then rm -f $PJ/scenarios; cp -r $SOL/scenarios $PJ/scenarios; fi
for p in ${PATCHES:-}; do (cd $PJ && patch -p1 --no-backup-if-mismatch -s < $p) || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/inspectprobe.ron\")#" $PJ/project.ron
sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$VER\")#" $PJ/project.ron
cat > $PJ/scenes/inspectprobe.ron <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Inspect Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "inspectprobe", enabled: true, params: [ ("hold", ${HOLD:-10}.0), ("sample", ${SAMPLE:-3}.0) ], strs: [ ("case", "$CASE") ] ) ] ),
    ],
)
RON
LOG=$S/logs/ip-$CASE.log
flock $LOCK bash -c "uptime; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH=$S/silent-alsa.conf timeout ${TMO:-360} $F play $PJ > $LOG 2>&1; echo exit \$?"
grep -a "IP \|ERROR\|error" $LOG | grep -av "^warning" | tail -${TAIL:-80}
echo "log: $LOG"
