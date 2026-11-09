#!/bin/bash
# airprobe.sh — expansion X1/X2 in the engine: the air you choose and the
# survey, with pictures (docs/crew-and-items.md §11, docs/tracking-station.md §6).
#
#   airprobe.sh <engine> [modes]   modes: airalien (default; an alien home with
#                                  Earth air: helmet off, the station's BODY
#                                  card, the lab's BODIES page, the Command
#                                  building's refill, save and reload, the
#                                  new-save panel's AIR row), airtoxic (an
#                                  alien home with no oxygen: the helmet stays on)
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh; AIR (the save's g_air,
#        default earth for airalien, alien for airtoxic), HOMESEED (the alien
#        home's seed: 6 a verdant world with Earth air, 17 a sulfur world)
#
# Splices airprobe_modes.lua into a copy of perfbench.lua and has its boot
# write `g_air`; the repo's perfbench is untouched. Pictures land in
# $WORK/proj/save/user/airshots/. Look for `AP PASS|FAIL` and `AP RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-air}
eng=${1:?usage: airprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/airprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "airalien" then AP.run_alien(); AP.result()\n'
              '    elseif MODE == "airtoxic" then AP.run_toxic(); AP.result()')
old = '    save.set("g_homeSeed", math.floor(params.homeseed or 1))\n  end\n'
assert old in s
s = s.replace(old, old + '  if params.air then save.set("g_air", params.air) end\n', 1)
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/airshots
for m in ${*:-airalien}; do
  air=${AIR:-}; hs=${HOMESEED:-}
  [ -z "$air" ] && { [ "$m" = airtoxic ] && air=alien || air=earth; }
  [ -z "$hs" ] && { [ "$m" = airtoxic ] && hs=17 || hs=6; }
  SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-420} \
    BENCH_PARAMS="(\"homealien\", 1.0), (\"homeseed\", $hs.0)" BENCH_STRS="(\"air\", \"$air\")" \
    bash $S/tools/bench.sh $eng $m
done
