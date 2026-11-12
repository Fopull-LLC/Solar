#!/bin/bash
# scnuishots.sh — the scenario screens in the real game (tools/perf/scnuiprobe.lua):
# the menu's SCENARIOS row and page, PLAY into slot scn, the curtain line,
# BRIEFING, the Ops strip and the SCENARIO chip, a dialogue line and a choice,
# a cutscene's letterbox, DEBRIEF, the controls page. Silent, under the shared lock.
#
#   WORK=<private dir> LOCK=/mnt/disks/3tb/.floptle-shared/engine2.lock tools/perf/scnuishots.sh <engine> [TAG]
#   env: PATCHES (unified diffs applied to the scratch copy), SCN_PARAMS ('("id", "two_rooms")' …),
#        TMO (seconds, default 420)
#
# Scenarios: the checkout's scenarios/ plus the fixtures in tools/perf/scnui_fixtures/
# (fx_*.lua: a list with a lock and a long title). With no scripts/scenario.lua
# in the checkout yet (FW-A not merged), tools/perf/scnui_stub_scenario.lua
# stands in for it, in the scratch copy only.
#
# Pictures land in $WORK/scnuishots/<TAG>/png (name_1080.png, name_1440.png),
# the log in run.log ("SCNUI " lines). The scratch project has REAL save/ and
# saves/ folders; slot scn, its terrain, the profile and the pictures' copies
# are deleted afterwards. Solar's own saves are never touched.
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
WORK=${WORK:?WORK}
PJ=$WORK/scnuiproj
LOCK=${LOCK:-$WORK/engine.lock}
eng=${1:?usage: scnuishots.sh <engine> [TAG]}; TAG=${2:-$(date +%H%M%S)}
if [ -x "$eng" ]; then F=$eng; else F=$HOME/.local/share/floptle/versions/$eng/floptle; fi
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
[ -f "$ALSA" ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > "$ALSA"
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
for d in animation_controllers animations audio docs fonts materials models shaders terrain tests textures tools ui vfx input.ron .luarc.json; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs" "$PJ/scenarios"
mkdir -p "$PJ/scripts" "$PJ/scenes" "$PJ/scenarios"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
[ -d "$SOL/scenarios" ] && cp -r "$SOL/scenarios/." "$PJ/scenarios/"
cp "$HERE"/scnui_fixtures/*.lua "$PJ/scenarios/"
if [ ! -f "$PJ/scripts/scenario.lua" ]; then
  # the stand-in rulebook, with the fixtures inlined (no loadfile in the game's VM)
  { echo "FIX = {}"
    for f in "$HERE"/scnui_fixtures/*.lua; do
      echo "FIX[\"$(basename "$f" .lua)\"] = (function()"; cat "$f"; echo "end)()"
    done
    cat "$HERE/scnui_stub_scenario.lua"; } > "$PJ/scripts/scenario.lua"
fi
if [ ! -f "$PJ/prefabs/ScenarioLib.prefab.ron" ]; then
  cat > "$PJ/prefabs/ScenarioLib.prefab.ron" <<'RON'
[
    (
        name: "ScenarioLib",
        transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
        matter: Empty,
        scripts: [ ( kind: "scenario", enabled: true, params: [] ) ],
    ),
]
RON
fi
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$HERE/scnuiprobe.lua" "$PJ/scripts/"
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/scnuiprobe.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -rf "$PJ/save/user/scnuishots" "$PJ/save/user/scenarios"
rm -f "$PJ/save/scn.ron"; rm -rf "$PJ/saves/scn"
cat > "$PJ/scenes/scnuiprobe.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Scenario UI Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "scnuiprobe", enabled: true, params: [], strs: [${SCN_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/scnuishots/$TAG; mkdir -p "$OUT"
# SIZE=WxH (storypolish): played offscreen at exactly that screen (`floptle shot
# --after … --size`), so the interface's Auto scale is the real one for that
# screen (a capture at another size keeps the window's); pass ("native", "1")
# in SCN_PARAMS for one picture a pose at that size.
RUNCMD="$F play $PJ"
[ -n "${SIZE:-}" ] && RUNCMD="$F shot $PJ --scene scnuiprobe --after ${AFTER:-${TMO:-420}}s --size $SIZE --out $OUT/last_$SIZE.png"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-420} $RUNCMD > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/scnuishots/*.png "$OUT/png/" 2>/dev/null
# the probe's saves go: slot scn, its terrain, the profile, the pictures' copies
rm -f "$PJ/save/scn.ron"; rm -rf "$PJ/saves/scn" "$PJ/save/user/scnuishots" "$PJ/save/user/scenarios" "$PJ/save/user/farlod/scn"
grep -a "SCNUI \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-400 | tail -80
