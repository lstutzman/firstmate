#!/usr/bin/env bash
# Path-rule admission classifier: a generic command for the admission contract
# in bin/fm-admission-lib.sh. It reads changed paths on stdin, one per line, and
# prints the class words their path rules flag, one per line and sorted, or
# `none` when no path matches a rule.
#
# Usage: fm-reserved-classify.sh --rules <rules-file> < paths
#
# A project opts in from this home's config/admission/<config>:
#   command=/path/to/bin/fm-reserved-classify.sh --rules /path/to/firstmate.rules
#   classes=authority credentials production
#   clear=none
#
# The rules file holds `<glob> <class>` lines; `#` comments and blank lines are
# ignored. For each path the first matching rule wins, and a path matching no
# rule is clear. Globs match the whole path and are case sensitive:
#   *       any run of characters except /
#   **      any run of characters including /; a leading or inner `**/` also
#           matches no directory at all, so `**/x` matches `x` and `a/x`
#   ?       one character except /
#   {a,b}   either alternative, nested allowed
# Any other character matches itself; there is no escaping and no bracket class.
#
# The rules file is read from the home, never the pull request, so a PR cannot
# rewrite the rules that judge it. A missing or unreadable rules file, a line
# that is not exactly `<glob> <class>`, an unbalanced brace, a glob whose
# regex the platform will not compile (BSD/macOS regcomp rejects an empty brace
# alternative such as `config{,.local}.json`, which glibc accepts), or a class
# name outside [A-Za-z0-9._-] (or `none`, which is reserved for the clear
# verdict) exits 1 with a message on stderr and prints nothing, so a broken rule file
# refuses a merge rather than admitting every change.

set -u

die() {
  printf 'fm-reserved-classify: %s\n' "$*" >&2
  exit 1
}

# glob_to_ere <glob>: prints an anchored extended regex, or returns 1.
glob_to_ere() {
  local glob=$1 re='' depth=0 i=0 c next len=${#1}
  while [ "$i" -lt "$len" ]; do
    c=${glob:i:1}
    next=${glob:i+1:1}
    case "$c" in
      '*')
        if [ "$next" = '*' ]; then
          if [ "${glob:i+2:1}" = '/' ]; then
            re="$re(.*/)?"
            i=$((i + 3))
          else
            re="$re.*"
            i=$((i + 2))
          fi
          continue
        fi
        re="${re}[^/]*"
        ;;
      '?') re="${re}[^/]" ;;
      '{')
        depth=$((depth + 1))
        re="$re("
        ;;
      '}')
        [ "$depth" -gt 0 ] || return 1
        depth=$((depth - 1))
        re="$re)"
        ;;
      ',')
        if [ "$depth" -gt 0 ]; then re="$re|"; else re="$re,"; fi
        ;;
      '.'|'+'|'('|')'|'['|']'|'^'|'$'|'|'|"\\") re="$re\\$c" ;;
      *) re="$re$c" ;;
    esac
    i=$((i + 1))
  done
  [ "$depth" -eq 0 ] || return 1
  printf '^%s$' "$re"
}

rules_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rules)
      [ "$#" -ge 2 ] || die '--rules needs a file'
      rules_file=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$rules_file" ] || die 'usage: fm-reserved-classify.sh --rules <rules-file> < paths'
[ -f "$rules_file" ] && [ -r "$rules_file" ] || die "the rules file $rules_file is missing or unreadable"

res=()
classes=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  case "$line" in ''|'#'*) continue ;; esac
  read -r glob class extra <<< "$line"
  if [ -z "$glob" ] || [ -z "${class:-}" ] || [ -n "${extra:-}" ]; then
    die "$rules_file line $lineno is not '<glob> <class>': $line"
  fi
  case "$class" in
    none|.*|*[!A-Za-z0-9._-]*) die "$rules_file line $lineno has an invalid class name: $class" ;;
  esac
  re=$(glob_to_ere "$glob") || die "$rules_file line $lineno has an invalid glob: $glob"
  rc=0
  [[ '' =~ $re ]] || rc=$?
  [ "$rc" -ne 2 ] || die "$rules_file line $lineno has an invalid glob: $glob"
  res+=("$re")
  classes+=("$class")
done < "$rules_file"

flagged=''
while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  for idx in "${!res[@]}"; do
    if [[ $path =~ ${res[$idx]} ]]; then
      flagged="$flagged${classes[$idx]}
"
      break
    fi
  done
done

if [ -z "$flagged" ]; then
  echo none
else
  printf '%s' "$flagged" | LC_ALL=C sort -u
fi
