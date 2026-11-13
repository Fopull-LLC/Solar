#!/bin/bash
# baseloopkit.sh — the hands-on base loop (work/baseloop/DESIGN.md) in the
# engine, on the kit probe's helpers.
#
#   baseloopkit.sh <engine> [modes]   modes: wired (W2: nothing has power
#                                     until it is cabled; a hab, a tower, a
#                                     bank and arrays cabled one run at a
#                                     time; the terminal tags, the POWER
#                                     overlay; save and reload)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# Splices the kit probe's mode files and baseloop_modes.lua into a copy of
# perfbench.lua. Pictures land in $WORK/proj/save/user/buildshots/.
# Look for `BK PASS|FAIL`, `BL` lines and `BK RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-baseloop}
eng=${1:?usage: kitprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/kitprobe_modes.lua" "$HERE/charprobe_modes.lua" "$HERE/powerprobe_modes.lua" "$HERE/reactorprobe_modes.lua" "$HERE/fluidsprobe_modes.lua" "$HERE/logicprobe_modes.lua" "$HERE/habjoinprobe_modes.lua" "$HERE/zfprobe_modes.lua" "$HERE/airlockprobe_modes.lua" "$HERE/baseloop_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(a).read() for a in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "kit" then KIT.run()\n    elseif MODE == "kitperf" then KIT.run_perf()\n    elseif MODE == "kitview" then KIT.run_view()\n    elseif MODE == "tbprof" then KIT.run_tbprof()\n    elseif MODE == "rooms" then KIT.run_rooms()\n    elseif MODE == "character" then CH.run()\n    elseif MODE == "tint" then CH.run_tint()\n    elseif MODE == "interior" then PW.run_interior()\n    elseif MODE == "power" then PW.run()\n    elseif MODE == "reactor" then RXP.run()\n    elseif MODE == "fluids" then FLP.run()\n    elseif MODE == "logic" then LGP.run()\n    elseif MODE == "habjoin" then HJ.run()\n    elseif MODE == "zfight" then ZF.run()\n    elseif MODE == "airlock" then ALP.run()\n    elseif MODE == "wired" then BL.run_wired()\n    elseif MODE == "ruin" then BL.run_ruin()\n    elseif MODE == "craft" then BL.run_craft()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/buildshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-900} bash $S/tools/bench.sh $eng ${*:-wired}
