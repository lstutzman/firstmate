#!/usr/bin/env bash
# Admission by class: which classes of change in a pull request need the
# captain's recorded word before bin/fm-pr-merge.sh may merge it.
#
# Sourced, never executed. A project opts in with admission=<config> on its
# data/projects.md line (bin/fm-project-mode.sh owns the token), naming this
# home's config/admission/<config> file:
#   # comments and blank lines are ignored
#   command=scripts/ci/classify-diff.sh --risk --stdin
#   classes=payments legal-text data-rewriting-migration
#   clear=none
# command and classes are required, clear is optional, each appears at most
# once, and no other key is accepted. command is split on spaces with no shell
# quoting or expansion. classes is the space-separated list of class names
# that need the captain's word, and clear the verdict words that need nothing;
# every name, like every word the classifier prints, is [A-Za-z0-9._-] and does
# not start with a dot, because a class becomes part of a task id.
#
# The classifier contract matches the project's own diff classifier: it runs
# with the project's local copy as its working directory, so a relative command
# resolves inside that copy, reads the changed paths on stdin one per line, and
# prints class words on stdout separated by whitespace; it must exit 0 and must
# not write. It runs from the home's copy of the project, never from the pull
# request's head, so a pull request cannot rewrite the classifier that judges
# it. Every printed word must be a configured class or clear word, and at
# least one word must be printed, so a classifier that ignores its mode and
# prints some other verdict, or prints nothing, refuses instead of admitting
# every change. A classifier that cannot run, exits nonzero, exceeds its time
# bound, or prints an empty or undeclared verdict is an error.
#
#   fm_admission_load <config-file>
#       Sets FM_ADMISSION_COMMAND (array), FM_ADMISSION_CLASSES, and
#       FM_ADMISSION_CLEAR (one word per line), or sets FM_ADMISSION_ERROR and
#       returns 1.
#   fm_admission_classify <project-dir> <paths-file>
#       Sets FM_ADMISSION_FLAGGED to the configured classes the classifier
#       printed, sorted and one per line (empty when none), or sets
#       FM_ADMISSION_ERROR and returns 1.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

FM_ADMISSION_CLASSIFIER_TIMEOUT=${FM_ADMISSION_CLASSIFIER_TIMEOUT:-120}
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_ADMISSION_FLAGGED=
FM_ADMISSION_ERROR=

fm_admission_name_ok() {  # <word>
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_admission_load() {  # <config-file>
  local file=$1 line key value command='' classes='' clear='' seen='' class names
  FM_ADMISSION_COMMAND=()
  FM_ADMISSION_CLASSES=
  FM_ADMISSION_CLEAR=
  FM_ADMISSION_ERROR=
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_ADMISSION_ERROR="the admission config $file is missing or unreadable"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    if [ "$key" = "$line" ]; then
      FM_ADMISSION_ERROR="the admission config $file has a line that is not key=value: $line"
      return 1
    fi
    case " $seen " in
      *" $key "*)
        FM_ADMISSION_ERROR="the admission config $file sets $key more than once"
        return 1
        ;;
    esac
    seen="$seen $key"
    case "$key" in
      command) command=$value ;;
      classes) classes=$value ;;
      clear) clear=$value ;;
      *)
        FM_ADMISSION_ERROR="the admission config $file has an unknown key $key; only command=, classes=, and clear= are accepted"
        return 1
        ;;
    esac
  done < "$file"
  read -r -a FM_ADMISSION_COMMAND <<< "$command"
  if [ "${#FM_ADMISSION_COMMAND[@]}" -eq 0 ]; then
    FM_ADMISSION_ERROR="the admission config $file names no classifier command="
    return 1
  fi
  read -r -a names <<< "$classes"
  for class in "${names[@]+"${names[@]}"}"; do
    if ! fm_admission_name_ok "$class"; then
      FM_ADMISSION_ERROR="the admission config $file names a class that is not a class name: $class"
      return 1
    fi
    FM_ADMISSION_CLASSES="$FM_ADMISSION_CLASSES$class
"
  done
  if [ -z "$FM_ADMISSION_CLASSES" ]; then
    FM_ADMISSION_ERROR="the admission config $file names no classes="
    return 1
  fi
  read -r -a names <<< "$clear"
  for class in "${names[@]+"${names[@]}"}"; do
    if ! fm_admission_name_ok "$class"; then
      FM_ADMISSION_ERROR="the admission config $file names a clear word that is not a class name: $class"
      return 1
    fi
    FM_ADMISSION_CLEAR="$FM_ADMISSION_CLEAR$class
"
  done
}

fm_admission_classify() {  # <project-dir> <paths-file>
  local dir=$1 paths=$2 out err rc=0 word flagged='' printed=0
  FM_ADMISSION_FLAGGED=
  FM_ADMISSION_ERROR=
  if [ ! -d "$dir" ]; then
    FM_ADMISSION_ERROR="the project copy $dir that the classifier runs in is missing"
    return 1
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/fm-admission-out.XXXXXX") || return 1
  err=$(mktemp "${TMPDIR:-/tmp}/fm-admission-err.XXXXXX") || { rm -f "$out"; return 1; }
  (cd "$dir" && fm_run_timed "$FM_ADMISSION_CLASSIFIER_TIMEOUT" "${FM_ADMISSION_COMMAND[@]}") \
    < "$paths" > "$out" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    FM_ADMISSION_ERROR="the classifier '${FM_ADMISSION_COMMAND[*]}' in $dir failed with status $rc"
    [ "$rc" -ne 124 ] || FM_ADMISSION_ERROR="$FM_ADMISSION_ERROR (its ${FM_ADMISSION_CLASSIFIER_TIMEOUT}s bound)"
    [ ! -s "$err" ] || FM_ADMISSION_ERROR="$FM_ADMISSION_ERROR: $(head -n 1 "$err")"
    rm -f "$out" "$err"
    return 1
  fi
  while read -r word; do
    [ -n "$word" ] || continue
    if ! fm_admission_name_ok "$word"; then
      FM_ADMISSION_ERROR="the classifier '${FM_ADMISSION_COMMAND[*]}' in $dir printed a word that is not a class name: $word"
      rm -f "$out" "$err"
      return 1
    fi
    printed=1
    if printf '%s' "$FM_ADMISSION_CLASSES" | grep -qxF -- "$word"; then
      flagged="$flagged$word
"
    elif ! printf '%s' "$FM_ADMISSION_CLEAR" | grep -qxF -- "$word"; then
      FM_ADMISSION_ERROR="the classifier '${FM_ADMISSION_COMMAND[*]}' in $dir printed $word, which the admission config declares in neither classes= nor clear="
      rm -f "$out" "$err"
      return 1
    fi
  done < <(tr -s '[:space:]' '\n' < "$out")
  rm -f "$out" "$err"
  if [ "$printed" -eq 0 ]; then
    FM_ADMISSION_ERROR="the classifier '${FM_ADMISSION_COMMAND[*]}' in $dir printed no verdict; a diff with no flagged class must print a clear= word"
    return 1
  fi
  # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
  FM_ADMISSION_FLAGGED=$(printf '%s' "$flagged" | LC_ALL=C sort -u)
}
