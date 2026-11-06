# lockpool.sh: sourced by the probe scripts. The machine runs two engines at
# once, on two lock slots: engine.lock (A) and engine2.lock (B). A script that
# asks for either slot gets whichever is free first, so two runs can go side by
# side instead of queueing on one slot while the other sits idle.
#
# It works by overriding `flock` inside the script. Any other lock file is
# passed to the real flock untouched. Each run holds its slot only while it
# runs (keep runs under ~6 min), so E, who also takes slot A, waits for one run
# at most.
#
# LOCKPOOL=0 turns this off: the run then takes exactly the slot it named. Use
# that for a quiet-window A/B, which must not wander onto the other slot.
_LP_DIR=/mnt/disks/3tb/.floptle-shared
flock() {
  local want="$1"
  case "$want" in
    "$_LP_DIR/engine.lock"|"$_LP_DIR/engine2.lock")
      if [ "${LOCKPOOL:-1}" = 0 ]; then command flock "$@"; return $?; fi
      shift
      local slot
      while :; do
        for slot in "$_LP_DIR/engine.lock" "$_LP_DIR/engine2.lock"; do
          # -n: take the slot only if it is free now; -E 75 marks "busy"
          command flock -n -E 75 "$slot" "$@"
          local rc=$?
          [ $rc -ne 75 ] && return $rc
        done
        sleep 3
      done ;;
    *) command flock "$@" ;;
  esac
}
