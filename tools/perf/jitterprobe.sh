#!/bin/bash
# jitterprobe.sh — the 2026-11-04 playtest's "I jitter up and down in third
# person while walking": per-frame heights of the crew, the camera and the
# head, and the head's screen y, standing, walking and sprinting.
#
#   jitterprobe.sh <engine> [modes]   modes: jitter medself fpsoak motionshots (pictures: $WORK/proj/save/user/jitshots/)
#   env: WORK LOCK SOLAR TAG PATCHES BENCH_PARAMS as bench.sh (TMO defaults to 300 s a mode)
#
# It splices jitterprobe_modes.lua into a copy of perfbench.lua (before its
# main) and runs that copy through bench.sh; the repo's perfbench is untouched.
# Look for `JIT RESULT` lines (BENCH_PARAMS='("jit_frames", 1.0)' prints the frames).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-jitter}
eng=${1:?usage: jitterprobe.sh <engine> [modes]}; shift
mkdir -p $S/tools
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/jitterprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n'
              '    elseif MODE == "jitter" then run_jitter()\n'
              '    elseif MODE == "medself" then run_medself()\n'
              '    elseif MODE == "motionshots" then run_motionshots()\n'
              '    elseif MODE == "fpsoak" then run_fpsoak()')
open(p, 'w').write(s)
PY
TMO=${TMO:-300} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng ${*:-jitter}
