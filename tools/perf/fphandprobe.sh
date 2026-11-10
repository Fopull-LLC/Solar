#!/bin/bash
# fphandprobe.sh — the first-person hands (playtest 2026-11-09d: "the fast
# walking arm jitter in first person"; "first person hands ... use things like
# ik so no matter what action you're doing they fit"): a per-frame log of the
# hand's drawn pose in the camera's frame while walking and sprinting on flat
# ground and up a ramp, and picture sequences of every first-person action.
#
#   fphandprobe.sh <engine> [modes]   modes: fpjit fpshots fpstance fpstshots (pictures: $WORK/proj/save/user/fpshots/)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#   BENCH_PARAMS='("fp_frames", 1.0)' prints every frame of the first 1.5 s of each phase;
#   '("fp_body", 0.0)' runs the old view models (the A/B in one build).
#
# It splices fphandprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `FH RESULT` lines and `FH SHOT` lines.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-fphand}
eng=${1:?usage: fphandprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $HERE/lockpool.sh $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/fphandprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "fpjit" then FH.run_jit()\n'
              '    elseif MODE == "fpshots" then FH.run_shots()\n'
              '    elseif MODE == "fpstance" then FH.run_stance()\n'
              '    elseif MODE == "fpstshots" then FH.run_stshots()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-fpjit}
