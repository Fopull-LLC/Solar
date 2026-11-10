#!/bin/bash
# palprobe.sh — one terrain slot per world, photographed (tools/perf/tileworld.lua): the palette
# probe of the worlds plan (W0, wildcard slots) and the slot review of the material library (W1).
# Each world is a plain ball whose whole surface is one slot (surfaceA), with steep ground taken by
# a slope rule (slot BORDER, default 14 granite), so a natural border runs through every view.
# No save is read or written: tileworld.sh's scratch project, silent, under the shared lock.
#
#   WORK=<scratch> LOCK=<lock> tools/perf/palprobe.sh <engine> TAG SLOTS
#     SLOTS: comma list of palette slots, e.g. 22,25,30
#   WILD=21-32   make those palette lines wildcards: their picture and maps are taken off the line
#                (its flags kept) and given back at play by terrain.setSlotMaterial (texture,
#                normalMap, roughnessMap = the line's own files). Compare with the same TAG run
#                without WILD: what differs is what the bridge loses.
#   PALETTE=<file>  the palette to start from (default terrain/system.palette)
#   AP_PARAMS     tileworld params (default dist + border views, settle 2)
#   BORDER=<slot> the slope rule's slot (default 14); TINT (default 0.625: x1.6 = the layer as baked)
# Pictures in $WORK/tworld/<TAG>/png, the log in $WORK/tworld/<TAG>/run.log ("TW " lines).
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:?engine version or binary}; TAG=${2:?tag}; SLOTS=${3:?slots}
if [ -x "$VER" ]; then F=$VER; else F=$HOME/.local/share/floptle/versions/$VER/floptle; fi
WORK=${WORK:?set WORK}; LOCK=${LOCK:?set LOCK}
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
[ -f "$ALSA" ] || printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > "$ALSA"
PJ=$WORK/palproj
mkdir -p "$PJ/save" "$PJ/saves" "$PJ/.floptle" "$PJ/terrain"
for d in fonts materials models shaders textures input.ron; do
  if [ -L "$PJ/$d" ] || [ ! -e "$PJ/$d" ]; then ln -sfn "$SOL/$d" "$PJ/$d"; fi
done
rm -rf "$PJ/scripts" "$PJ/scenes"; mkdir -p "$PJ/scripts" "$PJ/scenes"
rm -f "$PJ"/terrain/*
cp "$SOL/.floptle/textures.ron" "$PJ/.floptle/" 2>/dev/null
cp "$SOL/project.ron" "$PJ/project.ron"
sed -i "s#entry_scene: Some(\"[^\"]*\")#entry_scene: Some(\"scenes/tileworld.ron\")#" "$PJ/project.ron"
EV=$(basename "$(dirname "$F")"); [ -d "$HOME/.local/share/floptle/versions/$EV" ] && sed -i "s#engine_version: Some(\"[^\"]*\")#engine_version: Some(\"$EV\")#" "$PJ/project.ron"
# the palette (wildcard lines stripped of picture and maps) and the WORLDS / WILD tables
python3 -I - "${PALETTE:-$SOL/terrain/system.palette}" "$PJ/terrain/tileworld.palette" "$PJ/scripts/worlds.lua" \
  "$SLOTS" "${WILD:-}" "${BORDER:-14}" "${TINT:-0.625}" <<'PY'
import sys
src, dst, out, slots, wild, border, tint = sys.argv[1:8]
lines = open(src).read().split("\n")
wl = set()
if wild:
    for part in wild.split(","):
        a, _, b = part.partition("-")
        wl.update(range(int(a), int(b or a) + 1))
W = []
for i, line in enumerate(lines, 1):
    if i in wl and line.strip():
        bits = line.split("|")
        path, flags = bits[0], bits[1:]
        maps = {f.split("=", 1)[0]: f.split("=", 1)[1] for f in flags if f.split("=", 1)[0] in ("normal", "orm", "height")}
        keep = [f for f in flags if f.split("=", 1)[0] not in ("normal", "orm", "height")]
        lines[i - 1] = "|".join([""] + keep)
        W.append((i, path, maps))
open(dst, "w").write("\n".join(lines))
t = float(tint)
o = ["WORLDS = {"]
for k, s in enumerate(int(x) for x in slots.split(",")):
    o.append('  { name = "slot%d", peak = 40, opts = { seed = %d, radius = 320, voxel = 1.5, relief = 7, caveDepth = 24, deferCaves = true,'
             ' mountains = { height = 26, scale = 2.2, sharpness = 2.0, coverage = 0.4 },'
             ' surfaceA = { slot = %d, color = { %g, %g, %g } }, surfaceB = { slot = %d, color = { %g, %g, %g } },'
             ' biomes = { { slot = %s, color = { %g, %g, %g }, slope = { 32, 90 } } } } },'
             % (s, 11 + k, s, t, t, t, s, t, t, t, border, t, t, t))
o.append("}")
o.append("WILD = {")
for i, path, maps in W:
    ent = ['slot = %d' % i, 'texture = "%s"' % path]
    if maps.get("normal"):
        ent.append('normalMap = "%s"' % maps["normal"])
    if maps.get("orm"):
        ent.append('roughnessMap = "%s"' % maps["orm"])
    o.append("  { " + ", ".join(ent) + " },")
o.append("}")
open(out, "w").write("\n".join(o) + "\n")
print("palprobe: %d worlds, %d wildcard lines" % (len(slots.split(",")), len(W)))
PY
[ $? -eq 0 ] || exit 1
cat "$PJ/scripts/worlds.lua" "$SOL/tools/perf/tileworld.lua" > "$PJ/scripts/tileworld.lua"; rm "$PJ/scripts/worlds.lua"
cat > "$PJ/scenes/tileworld.ron" <<RON
(
    name: "tileworld",
    lighting: (
        direction: (0.4, 0.9, 0.45), stars: true, color: (1.0, 0.95, 0.88), ambient: (0.05, 0.05, 0.06),
        intensity: 1.0, shadows: true, shadow_softness: 0.35, shadow_strength: 1.0, shadow_distance: 500.0, shadow_map: true,
        fog_color: (0.55, 0.6, 0.7), fog_start: 250.0, fog_end: 1400.0, fog_density: 0.004, fog_height: 6.0, fog_falloff: 8.0,
    ),
    nodes: [
        ( name: "Camera", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Camera( fov_y: 1.1519173, active: true ), scripts: [] ),
        ( name: "Planet", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Terrain( id: 1 ), scripts: [] ),
        ( name: "Alien Probe", transform: ( translation: (0.0, 0.0, 0.0), rotation: (0.0, 0.0, 0.0, 1.0), scale: (1.0, 1.0, 1.0) ),
          matter: Empty, scripts: [ ( kind: "tileworld", enabled: true, params: [${AP_PARAMS:-("dist", 1.0), ("settle", 2.0)}], strs: [ ("tag", "$TAG") ] ) ] ),
    ],
)
RON
OUT=$WORK/tworld/$TAG; mkdir -p "$OUT"
rm -rf "$PJ/save/user/tworld"
flock "$LOCK" bash -c "uptime > '$OUT/uptime.txt'; env -u WAYLAND_DISPLAY ALSA_CONFIG_PATH='$ALSA' timeout ${TMO:-360} $F play $PJ > '$OUT/run.log' 2>&1; echo exit \$? >> '$OUT/uptime.txt'; uptime >> '$OUT/uptime.txt'"
mkdir -p "$OUT/png"; cp "$PJ"/save/user/tworld/*.png "$OUT/png/" 2>/dev/null
rm -rf "$PJ/save/user/tworld" "$PJ"/terrain/tileworld.*.cfield "$PJ"/terrain/tileworld.*.meta "$PJ/terrain/tileworld.palette.ron"
grep -a "TW \|ERROR\|error\|panick" "$OUT/run.log" | cut -c1-300 | tail -80
