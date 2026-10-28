#!/bin/bash
# bike0579.sh — floptle card 0579 (raked wheel joints, W vs S) dumps from the player's dirt bike.
#
#   bike0579.sh <engine> <variant>
#   env: RAKED=1   the joints on the parts' own raked axes (the snapshot's copy of
#                  auto_drive.lua loses jointAxis; Solar's tree is never touched)
#        BENCH_PARAMS e.g. '("tcoff", 1.0)' or '("nobal", 1.0)'
#        OUTDIR   where <variant>.log and the extracted dumps go
#                 (default /mnt/disks/3tb/.floptle-shared/solar-0579)
#        WORK LOCK TMO BIKE as verifyprobe.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SOL=$(cd "$HERE/../.." && pwd)
S=${WORK:-${TMPDIR:-/tmp}/solar-b79}
eng=${1:?usage: bike0579.sh <engine> <variant>}; var=${2:?variant name}
OUTDIR=${OUTDIR:-/mnt/disks/3tb/.floptle-shared/solar-0579}
mkdir -p $S/tools $S/solar $S/proj/save/user $OUTDIR
SN=$S/solar
for d in $(ls -A $SOL); do
  case $d in scripts|scenes|prefabs|project.ron|save|saves|.git|tools) ;; *) [ -e $SN/$d ] || ln -s $SOL/$d $SN/$d ;; esac
done
[ -e $SN/tools ] || ln -s $SOL/tools $SN/tools
rm -rf $SN/scripts $SN/scenes $SN/prefabs; rm -f $SN/project.ron
cp -r $SOL/scripts $SOL/scenes $SOL/prefabs $SN/; cp $SOL/project.ron $SN/
mkdir -p $SN/save $SN/saves
if [ -n "${RAKED:-}" ]; then
  sed -i 's/^function jointAxis(/function jointAxis_upright_off(/' $SN/scripts/auto_drive.lua
  grep -q '^function jointAxis(' $SN/scripts/auto_drive.lua && { echo "RAKED patch failed"; exit 3; }
  echo "b79: raked axes (snapshot auto_drive.lua without jointAxis)"
fi
BIKE=${BIKE:-$HOME/.local/share/solar/user/library/slot1/dirtbike.json}
cp "$BIKE" $S/proj/save/user/probe_dirtbike.json || exit 2
cp $HERE/bench.sh $HERE/table.py $HERE/perfbench.lua $S/tools/
python3 - "$S/tools/perfbench.lua" "$HERE/ivaprobe_modes.lua" "$HERE/verifyprobe_modes.lua" "$HERE/bike0579_modes.lua" <<'PY'
import sys
p = sys.argv[1]
m = "\n".join(open(f).read() for f in sys.argv[2:])
s = open(p).read()
i = s.index('-- ── main ──')
s = s[:i] + m + s[i:]
s = s.replace('    elseif MODE == "plane" then run_plane()',
              '    elseif MODE == "plane" then run_plane()\n    elseif MODE == "vb79" then run_vb79()')
open(p, 'w').write(s)
PY
luajit -e "assert(loadfile('$S/tools/perfbench.lua'))" || exit 3
TAG=b79-$var TMO=${TMO:-300} SOLAR=$SN WORK=$S bash $S/tools/bench.sh $eng vb79 > /dev/null
rc=$?
L=$S/results/b79-$var/vb79.log
cp $L $OUTDIR/$var.log
grep -a "VP \|VB79R\|moto:" $L | grep -v VB79P | cut -c1-400
python3 - $L $OUTDIR/$var <<'PY'
import sys, json
src, base = sys.argv[1], sys.argv[2]
out = {"static": [], "samples": [], "runs": [], "blueprint": None}
for line in open(src, errors="replace"):
    for key, dst in (("VB79S ", "static"), ("VB79T ", "samples"), ("VB79R ", "runs"), ("VB79P ", "blueprint")):
        i = line.find(key)
        if i >= 0:
            try: d = json.loads(line[i + len(key):])
            except Exception as e: d = {"bad": str(e)}
            if dst == "blueprint": out[dst] = d
            else: out[dst].append(d)
json.dump(out, open(base + ".json", "w"), indent=1)
with open(base + ".tsv", "w") as f:
    f.write("run\tt\tvf\ta_s\tlk\twant_a\tdrive\twheel\tgr\ttgt\trim\ttyre_v\tslip\tmotorSpeed\tmaxForce\tforce\tcomp\tNspring\tgnUp\n")
    for s in out["samples"]:
        for w in s.get("w", []):
            f.write("\t".join(str(x) for x in (s["tag"], s["t"], s.get("vf"), s.get("a_s"), s.get("lk"), s.get("want_a"), s.get("drive"), w.get("uid"), w.get("gr"),
                w.get("tgt"), w.get("rim"), w.get("tv"), w.get("slip"), w.get("ms"), w.get("mF"), w.get("force"), w.get("comp"), w.get("Nspring"), w.get("gnUp"))) + "\n")
print("dumps:", base + ".json", base + ".tsv", len(out["samples"]), "samples")
PY
rm -f $S/proj/save/slot13.ron; rm -rf $S/proj/saves/slot13
exit $rc
