#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration/backlog-and-decisions.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Body edits: `update <id>` with --body or --body-file replaces the task's whole
# note, so this command reads the current body first (`show <id> --full`) and
# guards the write, because a failed read once became an empty "existing" body
# and a one-line update wiped a task's note (PC-3268):
#   - a body that cannot be read (task missing, tasks-axi failed, no body field
#     in its output) is refused with nothing written, never treated as empty;
#   - a new body that does not contain the existing text is refused unless
#     --replace (discard it on purpose) or --archive-body (tasks-axi keeps the
#     previous body in its archive) is given; an existing empty body needs
#     neither;
#   - --append <text> adds <text> as a new line after the existing body (or
#     becomes the body when that is empty) and cannot combine with --body,
#     --body-file, --replace, or --archive-body.
# --replace and --append are this command's own flags and never reach
# tasks-axi. Other subcommands, and updates that set no body, pass through
# unchanged. The read and the write are two tasks-axi calls, so a concurrent
# writer is not detected; backlog writers serialize through the reserved
# `backlog` lease (bin/fm-lease.sh).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - an `update` body edit that fails the body guard above;
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi


# Read the task's current body into BODY_OLD. Returns nonzero with a reason in
# BODY_READ_ERROR when it cannot, so the caller refuses instead of treating an
# unreadable body as an empty one.
BODY_OLD=
BODY_READ_ERROR=
read_current_body() {  # <task-id>
  local out
  BODY_OLD=
  if ! out=$(tasks-axi show "$1" --full 2>&1); then
    BODY_READ_ERROR="tasks-axi show $1 --full failed: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"
    return 1
  fi
  if ! BODY_OLD=$(printf '%s\n' "$out" | perl -MJSON::PP -e '
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my $json = JSON::PP->new->allow_nonref;
    my ($id_seen, $body);
    while (my $line = <STDIN>) {
      chomp $line;
      $id_seen = 1 if $line =~ /^  id: /;
      next unless $line =~ /^  body: ?(.*)\z/;
      my $raw = $1;
      $body = $raw =~ /^"/ ? eval { $json->decode($raw) } : $raw;
      last;
    }
    exit 3 unless $id_seen && defined $body;
    print $body;
  '); then
    BODY_READ_ERROR="tasks-axi show $1 --full returned no readable body field"
    return 1
  fi
  return 0
}

# Read a --body-file value exactly (trailing newlines kept) into BODY_FILE_TEXT.
BODY_FILE_TEXT=
read_body_file() {  # <path>
  [ -r "$1" ] || fail "update refused: --body-file $1 is not readable, so the new body cannot be compared with the existing note"
  BODY_FILE_TEXT=$(cat -- "$1"; printf x) || fail "update refused: cannot read --body-file $1"
  BODY_FILE_TEXT=${BODY_FILE_TEXT%x}
}

# Guard an `update` that sets or appends a body. Rewrites ARGS for tasks-axi
# and sets BODY_GUARD_TMP to a staged body file the caller must remove.
BODY_GUARD_TMP=
guard_body_update() {
  local i n arg id='' new_text='' have_new=0 replace=0 archive=0 append=0 append_text=''
  local -a final=("${ARGS[0]}")
  n=${#ARGS[@]}
  for ((i = 1; i < n; i++)); do
    arg=${ARGS[i]}
    case "$arg" in
      --replace) replace=1 ;;
      --archive-body) archive=1; final+=("$arg") ;;
      --append)
        append=1
        i=$((i + 1))
        [ "$i" -lt "$n" ] || fail "update refused: --append needs text"
        append_text=${ARGS[i]}
        ;;
      --append=*) append=1; append_text=${arg#*=} ;;
      --body)
        have_new=1
        i=$((i + 1))
        [ "$i" -lt "$n" ] || fail "update refused: --body needs text"
        new_text=${ARGS[i]}
        ;;
      --body=*) have_new=1; new_text=${arg#*=} ;;
      --body-file)
        have_new=1
        i=$((i + 1))
        [ "$i" -lt "$n" ] || fail "update refused: --body-file needs a path"
        read_body_file "${ARGS[i]}"
        new_text=$BODY_FILE_TEXT
        ;;
      --body-file=*) have_new=1; read_body_file "${arg#*=}"; new_text=$BODY_FILE_TEXT ;;
      -*) final+=("$arg") ;;
      *)
        [ -z "$id" ] && id=$arg
        final+=("$arg")
        ;;
    esac
  done
  if [ "$append" = 0 ] && [ "$have_new" = 0 ]; then
    [ "$replace" = 0 ] || fail "update refused: --replace only applies together with --body or --body-file"
    return 0
  fi
  [ -n "$id" ] || fail "update refused: no task id given"
  if [ "$append" = 1 ]; then
    if [ "$have_new" = 1 ] || [ "$replace" = 1 ] || [ "$archive" = 1 ]; then
      fail "update refused: --append adds to the existing note and cannot combine with --body, --body-file, --replace, or --archive-body"
    fi
    [ -n "$append_text" ] || fail "update refused: --append needs non-empty text"
  fi
  read_current_body "$id" \
    || fail "update refused, nothing written: $BODY_READ_ERROR; the existing note could not be read, so replacing it could wipe it"
  if [ "$append" = 1 ]; then
    if [ -n "$BODY_OLD" ]; then
      new_text=$BODY_OLD$'\n'$append_text
    else
      new_text=$append_text
    fi
  elif [ -n "$BODY_OLD" ] && [ "$replace" = 0 ] && [ "$archive" = 0 ]; then
    case "$new_text" in
      *"$BODY_OLD"*) ;;
      *) fail "update refused, nothing written: the new body for $id drops the existing note text; use --append to add a line, keep the existing text in the new body, or pass --replace to discard it (--archive-body keeps the old body in the archive)" ;;
    esac
  fi
  BODY_GUARD_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tasks-axi-body.XXXXXX") \
    || fail "cannot stage the new body"
  if ! printf '%s\n' "$new_text" > "$BODY_GUARD_TMP"; then
    rm -f -- "$BODY_GUARD_TMP"
    fail "cannot stage the new body"
  fi
  ARGS=("${final[@]}" --body-file "$BODY_GUARD_TMP")
}

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
case "${1:-}" in
  update|edit)
    guard_body_update
    if [ -n "$BODY_GUARD_TMP" ]; then
      tasks-axi ${ARGS[@]+"${ARGS[@]}"}
      rc=$?
      rm -f -- "$BODY_GUARD_TMP"
      exit "$rc"
    fi
    exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
    ;;
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
