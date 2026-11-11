#!/bin/bash
# scnprobe.sh — a scenario played in the engine (docs/scenarios.md §8).
# Starts it exactly as the menu's PLAY does (scenario.prepareSlot into slot
# `scn`, then the system scene), waits for the staging, then plays its
# solution: scenarios/<id>/solve.lua when there is one (spliced in; it defines
# SOLVE(SP)), else the generic solver (every step completed with F11's call,
# its readings printed first). Asserts each step latches, no fail fires, the
# debrief state and the profile's medal; the runner's own cost a frame
# (perf.scriptMs "scenario_run", idle and while evaluating); pictures of the
# staged start, a cutscene or camera beat, and the end.
#
#   scnprobe.sh <engine> <id>      e.g. scnprobe.sh 0.117.1-dev.1468.83186b8 _probe
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh
#
# Look for `SP PASS|FAIL`, `SP COST` and `SP RESULT`. Pictures land in
# $WORK/proj/save/user/scnshots/. The slot `scn` is the scratch project's.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-scn}
eng=${1:?usage: scnprobe.sh <engine> <scenario id>}
id=${2:?usage: scnprobe.sh <engine> <scenario id>}
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
SOLVE=""
for f in "$SOL/scenarios/$id/solve.lua"; do [ -f "$f" ] && SOLVE="$f"; done
# EXTRA_LUA: more chunks spliced in after the modes (a per-frame monitor
# defines MON_tick(), called from perfbench's update, and MON_total() at DONE:
# tools/perf/camclear_mon.lua watches the cutscene camera)
python3 - "$S/tools/perfbench.lua" "$HERE/scnprobe_modes.lua" $SOLVE ${EXTRA_LUA:-} <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(x).read() + "\n" for x in sys.argv[2:])
s = open(p).read()
s = s.replace("function update(node, dt)\n  measure()", "function update(node, dt)\n  measure()\n  if MON_tick then MON_tick() end", 1)
s = s.replace('  P("DONE mode %s', '  if MON_total then MON_total() end\n  P("DONE mode %s', 1)
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
# the scenario mode makes its own slot: no perfbench boot()
s = s.replace('  boot()\n  if MODE == "base" then', '  if MODE ~= "scn" then boot() end\n  if MODE == "scn" then SP.run()\n  elseif MODE == "base" then')
s = s.replace('    after_boot_settle(4)\n', '    if MODE ~= "scn" then after_boot_settle(4) end\n')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/scnshots
SOLAR=$SOL WORK=$S TMO=${TMO:-420} BENCH_STRS="(\"scn\", \"$id\")${BENCH_STRS:+, $BENCH_STRS}" bash $S/tools/bench.sh $eng scn
# the probe's slot and its terrain: the scratch project's own, cleared
rm -f $S/proj/save/scn.ron; rm -rf $S/proj/saves/scn
grep -a "SP " $S/results/*/scn.log 2>/dev/null | tail -0 >/dev/null
