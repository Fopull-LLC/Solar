#!/bin/bash
# sfxprobe.sh — which sound each game event plays (scripts/sfx.lua's impacts,
# failures and footsteps), checked by the bank it picked, never by ear.
#
#   sfxprobe.sh <engine>
#   env: WORK LOCK SOLAR TAG PATCHES as bench.sh (TMO defaults to 360 s)
#
# Splices sfxprobe_modes.lua into a copy of perfbench.lua (before its main) and
# runs that copy through bench.sh; the repo's perfbench is untouched. Look for
# `SP PASS|FAIL`, `SP RESULT`, `SP events` and the `SFX <event> <bank> <clip>`
# lines sfx.lua writes with sfxLog on.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-sfx}
eng=${1:?usage: sfxprobe.sh <engine>}; shift
mkdir -p $S/tools $S/proj/save/user
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/sfxprobe_modes.lua" <<'PY'
import sys
p, m = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "sfx" then run_sfx()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TMO=${TMO:-360} SOLAR=${SOLAR:-$(cd "$HERE/../.." && pwd)} WORK=$S bash $S/tools/bench.sh $eng sfx
