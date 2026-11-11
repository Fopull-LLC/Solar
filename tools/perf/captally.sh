#!/bin/bash
# captally.sh — how many big captions a play session puts on screen (Ty
# 2026-11-11: "I don't like all the popup messages, they happen too much").
# Runs a perfbench mode with every big_caption.show call wrapped: each prints
# "CAPT SHOWN|held <kind> | <title> | <line>" (a build before the caption
# kinds returns nothing from show: every call counts as SHOWN), and the
# totals at the end.
#
#   captally.sh <engine> gameplay|hazard [seed]
#     gameplay  the gameplay smoke: the starter rocket, a rover drive, the
#               VAB, on foot (bench.sh gameplay; pass PATCHES=funds.patch)
#     hazard    the cave hazards probe (hazardprobe_modes.lua): into a cave,
#               bad air, methane, a rockfall, a dose, a vent, the ruins
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh
#
# Totals: grep -c "CAPT SHOWN" in $WORK/results/<TAG>/<mode>.log.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:?WORK}
eng=${1:?usage: captally.sh <engine> gameplay|hazard [seed]}
MODE=${2:?mode}
SEED=${3:-1}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$MODE" "$HERE/caveprobe_modes.lua" "$HERE/hazardprobe_modes.lua" <<'PY'
import sys
p, mode = sys.argv[1], sys.argv[2]
s = open(p).read()
ct = r'''
-- ── captally: every big_caption.show, counted ──
local CT = { n = 0, shown = 0, wrapped = nil, k = 0 }
function CT_tick()
  CT.k = CT.k + 1
  if CT.k % 30 ~= 1 then return end
  local bc = findScript and findScript("big_caption", { quiet = true })
  if bc and bc.show and bc.show ~= CT.wrapped then
    local orig = bc.show
    CT.wrapped = function(t, s, secs, kind)
      local r = orig(t, s, secs, kind)
      CT.n = CT.n + 1
      local shown = r ~= false
      if shown then CT.shown = CT.shown + 1 end
      print(string.format("CAPT %s %s | %s | %s   (shown %d of %d)", shown and "SHOWN" or "held", tostring(kind or "-"),
        tostring(t), tostring(s), CT.shown, CT.n))
      return r
    end
    bc.show = CT.wrapped
  end
end
function CT_total() print(string.format("CAPT TOTAL shown %d of %d calls", CT.shown, CT.n)) end
'''
i = s.index('-- ── main ──')
extra = ""
if mode == "hazard":
    extra = open(sys.argv[3]).read() + "\n" + open(sys.argv[4]).read() + "\n"
    s = s.replace('    elseif MODE == "plane" then run_plane()',
                  '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "hazard" then HZ.run()')
s = s[:i] + extra + ct + s[i:]
s = s.replace("function update(node, dt)\n  measure()", "function update(node, dt)\n  measure()\n  if CT_tick then CT_tick() end", 1)
s = s.replace('  P("DONE mode %s', '  if CT_total then CT_total() end\n  P("DONE mode %s', 1)
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TAG=${TAG:-cap-$MODE-$(date +%m%d-%H%M)}
if [ "$MODE" = hazard ]; then BP="(\"seed\", $SEED.0)${BENCH_PARAMS:+, $BENCH_PARAMS}"; else BP=${BENCH_PARAMS:-}; fi
TAG=$TAG TMO=${TMO:-480} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S BENCH_PARAMS="$BP" bash $S/tools/bench.sh $eng $MODE
L=$S/results/$TAG/$MODE.log
grep -a "CAPT " $L | cut -c1-300
echo "shown: $(grep -ac 'CAPT SHOWN' $L)  held: $(grep -ac 'CAPT held' $L)"
rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
