#!/bin/bash
# portraitbooth.sh — bake a scenario's cast portraits (docs/scenarios.md §4.4;
# work/scenarios2/PLAN.md §2 F1).
#
# In play a cast member with `portrait = "auto"` is photographed from their
# own body once the scenario is staged (scenario_run.capturePortrait: the
# random face this playthrough generated). This bakes the FALLBACK: the same
# rig, run in the scenario probe, writes <key>.png for every auto cast member
# into scenarios/<id>/, used for anyone who never spawns (a voice off the
# roster, the dead) and before the live picture is taken. A cast member with
# only a `look = <seed>` borrows another body's face for the shot.
#
#   portraitbooth.sh <engine> <id>      e.g. portraitbooth.sh 0.118.3-dev.1480.decd01d _story
#   env: WORK LOCK SOLAR as scnprobe.sh; NOCOPY=1 leaves the pictures in $WORK
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
eng=${1:?usage: portraitbooth.sh <engine> <scenario id>}
id=${2:?usage: portraitbooth.sh <engine> <scenario id>}
S=${WORK:-${TMPDIR:-/tmp}/solar-booth}
SOL=${SOLAR:-$(cd "$HERE/../.." && pwd)}
rm -rf "$S/proj/save/user/booth"
WORK=$S SOLAR=$SOL BENCH_STRS="(\"booth\", \"1\")${BENCH_STRS:+, $BENCH_STRS}" bash "$HERE/scnprobe.sh" "$eng" "$id"
grep -a "SP booth\|SP PASS booth\|SP FAIL booth\|SP RESULT" "$S"/results/*/scn.log 2>/dev/null | tail -20
if [ -d "$S/proj/save/user/booth" ] && [ "${NOCOPY:-0}" != "1" ]; then
  if [ -d "$SOL/scenarios/$id" ]; then
    for f in "$S/proj/save/user/booth/"*.png; do case "$f" in *_wide.png) ;; *) cp "$f" "$SOL/scenarios/$id/" ;; esac; done
    ls -la "$SOL/scenarios/$id/"*.png
  else
    echo "scenarios/$id is not a folder scenario: the pictures stay in $S/proj/save/user/booth"
  fi
fi
