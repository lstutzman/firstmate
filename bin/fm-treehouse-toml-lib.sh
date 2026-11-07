#!/usr/bin/env bash
# Share a project's local treehouse.toml between the clones of that project on
# one host. Treehouse keys one pool directory per project and counts it against
# the max_trees of whichever clone asks, so a clone without the file reads the
# default of 16 and sees a pool another clone grew past it as full.
#
# Sourced by bin/fm-home-seed.sh and bin/fm-remote-home-provision.sh (inherit)
# and bin/fm-office.sh (mismatch check). "Same project" means the same origin
# URL string. Peer clones are <root>/*/projects/<name> under the colon list in
# FM_TREEHOUSE_PEER_ROOTS (default $HOME/fm-homes) plus any roots the caller
# passes; a clone is only ever read, never written.

FM_TH_DEFAULT_MAX=16

fm_th_roots() {
  printf '%s\n' "$@"
  printf '%s\n' "${FM_TREEHOUSE_PEER_ROOTS:-$HOME/fm-homes}" | tr ':' '\n'
}

# fm_th_max <file>: the file's max_trees, or empty.
fm_th_max() { sed -n 's/^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1; }

# fm_th_peers <name> <origin> <skip-dir> [extra-root...]: peer clone dirs, one per line.
fm_th_peers() {
  local name=$1 origin=$2 skip=$3 root d seen=
  shift 3
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for d in "$root"/*/projects/"$name"; do
      [ -d "$d/.git" ] || continue
      [ "$d" != "$skip" ] || continue
      case "$seen" in *"|$d|"*) continue ;; esac
      seen="$seen|$d|"
      [ "$(git -C "$d" remote get-url origin 2>/dev/null)" = "$origin" ] && printf '%s\n' "$d"
    done
  done <<EOF2
$(fm_th_roots "$@")
EOF2
  return 0
}

# fm_th_inherit <dst-clone> <name> [extra-root...]: copy a peer's treehouse.toml
# into a new clone. Never overwrites one. With several peers that differ, the
# largest max_trees wins and the other keys come from the first one found.
fm_th_inherit() {
  local dst=$1 name=$2 origin peer first='' best='' v list=''
  shift 2
  [ ! -e "$dst/treehouse.toml" ] || return 0
  origin=$(git -C "$dst" remote get-url origin 2>/dev/null) || return 0
  while IFS= read -r peer; do
    [ -n "$peer" ] && [ -f "$peer/treehouse.toml" ] || continue
    [ -n "$first" ] || first=$peer
    v=$(fm_th_max "$peer/treehouse.toml")
    list="$list ${peer}=${v:-default}"
    if [ -n "$v" ] && { [ -z "$best" ] || [ "$v" -gt "$best" ]; }; then best=$v; fi
  done <<EOF2
$(fm_th_peers "$name" "$origin" "$dst" "$@")
EOF2
  [ -n "$first" ] || return 0
  if [ -n "$best" ]; then
    { grep -v '^[[:space:]]*max_trees[[:space:]]*=' "$first/treehouse.toml" || true; printf 'max_trees = %s\n' "$best"; } > "$dst/treehouse.toml"
  else
    cp "$first/treehouse.toml" "$dst/treehouse.toml"
  fi
  printf 'treehouse.toml for %s: copied from %s (max_trees %s; peers:%s)\n' "$name" "$first" "${best:-unset}" "$list"
}

# fm_th_mismatches: one line per project whose clones on this host disagree on
# max_trees (a missing file reads as the default).
fm_th_mismatches() {
  local root d origin v rows=''
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for d in "$root"/*/projects/*; do
      [ -d "$d/.git" ] || continue
      origin=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
      v=$(fm_th_max "$d/treehouse.toml")
      rows="$rows$origin $d ${v:-$FM_TH_DEFAULT_MAX}"$'\n'
    done
  done <<EOF2
$(fm_th_roots)
EOF2
  printf '%s' "$rows" | sort -u | awk '
    { if ($1 != o) { flush(); o = $1; list = ""; n = 0; delete vals }
      list = list " " $2 "=" $3; vals[$3] = 1; n++ }
    function flush(  k, c) { if (o == "") return; c = 0; for (k in vals) c++
      if (c > 1) printf "clones of %s share a treehouse pool but differ on max_trees (%s); copy the largest treehouse.toml into the others\n", o, substr(list, 2) }
    END { flush() }'
}
