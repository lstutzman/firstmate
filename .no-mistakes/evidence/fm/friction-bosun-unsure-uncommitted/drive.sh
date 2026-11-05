#!/usr/bin/env bash
# usage: drive.sh <repo-root> <out-dir>
ROOT_IN=$1; OUT=$2
cd "$ROOT_IN"
. "$ROOT_IN/tests/officer-helpers.sh"; eval "$(sed -n 21,138p tests/fm-officer-friction.test.sh | grep -v officer-helpers.sh)"
w="$TMP_ROOT/bosun"; home=$(make_world bosun)
sed -i 's/; added /; bosun-hosts: okhost,downhost; added /' "$home/data/officers.md"
mkdir -p "$w/gh" "$w/home/services/bosun-maintenance"
for d in clean untracked staged ignored; do
  mkdir -p "$w/$d"; git -C "$w/$d" init -q
  echo one > "$w/$d/a.txt"; echo 'build/' > "$w/$d/.gitignore"
  git -C "$w/$d" add a.txt .gitignore; git -C "$w/$d" -c user.name=t -c user.email=t@t commit -q -m one
  git -C "$w/$d" update-ref refs/remotes/origin/main HEAD
  git -C "$w/$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf '[]' > "$w/gh/task-$d.json"
done
echo notes > "$w/untracked/scratch.md"
echo new > "$w/staged/s.txt"; git -C "$w/staged" add s.txt
mkdir -p "$w/ignored/build"; echo out > "$w/ignored/build/o.bin"
jq -n --arg w "$w" 'def c(d): {kind:"copy", item:($w+"/"+d), why:("branch task-"+d+" is not merged and its pull request is missing or unreadable"), bucket:"rule-settles"};
  {date:"2026-10-24", unsure:[c("clean"),c("untracked"),c("staged"),c("ignored")]}' > "$w/home/services/bosun-maintenance/last-result.json"
fakebin=$(fm_fakebin "$w")
cat > "$fakebin/ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do case "\$1" in -o) shift 2 ;; *) break ;; esac; done
[ "\$1" = okhost ] || { echo "ssh: connect to host \$1: unreachable" >&2; exit 255; }
shift; HOME="$w/home" exec bash -c "\$*"
SH
cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in --head=*) f="$w/gh/\${a#--head=}.json" ;; esac; done
[ -f "\$f" ] && cat "\$f"
SH
chmod +x "$fakebin/ssh" "$fakebin/gh"
st0=$(git -C "$w/untracked" status --porcelain; git -C "$w/staged" status --porcelain)
PATH="$fakebin:$PATH" run_officer "$home" >/dev/null 2>"$OUT.stderr"; echo "run exit $?"
mkdir -p "$OUT"; cp "$home/data/officers/friction/bosun-answers.json" "$home/data/officers/friction/$DATE.md" "$home/data/officers/friction/$DATE.velocity-findings.json" "$OUT/"
st1=$(git -C "$w/untracked" status --porcelain; git -C "$w/staged" status --porcelain)
[ "$st0" = "$st1" ] && echo "copies untouched: yes" || echo "copies untouched: NO"
ls "$w/untracked" "$w/staged"
