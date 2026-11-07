#!/usr/bin/env bash
# fm-office-authority-lib.sh - is this home an office, and what may it do.
#
# Sourced, never executed. An office is a second mate that runs a standing role
# mandate (docs/configuration.md "Offices (data/offices.md)"). bin/fm-spawn.sh,
# bin/fm-pr-merge.sh and bin/fm-merge-local.sh call fm_office_resolve and, in an
# office, refuse what the office's authority record does not cover. Outside an
# office nothing here changes what any of them does. This library grants
# nothing: every result is either "not an office" or a narrower set of allowed
# actions.
#
# Detection reads two independent local signals, so deleting one makes the home
# refuse rather than fall back to plain second-mate behaviour:
#   - the .fm-office marker, a regular file holding the office id, which must
#     equal the id in the home's .fm-secondmate-home marker;
#   - a line starting "# Office authority" in the home's data/charter.md.
# Neither signal is "not an office". Both, with matching ids, is an office. Any
# other combination, a symlinked or unreadable marker, or an unreadable charter
# is inconsistent and refuses every spawn and merge.
#
# Authority record: config/office-authority in the office home, published by
# the main home through the inherited-config push (bin/fm-config-inherit-lib.sh,
# and bin/fm-office.sh publish for one office now). It is trusted only while
# config/.fm-inherit-office-authority.generation proves its exact bytes, using
# the same receipt as the inherited role grant (bin/fm-role-lib.sh,
# fm_role_inherit_check). A missing, unproven, or malformed record, or a receipt
# that records an absent record, means no authority, and every spawn and merge
# is refused. Like the role grant, this guards against accidents and drift, not
# against a process that deliberately forges local files. Grammar:
#   fm-office-authority-v1
#   id=<office id>
#   dispatch=<project>[,<project>...]
#   merge=<project>[,<project>...]        or none, or empty
#   merge-via=<project>=<home>[,...]      or none, or empty
#   auto-merge-classes=none               or empty; nothing else is accepted
#   wip=<1-9>
#   admission-sha256=<project>:<digest>[,...]   or empty when merge is
# The version line comes first, then each key exactly once, in any order, and
# no other line. Names are [A-Za-z0-9._-]. merge and merge-via are subsets of
# dispatch and disjoint. admission-sha256 holds one entry for each merge
# project and no other: the fm_office_admission_digest of the admission config
# that project's registry entry names in this home.
#
# Admission digest: for admission config <name>, the sha256 of the lines
# "<sha256 of file>\n" for config/admission/<name> and then for each rules file
# its classifier reads: every file named by a "--rules <path>" argument on the
# config's command= line, in order, which must be an absolute path to a
# readable regular file; or, when command= has no --rules argument,
# config/admission/<name>.rules if it exists (the conventional path-rule file
# of bin/fm-reserved-classify.sh). Only contents are listed, never paths, so a
# byte-identical copy in another home digests the same; the config's own bytes
# already carry each --rules path. It lets an office's merge notice a local
# edit to its own classifier config or rules.
#
# Publishing: fm_office_inherit_payload builds one destination's record from
# the main home's data/offices.md, so every other home receives an absence.
# A destination gets a record only when exactly one registry line names its
# id and, on a local route, its home's .fm-office marker names that id too; no
# line, no registry, or no marker is an absence. A malformed line, or a merge
# project whose admission config cannot be pinned, is an error and publishes
# nothing. The record copies the line's dispatch, merge, merge-via,
# auto-merge-classes and wip, and pins admission-sha256 from the main home's
# master copy config/admission/<name>, where <name> is the admission= token of
# that project in the office home's data/projects.md; a remote route cannot
# read that registry, so it takes the seed's own name (the project) and needs
# the remote home path to publish a merging office. The
# built record must pass the same grammar check the office applies on load.
#
# FM_OFFICE_ROLES names the roles an office may take, and
# FM_OFFICE_RESERVED_ROLES the role names held for later offices; a reserved
# role has no charter and no authority, so a line naming it is refused. The
# reserved set is empty: alchemist and librarian were unlocked as office roles.
#
# Public functions:
#   fm_office_detect <home> <data-dir>
#       0 an office (sets FM_OFFICE_DETECT_ID), 1 not an office, 2 inconsistent
#       (sets FM_OFFICE_ERROR).
#   fm_office_authority_load <config-dir> <office-id>
#       0 with the FM_OFFICE_* authority variables set, or 1 with FM_OFFICE_ERROR.
#   fm_office_resolve <home> <data-dir> <config-dir>
#       detect, then load: 0 with FM_OFFICE_ID empty (not an office) or set (an
#       office with its authority loaded), or 1 with FM_OFFICE_ERROR (refuse).
#   fm_office_admission_digest <config-dir> <name>
#       prints the digest above, or returns 1 when config/admission/<name> or a
#       rules file it names is missing or unreadable, or a --rules path is not
#       absolute.
#   fm_office_authority_parse <file> <office-id>
#       the grammar check alone, with no receipt: 0 with the FM_OFFICE_*
#       authority variables set, or 1 with FM_OFFICE_ERROR.
#   fm_office_inherit_payload <src-config> <src-data> <dest-id> <dest-home> <out-file> [<remote-home>]
#       writes <dest-id>'s record to <out-file>, or leaves it absent; returns 1
#       with FM_OFFICE_ERROR on an error. <dest-home> is empty on a remote route,
#       where <remote-home> (the registered home path) lets a merging office be
#       published: the seed names its admission configs after their projects, and
#       the master's --rules path <remote-home>/config/admission/<name>.rules
#       digests as the master copy.
#   fm_office_project_token <projects.md> <project> <key>
#       prints a key=value token of one data/projects.md line, or nothing.
#   fm_office_in <item> <comma-list>
#   fm_office_role_check <role>
#       0 for an office role, or 1 with FM_OFFICE_ERROR naming a reserved or
#       unknown role.
#   fm_office_live_tasks <state-dir> <own-id> <office-id>
#       the one count of an office's places under wip=, used by the tick
#       (bin/fm-office.sh) and the spawn gate (bin/fm-spawn.sh). Sets
#       FM_OFFICE_LIVE and FM_OFFICE_LIVE_IDS to this home's task records other
#       than <own-id>, any secondmate, and any landing task, and
#       FM_OFFICE_LANDING and FM_OFFICE_LANDING_IDS to the landing tasks it
#       left out; returns 1 with FM_OFFICE_ERROR when a record cannot be read.
#   fm_office_task_landing <state-dir> <id> <office-id>
#       0 when task <id> is landing, as defined below. bin/fm-watch.sh reads it
#       too, to skip wedge alarms for a landing task (wedge_skip_landing), with
#       an empty <office-id> outside an office.
#
# Landing: a ship whose finished PR waits only on another home's merge holds no
# place under wip=, because its worker has stopped and the office can do
# nothing to land it. Every condition comes from a record firstmate already
# keeps, and any doubt counts the task:
#   - its meta records kind=ship and a pr= URL (bin/fm-pr-check.sh writes it
#     when the PR is ready);
#   - that PR is handed to a merger that is not this office: state/<id>.merge-handoff
#     names the same URL (bin/fm-pr-check.sh writes it once the handoff line
#     is delivered), or the task's own status holds that PR's open
#     merge-handoff-<n> decision naming the URL, or the project's merger
#     binding (bin/fm-project-mode.sh --merger) names another home and the task
#     is not held for the captain (bin/fm-captain-hold.sh open);
#   - its status folds to no open decision other than that handoff
#     (status_open_decisions in bin/fm-classify-lib.sh), so an open ask-user,
#     blocker or other question still counts;
#   - its latest status event, without merge-handoff lines, is a done line with
#     an [at=<epoch>] stamp, so a later working, paused, failed or resolved
#     event (a resumed worker) counts;
#   - its steering inbox holds no unhandled message and no handled one written
#     after that done line, so a worker steered back into fix work counts until
#     it reports done again.
# A handoff routed by an admission config (route.<class>=handoff:<home>) is
# recorded only on the office's parent channel, which is not read here, so such
# a task counts until one of the records above names it.
# Project capacity (bin/fm-project-capacity-lib.sh) and landing lag
# (data/projects.md landing-lag=) still bound every spawn, so leaving landing
# tasks out of wip= never lifts a project's own limits.
#
# Every FM_OFFICE_* authority variable is set only by fm_office_authority_load
# and fm_office_authority_parse, so in a home that is not an office they stay
# empty.

# Every FM_OFFICE_* result is read by the sourcing script, not here.
# shellcheck disable=SC2034

# Sourcing it again (bin/fm-config-inherit-lib.sh sources it too) must never
# reset an authority already loaded, so only the first source runs.
[ -z "${FM_OFFICE_AUTHORITY_LIB_SOURCED:-}" ] || return 0
FM_OFFICE_AUTHORITY_LIB_SOURCED=1

# shellcheck source=bin/fm-role-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-role-lib.sh"
# shellcheck source=bin/fm-registry-line-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-registry-line-lib.sh"

FM_OFFICE_ID=
FM_OFFICE_DISPATCH=
FM_OFFICE_MERGE=
FM_OFFICE_MERGE_VIA=
FM_OFFICE_AUTO_MERGE_CLASSES=
FM_OFFICE_WIP=
FM_OFFICE_ADMISSION_SHA256=
FM_OFFICE_DETECT_ID=
FM_OFFICE_ERROR=
FM_OFFICE_LIVE=0
FM_OFFICE_LIVE_IDS=
FM_OFFICE_LANDING=0
FM_OFFICE_LANDING_IDS=
# The office roles with a charter, and the role names held for later offices
# that have neither a charter nor any authority yet (none at present).
FM_OFFICE_ROLES="navigator quartermaster alchemist librarian"
FM_OFFICE_RESERVED_ROLES=""
FM_OFFICE_REPAIR="the main home reports this with bin/fm-office.sh ensure and republishes the record with bin/fm-office.sh publish <id>"

fm_office_in() {  # <item> <comma-list>
  case ",$2," in *",$1,"*) return 0 ;; esac
  return 1
}

fm_office_role_check() {  # <role>: 0 for an office role, or 1 with FM_OFFICE_ERROR
  case " $FM_OFFICE_ROLES " in *" $1 "*) return 0 ;; esac
  FM_OFFICE_ERROR="unknown role \"$1\" (known: $FM_OFFICE_ROLES)"
  [ -n "$1" ] || return 1
  case " $FM_OFFICE_RESERVED_ROLES " in
    *" $1 "*) FM_OFFICE_ERROR="role \"$1\" is reserved: it has no charter or authority yet" ;;
  esac
  return 1
}

fm_office_name_ok() {  # <word>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# fm_office_bad <reason>: the malformed-record refusal, reading the caller's
# $want and $file.
fm_office_bad() {
  # shellcheck disable=SC2154 # want and file are the calling loader's locals.
  FM_OFFICE_ERROR="office $want's authority record $file is malformed: $1; $FM_OFFICE_REPAIR"
}

fm_office_detect() {  # <home> <data-dir>
  local home=$1 charter=$2/charter.md marker=$1/.fm-office sm=$1/.fm-secondmate-home id sm_id heading=0
  FM_OFFICE_DETECT_ID=
  FM_OFFICE_ERROR=
  if [ -e "$charter" ] || [ -L "$charter" ]; then
    if [ ! -f "$charter" ] || [ ! -r "$charter" ]; then
      FM_OFFICE_ERROR="this home's charter $charter cannot be read, so whether it is an office cannot be told"
      return 2
    fi
    grep -q '^# Office authority' "$charter" && heading=1
  fi
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    [ "$heading" = 0 ] && return 1
    FM_OFFICE_ERROR="$charter has the \"# Office authority\" heading but this home has no .fm-office marker"
    return 2
  fi
  if [ -L "$marker" ] || [ ! -f "$marker" ] || [ ! -r "$marker" ]; then
    FM_OFFICE_ERROR="this home's .fm-office marker is not a readable regular file"
    return 2
  fi
  if [ -L "$sm" ] || [ ! -f "$sm" ] || [ ! -r "$sm" ]; then
    FM_OFFICE_ERROR="this home has an .fm-office marker but is not a seeded second mate (no readable .fm-secondmate-home)"
    return 2
  fi
  id=$(tr -d '[:space:]' < "$marker")
  sm_id=$(tr -d '[:space:]' < "$sm")
  if [ -z "$id" ] || [ "$id" != "$sm_id" ]; then
    FM_OFFICE_ERROR="this home's .fm-office marker names office '$id' but its .fm-secondmate-home names '$sm_id'"
    return 2
  fi
  if [ "$heading" = 0 ]; then
    FM_OFFICE_ERROR="this home has an .fm-office marker but $charter lacks the \"# Office authority\" heading"
    return 2
  fi
  FM_OFFICE_DETECT_ID=$id
  return 0
}

fm_office_admission_digest() {  # <config-dir> <name> [<remote-home>]
  local dir=$1/admission name=$2 remote=${3:-} f line sum listing='' words i
  local -a files=()
  [ -f "$dir/$name" ] && [ ! -L "$dir/$name" ] && [ -r "$dir/$name" ] || return 1
  files=("$dir/$name")
  line=$(grep -m 1 '^command=' "$dir/$name") || line=
  read -r -a words <<< "${line#command=}"
  for ((i = 0; i < ${#words[@]}; i++)); do
    [ "${words[$i]}" = --rules ] || continue
    f=${words[$((i + 1))]:-}
    # On a remote home the classifier reads <remote-home>/config/admission/<name>.rules,
    # a byte copy of this home's master, so the master stands in for that path.
    [ -z "$remote" ] || [ "$f" != "$remote/config/admission/$name.rules" ] || f="$dir/$name.rules"
    case "$f" in /*) files+=("$f") ;; *) return 1 ;; esac
  done
  if [ "${#files[@]}" -eq 1 ] && { [ -e "$dir/$name.rules" ] || [ -L "$dir/$name.rules" ]; }; then
    files+=("$dir/$name.rules")
  fi
  for f in "${files[@]}"; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 1
    sum=$(fm_role_sha256_stdin < "$f")
    [ -n "$sum" ] || return 1
    listing="$listing$sum
"
  done
  printf '%s' "$listing" | fm_role_sha256_stdin
}

fm_office_authority_load() {  # <config-dir> <office-id>
  local file=$1/office-authority receipt=$1/.fm-inherit-office-authority.generation want=$2
  FM_OFFICE_ID=
  FM_OFFICE_DISPATCH=
  FM_OFFICE_MERGE=
  FM_OFFICE_MERGE_VIA=
  FM_OFFICE_AUTO_MERGE_CLASSES=
  FM_OFFICE_WIP=
  FM_OFFICE_ADMISSION_SHA256=
  FM_OFFICE_ERROR=
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    FM_OFFICE_ERROR="office $want has no published authority record ($file with its receipt); $FM_OFFICE_REPAIR"
    return 1
  fi
  if ! fm_role_inherit_check "$file" "$receipt" "office authority record" "authority record"; then
    FM_OFFICE_ERROR="office $want's authority record is unproven: $FM_ROLE_DIAG; $FM_OFFICE_REPAIR"
    return 1
  fi
  if [ "$(sed -n '4p' "$receipt" 2>/dev/null)" = absent ]; then
    FM_OFFICE_ERROR="the main home published no authority for office $want; $FM_OFFICE_REPAIR"
    return 1
  fi
  fm_office_authority_parse "$file" "$want"
}

fm_office_authority_parse() {  # <file> <office-id>
  local file=$1 want=$2
  local line key value seen='' first=1 p pair id='' dispatch='' merge='' via='' auto='' wip='' sha='' entry
  FM_OFFICE_ERROR=
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = fm-office-authority-v1 ] && continue
      FM_OFFICE_ERROR="office $want's authority record $file does not start with fm-office-authority-v1; $FM_OFFICE_REPAIR"
      return 1
    fi
    key=${line%%=*}
    value=${line#*=}
    if [ "$key" = "$line" ]; then
      FM_OFFICE_ERROR="office $want's authority record $file has a line that is not key=value: $line; $FM_OFFICE_REPAIR"
      return 1
    fi
    case " $seen " in
      *" $key "*)
        FM_OFFICE_ERROR="office $want's authority record $file sets $key more than once; $FM_OFFICE_REPAIR"
        return 1
        ;;
    esac
    seen="$seen $key"
    case "$key" in
      id) id=$value ;;
      dispatch) dispatch=$value ;;
      merge) merge=$value ;;
      merge-via) via=$value ;;
      auto-merge-classes) auto=$value ;;
      wip) wip=$value ;;
      admission-sha256) sha=$value ;;
      *)
        FM_OFFICE_ERROR="office $want's authority record $file has an unknown key $key; $FM_OFFICE_REPAIR"
        return 1
        ;;
    esac
  done < "$file"
  for key in id dispatch merge merge-via auto-merge-classes wip admission-sha256; do
    case " $seen " in
      *" $key "*) ;;
      *)
        FM_OFFICE_ERROR="office $want's authority record $file has no $key= line; $FM_OFFICE_REPAIR"
        return 1
        ;;
    esac
  done
  [ "$id" = "$want" ] || { fm_office_bad "id=$id is not this office ($want)"; return 1; }
  [ "$merge" != none ] || merge=
  [ "$via" != none ] || via=
  [ "$auto" != none ] || auto=
  [ -z "$auto" ] || { fm_office_bad "auto-merge-classes must be none (no class auto-merges yet), got '$auto'"; return 1; }
  [[ "$wip" =~ ^[1-9]$ ]] || { fm_office_bad "wip must be a number from 1 to 9, got '$wip'"; return 1; }
  [ -n "$dispatch" ] || { fm_office_bad "dispatch names no project"; return 1; }
  for p in ${dispatch//,/ }; do
    fm_office_name_ok "$p" || { fm_office_bad "dispatch entry '$p' is not a project name"; return 1; }
  done
  for p in ${merge//,/ }; do
    fm_office_in "$p" "$dispatch" || { fm_office_bad "merge project '$p' is not in dispatch"; return 1; }
  done
  for pair in ${via//,/ }; do
    p=${pair%%=*}
    { [[ "$pair" == *=?* ]] && fm_office_name_ok "${pair#*=}"; } || { fm_office_bad "merge-via entry '$pair' is not <project>=<home>"; return 1; }
    fm_office_in "$p" "$dispatch" || { fm_office_bad "merge-via project '$p' is not in dispatch"; return 1; }
    ! fm_office_in "$p" "$merge" || { fm_office_bad "merge-via project '$p' is also in merge"; return 1; }
  done
  for entry in ${sha//,/ }; do
    p=${entry%%:*}
    [[ "$entry" =~ ^[^:]+:[0-9a-f]{64}$ ]] || { fm_office_bad "admission-sha256 entry '$entry' is not <project>:<sha256>"; return 1; }
    fm_office_in "$p" "$merge" || { fm_office_bad "admission-sha256 names '$p', which is not a merge project"; return 1; }
  done
  for p in ${merge//,/ }; do
    case ",$sha," in *",$p:"*) ;; *) fm_office_bad "merge project '$p' has no admission-sha256 entry"; return 1 ;; esac
  done
  FM_OFFICE_ID=$id
  FM_OFFICE_DISPATCH=$dispatch
  FM_OFFICE_MERGE=$merge
  FM_OFFICE_MERGE_VIA=$via
  FM_OFFICE_AUTO_MERGE_CLASSES=$auto
  FM_OFFICE_WIP=$wip
  FM_OFFICE_ADMISSION_SHA256=$sha
  return 0
}

fm_office_project_token() {  # <projects.md> <project> <key>
  local line tok
  [ -f "$1" ] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^-\ ([^\ ]+)\ \[([^]]*)\] ]] || continue
    [ "${BASH_REMATCH[1]}" = "$2" ] || continue
    for tok in ${BASH_REMATCH[2]}; do
      case "$tok" in "$3="*) printf '%s\n' "${tok#*=}"; return 0 ;; esac
    done
    return 0
  done < "$1"
}

# fm_office_payload_fail <reason>: the publisher's refusal, reading the
# caller's $want and $tmp.
fm_office_payload_fail() {
  # shellcheck disable=SC2154 # want and tmp are the calling publisher's locals.
  [ -z "$tmp" ] || rm -f "$tmp"
  FM_OFFICE_ERROR="cannot publish office $want's authority record: $1"
  return 1
}

fm_office_inherit_payload() {  # <src-config-dir> <src-data-dir> <dest-id> <dest-home> <out-file> [<remote-home>]
  local config=$1 REGISTRY=$2/offices.md want=$3 home=$4 out=$5 remote=${6:-} line match='' n=0 key p name digest tmp=''
  local dispatch merge via auto wip sha=''
  FM_OFFICE_ERROR=
  rm -f "$out" || { FM_OFFICE_ERROR="cannot clear the staged authority record $out"; return 1; }
  [ -n "$want" ] || return 0
  [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ] || return 0
  [ -f "$REGISTRY" ] && [ -r "$REGISTRY" ] || fm_office_payload_fail "$REGISTRY cannot be read" || return 1
  while IFS= read -r line; do
    case "$line" in "- $want "*) ;; *) continue ;; esac
    n=$((n + 1))
    match=$line
  done <<EOF
$(registry_lines)
EOF
  [ "$n" -gt 0 ] || return 0
  [ "$n" -eq 1 ] || fm_office_payload_fail "$REGISTRY has $n lines for it" || return 1
  if [ -n "$home" ]; then
    [ -f "$home/.fm-office" ] && [ ! -L "$home/.fm-office" ] && [ "$(tr -d '[:space:]' < "$home/.fm-office")" = "$want" ] || return 0
  fi
  [[ "$match" =~ $REGISTRY_LINE_RE ]] || fm_office_payload_fail "its line in $REGISTRY is malformed" || return 1
  for key in dispatch merge merge-via auto-merge-classes wip; do
    line_field "$match" "$key" >/dev/null || fm_office_payload_fail "its line in $REGISTRY has no $key: field" || return 1
  done
  dispatch=$(line_field "$match" dispatch)
  merge=$(line_field "$match" merge)
  via=$(line_field "$match" merge-via)
  auto=$(line_field "$match" auto-merge-classes)
  wip=$(line_field "$match" wip)
  if [ -n "$merge" ] && [ "$merge" != none ]; then
    [ -n "$home" ] || [ -n "$remote" ] || fm_office_payload_fail "it merges $merge, and its admission config cannot be pinned on a remote route without the remote home path" || return 1
    for p in ${merge//,/ }; do
      # A remote seed (bin/fm-remote-home-seed.sh) always names the config for a merge project after the project.
      if [ -n "$home" ]; then name=$(fm_office_project_token "$home/data/projects.md" "$p" admission); else name=$p; fi
      [ -n "$name" ] || fm_office_payload_fail "merge project $p has no admission= in $home/data/projects.md" || return 1
      fm_office_name_ok "$name" || fm_office_payload_fail "merge project $p names admission config '$name', which is not a name" || return 1
      digest=$(fm_office_admission_digest "$config" "$name" "$remote") \
        || fm_office_payload_fail "the main home's master admission config $config/admission/$name or a rules file it names cannot be read" || return 1
      sha="${sha:+$sha,}$p:$digest"
    done
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-office-authority.XXXXXX") || fm_office_payload_fail "cannot stage the record" || return 1
  printf '%s\n' fm-office-authority-v1 "id=$want" "dispatch=$dispatch" "merge=$merge" "merge-via=$via" \
    "auto-merge-classes=$auto" "wip=$wip" "admission-sha256=$sha" > "$tmp" \
    || fm_office_payload_fail "cannot stage the record" || return 1
  if ! FM_OFFICE_ERROR=$(fm_office_authority_parse "$tmp" "$want" >/dev/null || { printf '%s' "$FM_OFFICE_ERROR"; exit 1; }); then
    fm_office_payload_fail "its line in $REGISTRY does not make a valid record (${FM_OFFICE_ERROR%%; the main home*})"
    return 1
  fi
  mv -f "$tmp" "$out" || fm_office_payload_fail "cannot stage the record" || return 1
}

fm_office_resolve() {  # <home> <data-dir> <config-dir>
  local rc=0
  FM_OFFICE_ID=
  fm_office_detect "$1" "$2" || rc=$?
  case "$rc" in
    0) fm_office_authority_load "$3" "$FM_OFFICE_DETECT_ID" ;;
    1) return 0 ;;
    *)
      FM_OFFICE_ERROR="$FM_OFFICE_ERROR; $FM_OFFICE_REPAIR"
      return 1
      ;;
  esac
}

# The last value of <key>= in a task record, or nothing.
fm_office_meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# 0 when the handled steering message <msg> was written after <epoch>, or when
# its time cannot be read.
fm_office_msg_after() {  # <msg> <epoch>
  local schema at epoch
  { IFS= read -r schema; IFS= read -r at; } < "$1" 2>/dev/null || return 0
  case "$at" in at=*) ;; *) return 0 ;; esac
  epoch=$(fm_utc_iso_to_epoch "${at#at=}") || return 0
  [ "$epoch" -ge "$2" ]
}

fm_office_task_landing() {  # <state-dir> <id> <office-id>
  local state=$1 id=$2 self=$3 meta=$1/$2.meta status=$1/$2.status url n open key verb note handed=0 last done_at msg project merger rc=0
  [ "$(fm_office_meta_value "$meta" kind)" = ship ] || return 1
  url=$(fm_office_meta_value "$meta" pr)
  [ -n "$url" ] || return 1
  n=${url##*/}
  [ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ] || return 1
  open=$(status_open_decisions "$status" ship)
  while IFS=$'\t' read -r key verb note; do
    [ -n "$key" ] || continue
    [ "$key" = "merge-handoff-$n" ] || return 1
    case "$note" in *"$url"*) handed=1 ;; esac
  done <<EOF
$open
EOF
  last=$(_fm_status_latest_event "$status" merge-handoff-)
  status_line_verb "$last" verb
  [ "$verb" = "done" ] || return 1
  done_at=$(status_line_at_epoch "$last") || return 1
  for msg in "$state/$id.inbox"/*.msg; do
    [ ! -e "$msg" ] || return 1
  done
  for msg in "$state/$id.inbox/handled"/*.msg; do
    [ -f "$msg" ] || continue
    ! fm_office_msg_after "$msg" "$done_at" || return 1
  done
  [ "$handed" = 0 ] || return 0
  if [ -f "$state/$id.merge-handoff" ] && [ ! -L "$state/$id.merge-handoff" ]; then
    read -r key _ < "$state/$id.merge-handoff" 2>/dev/null || key=
    [ "$key" != "$url" ] || return 0
  fi
  project=$(fm_office_meta_value "$meta" project)
  [ -n "$project" ] && [ -n "$self" ] || return 1
  merger=$("$(dirname "${BASH_SOURCE[0]}")/fm-project-mode.sh" --merger "$(basename "$project")" 2>/dev/null) || return 1
  [ -n "$merger" ] && [ "$merger" != "$self" ] || return 1
  FM_STATE_OVERRIDE="$state" "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold.sh" open "$id" --distinguish-absent >/dev/null 2>&1 || rc=$?
  case "$rc" in 1|3) return 0 ;; esac
  return 1
}

fm_office_live_tasks() {  # <state-dir> <own-id> <office-id>
  local meta id
  FM_OFFICE_LIVE=0
  FM_OFFICE_LIVE_IDS=
  FM_OFFICE_LANDING=0
  FM_OFFICE_LANDING_IDS=
  # The landing test reads the status fold, which bin/fm-classify-lib.sh owns.
  if ! declare -F status_open_decisions >/dev/null; then
    # shellcheck source=bin/fm-classify-lib.sh
    . "$(dirname "${BASH_SOURCE[0]}")/fm-classify-lib.sh"
  fi
  for meta in "$1"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" != "$2" ] || continue
    [ -r "$meta" ] || {
      FM_OFFICE_ERROR="task record $meta cannot be read to count this office's live tasks"
      return 1
    }
    ! grep -qx 'kind=secondmate' "$meta" || continue
    if fm_office_task_landing "$1" "$id" "${3-}"; then
      FM_OFFICE_LANDING=$((FM_OFFICE_LANDING + 1))
      FM_OFFICE_LANDING_IDS="${FM_OFFICE_LANDING_IDS:+$FM_OFFICE_LANDING_IDS, }$id"
      continue
    fi
    FM_OFFICE_LIVE=$((FM_OFFICE_LIVE + 1))
    FM_OFFICE_LIVE_IDS="${FM_OFFICE_LIVE_IDS:+$FM_OFFICE_LIVE_IDS, }$id"
  done
  return 0
}
