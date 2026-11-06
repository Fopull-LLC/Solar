#!/bin/bash
# exportcheck.sh — export the project the way its players get it and fail
# loudly if the build is missing anything the game loads.
#
#   WORK=<scratch> LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/exportcheck.sh [engine version]
#   env: SRC=head      (default) `git archive HEAD`: exactly what the demo-zip workflow
#                      (.github/workflows/demo-zip.yml) publishes and players export from
#        SRC=worktree  the working tree's tracked and new (not ignored) files, minus what
#                      .gitattributes export-ignores: check uncommitted changes the same way
#        KEEP=1        keep $WORK/xc-src and $WORK/xc-out (the build) afterwards
#        LOCAL=0       leave out textures/env_local (the commercial textures; default: a
#                      local build carries them, see tools/import_textures.py --stage)
#
# 1. the source: a clean archive (SRC=head) or the working tree's files (SRC=worktree);
# 2. `floptle export <src> <out> linux-x86_64 --title Solar` through the shared lock;
# 3. tools/perf/exportcheck.py: every tracked file the exporter should ship is in
#    the build, every asset path a shipped file names is there, and the gear's
#    computed loads (TOOLDEF / items.lua prefabs spawned by name, and the models and
#    textures those prefabs load) are there. `EXPORTCHECK FAIL ...` lines, exit 1.
# The archive is also listed against the repo: a tracked file under models/,
# textures/, prefabs/ ... that the archive itself dropped is named here, since
# that is where the 2026-10-28 loss happened (a bare `tools export-ignore`).
set -u
for _lp in "$(dirname "$0")/lockpool.sh" /mnt/disks/3tb/GithubRepositories/Solar/tools/perf/lockpool.sh; do [ -f "$_lp" ] && { . "$_lp"; break; }; done
SOL=$(cd "$(dirname "$0")/../.." && pwd)
VER=${1:-0.117.1-dev.1377.6ac1c98}
ENG=${ENGINE:-$HOME/.local/share/floptle/versions/$VER/floptle}
WORK=${WORK:?WORK (a scratch dir)}; LOCK=${LOCK:?LOCK (the shared engine lock)}
MODE=${SRC:-head}
S=$WORK/xc-src; O=$WORK/xc-out; L=$WORK/xc-files.txt
rm -rf "$S" "$O"; mkdir -p "$S" "$WORK"
if [ "$MODE" = head ]; then
  git -C "$SOL" archive HEAD | tar -x -C "$S" || { echo "EXPORTCHECK RESULT FAIL: git archive"; exit 2; }
  git -C "$SOL" ls-tree -r --name-only HEAD > "$L"
  echo "EXPORTCHECK source: git archive of HEAD $(git -C "$SOL" rev-parse --short HEAD)"
else
  # tracked + new files, minus whatever .gitattributes export-ignores (the file or a folder above it)
  ( cd "$SOL" && git ls-files -co --exclude-standard ) | sort -u > "$L.all"
  python3 -I - "$SOL" "$L.all" "$L" "$S" <<'PY'
import os, shutil, subprocess, sys
sol, src_list, out_list, dst = sys.argv[1:5]
files = [l.rstrip("\n") for l in open(src_list) if l.strip() and os.path.isfile(os.path.join(sol, l.strip()))]
prefixes = sorted({"/".join(f.split("/")[:k]) for f in files for k in range(1, f.count("/") + 2)})
r = subprocess.run(["git", "-C", sol, "check-attr", "--stdin", "-z", "export-ignore"], input="\0".join(prefixes) + "\0",
                   capture_output=True, text=True)
tok = r.stdout.split("\0")
ign = {tok[i] for i in range(0, len(tok) - 2, 3) if tok[i + 2] == "set"}
keep = [f for f in files if not any("/".join(f.split("/")[:k]) in ign for k in range(1, f.count("/") + 2))]
for f in keep:
    d = os.path.join(dst, os.path.dirname(f)); os.makedirs(d, exist_ok=True)
    shutil.copy2(os.path.join(sol, f), os.path.join(dst, f))
open(out_list, "w").write("\n".join(files) + "\n")
print(f"EXPORTCHECK source: the working tree, {len(keep)} of {len(files)} files ({len(files) - len(keep)} export-ignored)")
PY
fi
# The commercial-licence textures (textures/env_local, git-ignored: never in an
# archive or a commit) go into a LOCAL build: tools/import_textures.py --stage copies
# the folder in and points the terrain palettes' slots at their local layers. LOCAL=0
# checks the public build (what the demo zip and a clean checkout give: CC0 only).
if [ "${LOCAL:-1}" = 1 ] && [ -d "$SOL/textures/env_local" ]; then
  python3 -I "$SOL/tools/import_textures.py" --stage "$S" | sed 's/^/EXPORTCHECK /'
fi
# what the archive itself dropped, among the folders the game loads from
python3 -I - "$L" "$S" <<'PY'
import os, sys
lst, src = sys.argv[1:3]
roots = ("models/", "textures/", "audio/", "prefabs/", "scenes/", "vfx/", "shaders/", "fonts/", "ui/", "materials/",
         "animations/", "animation_controllers/", "terrain/", "scripts/")
miss = [l.strip() for l in open(lst) if l.strip().startswith(roots) and not os.path.exists(os.path.join(src, l.strip()))]
for m in miss[:30]:
    print("EXPORTCHECK FAIL ARCHIVE " + m + ": tracked game asset left out of the source archive (.gitattributes export-ignore?)")
print(f"EXPORTCHECK archive: {len(miss)} tracked game assets missing from the source")
sys.exit(1 if miss else 0)
PY
arc=$?
ALSA=${ALSA:-$(dirname "$LOCK")/silent-alsa.conf}
flock "$LOCK" timeout 300 env ALSA_CONFIG_PATH="$ALSA" "$ENG" export "$S" "$O" linux-x86_64 --title Solar > "$WORK/xc-export.log" 2>&1
ex=$?
tail -c 1500 "$WORK/xc-export.log" | sed 's/^/EXPORTCHECK export: /'
if [ $ex -ne 0 ] || [ ! -d "$O/assets" ]; then echo "EXPORTCHECK RESULT FAIL: the export itself failed (exit $ex)"; exit 2; fi
python3 -I "$SOL/tools/perf/exportcheck.py" "$S" "$L" "$O/assets"
rc=$?
[ $arc -ne 0 ] && rc=1
[ -z "${KEEP:-}" ] && rm -rf "$S" "$O"
exit $rc
