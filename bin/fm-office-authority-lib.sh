#!/usr/bin/env bash
# fm-office-authority-lib.sh - is this home an office, and what may it do.
#
# Sourced, never executed. An office is a second mate that runs a standing role
# mandate (docs/configuration.md "Offices (data/offices.md)"). bin/fm-spawn.sh
# and bin/fm-pr-merge.sh call fm_office_resolve and, in an office, refuse what
# the office's authority record does not cover. Outside an office nothing here
# changes what either script does. This library grants nothing: every result is
# either "not an office" or a narrower set of allowed actions.
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
# the main home (a later change adds the publisher). It is trusted only while
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
# "<sha256 of file>  admission/<file>\n" for config/admission/<name> and then,
# when it exists, config/admission/<name>.rules (the conventional path-rule file
# a bin/fm-reserved-classify.sh classifier reads). It lets an office's merge
# notice a local edit to its own classifier config or rules.
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
#       prints the digest above, or returns 1 when config/admission/<name> is
#       missing or unreadable.
#   fm_office_in <item> <comma-list>
#   fm_office_live_tasks <state-dir> <own-id>
#       sets FM_OFFICE_LIVE and FM_OFFICE_LIVE_IDS to this home's task records
#       other than <own-id> and any secondmate, or returns 1 with
#       FM_OFFICE_ERROR when a record cannot be read.
#
# Every FM_OFFICE_* authority variable is set only by fm_office_authority_load,
# so in a home that is not an office they stay empty.

# Every FM_OFFICE_* result is read by the sourcing script, not here.
# shellcheck disable=SC2034
# shellcheck source=bin/fm-role-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-role-lib.sh"

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
FM_OFFICE_REPAIR="the main home reports and repairs this with bin/fm-office.sh ensure"

fm_office_in() {  # <item> <comma-list>
  case ",$2," in *",$1,"*) return 0 ;; esac
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

fm_office_admission_digest() {  # <config-dir> <name>
  local dir=$1/admission name=$2 f sum listing=
  for f in "$name" "$name.rules"; do
    if [ ! -e "$dir/$f" ] && [ ! -L "$dir/$f" ]; then
      [ "$f" = "$name" ] && return 1
      continue
    fi
    [ -f "$dir/$f" ] && [ ! -L "$dir/$f" ] && [ -r "$dir/$f" ] || return 1
    sum=$(fm_role_sha256_stdin < "$dir/$f")
    [ -n "$sum" ] || return 1
    listing="$listing$sum  admission/$f
"
  done
  printf '%s' "$listing" | fm_role_sha256_stdin
}

fm_office_authority_load() {  # <config-dir> <office-id>
  local file=$1/office-authority receipt=$1/.fm-inherit-office-authority.generation want=$2
  local line key value seen='' first=1 p pair id='' dispatch='' merge='' via='' auto='' wip='' sha='' entry
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

fm_office_live_tasks() {  # <state-dir> <own-id>
  local meta id
  FM_OFFICE_LIVE=0
  FM_OFFICE_LIVE_IDS=
  for meta in "$1"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" != "$2" ] || continue
    [ -r "$meta" ] || {
      FM_OFFICE_ERROR="task record $meta cannot be read to count this office's live tasks"
      return 1
    }
    ! grep -qx 'kind=secondmate' "$meta" || continue
    FM_OFFICE_LIVE=$((FM_OFFICE_LIVE + 1))
    FM_OFFICE_LIVE_IDS="${FM_OFFICE_LIVE_IDS:+$FM_OFFICE_LIVE_IDS, }$id"
  done
  return 0
}
