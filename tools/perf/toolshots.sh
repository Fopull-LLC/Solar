#!/bin/bash
# toolshots.sh — one silent `floptle play` of toolshots.lua on a COPY of the player's
# save, under the shared engine lock. Pictures land in $WORK/look/<TAG>/png.
#   WORK=$SCRATCH/ground LOCK=$SCRATCH/engine.lock tools/perf/look.sh <engine> [TAG]
#   SHOT_PARAMS='("occl", 0.0), ("weather", 1.0)'   probe params (see toolshots.lua)
#   BEFORE=1   the tools as committed (HEAD's models/tools, Tool* prefabs, tool_belt.lua, textures/tools)
#   EDITOR=1   run `floptle <proj> --auto-play` (the editor, as the player plays) instead of `play`
#   PROTOS=DIR VARIANT=A   the laser as design A (gen_tools.py --protos DIR): its models,
#              its prefabs as ToolLaser / ToolLaserFP and its RIG lines in tool_belt
#   SHOT_PARAMS='("mode", 1.0)'   the ENERGY set instead (toolshots.lua mode 1):
#              each tool idle and working, first and third person, in daylight
#              and then in shade (a probe canopy between the crew and the sun)
#   XWAYLAND=   run on native Wayland (the default is XWayland, for frame timing;
#               XWayland would not make a GPU device while the screen was locked)
set -u
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:-look}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
PJ=$WORK/toolshotsproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle"
# models/ and textures/ are real folders of links, so BEFORE=1 can swap the tools in
for d in models textures; do
  [ -L "$PJ/$d" ] && rm "$PJ/$d"
  rm -rf "$PJ/$d"; mkdir -p "$PJ/$d"
  for e in "$SOL/$d"/*; do ln -s "$e" "$PJ/$d/$(basename "$e")"; done
done
for d in animation_controllers animations audio docs fonts materials shaders terrain tests tools ui vfx input.ron .luarc.json; do
  [ -e "$PJ/$d" ] || ln -s "$SOL/$d" "$PJ/$d"
done
rm -rf "$PJ/scripts" "$PJ/scenes" "$PJ/prefabs"
mkdir -p "$PJ/scripts" "$PJ/scenes"
cp "$SOL"/scripts/*.lua "$PJ/scripts/"; cp -r "$SOL/prefabs" "$PJ/prefabs"; cp "$SOL"/scenes/*.ron "$PJ/scenes/"
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null; cp -r "$SOL/.floptle/library" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
cp "$SOL/tools/perf/toolshots.lua" "$PJ/scripts/"
# models/tools is a real folder of links too: a VARIANT's models are added
# there, never into Solar's own models/tools through a linked folder
rm "$PJ/models/tools"; mkdir -p "$PJ/models/tools"
for e in "$SOL/models/tools"/*; do ln -s "$e" "$PJ/models/tools/$(basename "$e")"; done
if [ "${BEFORE:-0}" = 1 ]; then
  rm -f "$PJ"/models/tools/*
  (cd "$SOL" && git ls-tree --name-only HEAD models/tools/) | while read f; do (cd "$SOL" && git show "HEAD:$f") > "$PJ/$f"; done
  for f in ToolGravGun ToolLaser ToolGravGunFP ToolLaserFP; do (cd "$SOL" && git show "HEAD:prefabs/$f.prefab.ron") > "$PJ/prefabs/$f.prefab.ron"; done
  (cd "$SOL" && git show HEAD:scripts/tool_belt.lua) > "$PJ/scripts/tool_belt.lua"
  rm -f "$PJ/textures/tools"; mkdir -p "$PJ/textures/tools"
  (cd "$SOL" && git ls-tree --name-only HEAD textures/tools/) | while read f; do (cd "$SOL" && git show "HEAD:$f") > "$PJ/$f"; done
fi
if [ -n "${VARIANT:-}" ]; then
  P2=${PROTOS:?PROTOS=DIR with VARIANT}
  for e in "$P2"/models/tools/*; do ln -sf "$e" "$PJ/models/tools/$(basename "$e")"; done
  sed "s/ToolLaser${VARIANT}FP/ToolLaserFP/; s/ToolLaser${VARIANT}\"/ToolLaser\"/" "$P2/prefabs/ToolLaser${VARIANT}.prefab.ron" > "$PJ/prefabs/ToolLaser.prefab.ron"
  sed "s/ToolLaser${VARIANT}FP/ToolLaserFP/" "$P2/prefabs/ToolLaser${VARIANT}FP.prefab.ron" > "$PJ/prefabs/ToolLaserFP.prefab.ron"
  python3 - "$PJ/scripts/tool_belt.lua" "$P2/rig_${VARIANT}.txt" <<'PY'
import sys
tb, rig = sys.argv[1], open(sys.argv[2]).read().splitlines()
L = open(tb).read().split("\n")
hits = [i for i, l in enumerate(L) if l.startswith("  laser   = { grip")][:2]
for i, new in zip(hits, rig):
    L[i] = new
open(tb, "w").write("\n".join(L))
PY
fi
# the shade canopy the energy set stands the crew under (a static box, so
# it shades the view model through the shadow proxies too; moved every frame)
cat > "$PJ/prefabs/ProbeShade.prefab.ron" <<'RON'
[
    (
        name: "ProbeShade",
        transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
        matter: Empty,
        scripts: [],
        rigidbody: Some(( boxed: true, mode: Static, radius: 0.5, height: 1.0, half_extents: (2.0, 0.04, 2.0),
            restitution: 0.0, friction: 0.9, gravity: false, lock_pos: (false, false, false), lock_rot: (false, false, false) )),
    ),
    (
        name: "ProbeShadeSlab",
        transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (4.0, 0.08, 4.0) ),
        matter: Primitive( shape: Cube, color: (0.3, 0.3, 0.3) ),
        scripts: [],
        parent: Some(0),
    ),
]
RON
for p in ${PATCHES:-}; do (cd "$PJ" && patch -s -p1 --no-backup-if-mismatch < "$p") || echo "PATCH FAILED $p"; done
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/toolshots.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/toolshots"
cp "$SOL/save/slot1.ron" "$PJ/save/slot1.ron"; cp -r "$SOL/saves/slot1" "$PJ/saves/slot1"
[ "${NOSETTINGS:-0}" = 1 ] || cp "$SOL/save/settings.ron" "$PJ/save/settings.ron"
cat > "$PJ/scenes/toolshots.ron" <<RON
(
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Tool Shots", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "toolshots", enabled: true, params: [${SHOT_PARAMS:-}] ) ] ),
    ],
)
RON
OUT=$WORK/toolshots/$TAG; mkdir -p "$OUT"
if [ "${EDITOR:-0}" = 1 ]; then CMD="$F $PJ --auto-play"; else CMD="$F play $PJ"; fi
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env ${XWAYLAND-"-u WAYLAND_DISPLAY"} ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-240} $CMD > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/toolshots/*.png "$OUT/png/" 2>/dev/null
# the probe's save copies go: nothing of the player's is kept in the scratch project
rm -f "$PJ/save/slot1.ron" "$PJ/save/settings.ron"; rm -rf "$PJ/saves/slot1" "$PJ/save/user/toolshots"
grep -a "TSG \|ERROR\|error" "$OUT/run.log" | cut -c1-400 | tail -60
