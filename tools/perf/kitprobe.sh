#!/bin/bash
# kitprobe.sh — sandbox plan S1/S2 (work/sandbox/PLAN.md §12): the modular
# structure kit and live placed parts on the home world, in the engine.
#
#   kitprobe.sh <engine> [modes]     modes: kit (default: a hab built from
#                                    pieces, walked into, a cockpit boarded, a
#                                    locker opened, a light switched, the Shed
#                                    and Hab prefabs entered, the stand's blue
#                                    display copy, save and reload), kitperf
#                                    (500 / 2,000 / 6,000 pieces in view: counts,
#                                    draws, the render bucket, script ms), rooms
#                                    (S3: a sealed hab with an airlock built,
#                                    pressurised by its tank, the ROOMS overlay,
#                                    walked in through the airlock, its air
#                                    breathed helmet off, the seat tick's cost,
#                                    a far door opened: the leak alarm; refilled;
#                                    save and reload), character (S4: the hab
#                                    painted, a sign with the base's name,
#                                    decals, props inside, saved as a
#                                    blueprint and a copy placed, a 500-piece
#                                    base + 100 props + 20 decals in view,
#                                    painted and bare; save and reload),
#                                    interior (S5: a hab's inside light, with
#                                    its lamp on and off and its sky reflection
#                                    off), power (S5: two bases on a long cable
#                                    with transformers, a breaker tripped by
#                                    overload and reset, the POWER overlay, the
#                                    new swatches, a sign read at 8 m, save and
#                                    reload), reactor (S6: a reactor assembled
#                                    from components on a slab floor, fuelled,
#                                    taken critical on real warp, its turbine on
#                                    the base grid, the NUCLEAR overlay and the
#                                    console, SCRAM, the xenon pit blocking a
#                                    restart, the pumps cut: the overheat
#                                    alarm; save and reload)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh
#
# Splices vfxprobe_modes.lua (its freecam), buildkitprobe_modes.lua (the BK
# helpers) and kitprobe_modes.lua into a copy of perfbench.lua; the repo's
# perfbench is untouched. Pictures land in $WORK/proj/save/user/buildshots/.
# Look for `BK PASS|FAIL`, `KIT` lines and `BK RESULT`.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-kit}
eng=${1:?usage: kitprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/vfxprobe_modes.lua" "$HERE/buildkitprobe_modes.lua" "$HERE/kitprobe_modes.lua" "$HERE/charprobe_modes.lua" "$HERE/powerprobe_modes.lua" "$HERE/reactorprobe_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "".join(open(a).read() for a in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "kit" then KIT.run()\n    elseif MODE == "kitperf" then KIT.run_perf()\n    elseif MODE == "rooms" then KIT.run_rooms()\n    elseif MODE == "character" then CH.run()\n    elseif MODE == "tint" then CH.run_tint()\n    elseif MODE == "interior" then PW.run_interior()\n    elseif MODE == "power" then PW.run()\n    elseif MODE == "reactor" then RXP.run()')
open(p, 'w').write(s)
PY
rm -rf $S/proj/save/user/buildshots
SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S TMO=${TMO:-900} bash $S/tools/bench.sh $eng ${*:-kit}
