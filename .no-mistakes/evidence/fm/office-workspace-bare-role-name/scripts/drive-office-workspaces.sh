#!/usr/bin/env bash
# Drives the real bin/backends/herdr.sh against a guarded fm-lab-* Herdr session.
set -u
ROOT=$1 S=$2 T=$3
[[ "$S" == fm-lab-* ]] || { echo "refusing non-lab session $S"; exit 1; }
lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$S" "$@"; }
listing() { lab workspace list | jq -c '[.result.workspaces[] | {id:.workspace_id,label}]'; }
mkoffice() { # home id parent role-line
  mkdir -p "$1/data"; printf '%s\n' "$2" > "$1/.fm-secondmate-home"; printf '%s\n' "$2" > "$1/.fm-office"
  printf '# Office authority\n' > "$1/data/charter.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$3" > "$1/.fm-secondmate-parent"
}
ensure() { # home [relationship]
  local out rc
  out=$(FM_HOME="$1" HERDR_SESSION="$S" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp "$1" "$2"' "$ROOT" "${2:-other-home}" "$S" 2>&1); rc=$?
  case "$out" in "$S:"*) ;; *) echo "GUARD: ensure did not target lab session: $out" >&2; kill $$; exit 1 ;; esac
  printf '%s rc=%s' "$out" "$rc"
}
parent=$T/primary; mkdir -p "$parent/data"
cat > "$parent/data/offices.md" <<R
- quartermaster - Run the fleet. (role: quartermaster; runs-on: slartibartfast; added 2026-11-04)
- nav-office - Lead PC. (runs-on: slartibartfast; role: navigator; wip: 3; added 2026-11-04)
- alchemist - Train. (role: alchemist; runs-on: slartibartfast; added 2026-11-04)
- librarian - Shelve. (role: librarian; runs-on: slartibartfast; added 2026-11-04)
R
mkoffice "$T/qm" quartermaster "$parent"
mkoffice "$T/nav" nav-office "$parent"
mkoffice "$T/alc" alchemist "$parent"
mkoffice "$T/lib" librarian "$parent"
mkdir -p "$T/plain"; printf 'plain-sm\n' > "$T/plain/.fm-secondmate-home"

echo "=== S0 guard: plain home ensure lands in lab"
echo "ensure(plain): $(ensure "$T/plain")" || exit 1
echo "lab: $(listing)"
echo "=== S1: live legacy Quartermaster office workspaces are renamed in place"
lab workspace create --label 2ndmate-quartermaster --cwd /tmp --no-focus >/dev/null
lab workspace create --label "2ndmate-quartermaster workers" --cwd /tmp --no-focus >/dev/null
echo "before: $(listing)"
echo "ensure(qm): $(ensure "$T/qm")"
echo "after:  $(listing)"
echo "ensure(qm) again: $(ensure "$T/qm")"
echo "after2: $(listing)"
echo "=== S2: new Navigator office (role field not first, id != role) gets bare 'Navigator'"
echo "ensure(nav): $(ensure "$T/nav")"
echo "after:  $(listing)"
echo "=== S3: plain second mate keeps 2ndmate-<id>; primary keeps firstmate"
echo "ensure(plain): $(ensure "$T/plain")"
echo "ensure(primary): $(ensure "$parent")"
echo "after:  $(listing)"
echo "=== S4 adversarial: Alchemist has both role and legacy workspaces -> no rename"
lab workspace create --label Alchemist --cwd /tmp --no-focus >/dev/null
lab workspace create --label 2ndmate-alchemist --cwd /tmp --no-focus >/dev/null
echo "ensure(alc): $(ensure "$T/alc")"
echo "after:  $(listing)"
echo "=== S5 adversarial: two legacy 2ndmate-librarian workspaces -> neither renamed"
lab workspace create --label 2ndmate-librarian --cwd /tmp --no-focus >/dev/null
lab workspace create --label 2ndmate-librarian --cwd /tmp --no-focus >/dev/null
echo "ensure(lib): $(ensure "$T/lib")"
echo "after:  $(listing)"
