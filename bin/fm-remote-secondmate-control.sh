#!/usr/bin/env bash
# Host-local lifecycle control for the remote secondmate home selected by fm-on.
#
# Usage:
#   fm-remote-secondmate-control.sh launch <id> <harness> <model|-> <effort|-> {herdr|rex} [traceparent]
#   fm-remote-secondmate-control.sh relaunch <id> <harness> <model|default|-> <effort|default|->
#   fm-remote-secondmate-control.sh state <id>
#   fm-remote-secondmate-control.sh route <id>
#   fm-remote-secondmate-control.sh send <id> <message> [fire-and-forget]
#   fm-remote-secondmate-control.sh send-stdin <id> [fire-and-forget]  # message on stdin
#   fm-remote-secondmate-control.sh key <id> <key>
#   fm-remote-secondmate-control.sh capture <id> [lines]
#   fm-remote-secondmate-control.sh observe <id>
#   fm-remote-secondmate-control.sh sync <id> [<parent-commit>]
#   fm-remote-secondmate-control.sh update <id>
#   fm-remote-secondmate-control.sh retire <id> [--force]
#   fm-remote-secondmate-control.sh adopt <id> <agent_session_id>
#
# Remote placement ends here, but the second-mate agent runs only on a session
# backend whose server survives every SSH disconnection that supervises it:
# herdr in this code root's remote session (bin/fm-remote-herdr-identity-lib.sh),
# or rex in this home's 2ndmate-<id>-<hash> session on the personal rex server.
# Launch refuses any other selection rather than reading this home's
# config/backend. The user's interactive sessions remain for the user's work,
# unless the account opts a Herdr session in with ~/.firstmate/remote-herdr-session
# (one session name, never fm-remote*): every verb here then uses that session,
# route reports herdr_session_source=selected, and nothing here creates, owns,
# starts, or stops that session's server (FM_BACKEND_HERDR_NO_AUTOSTART_SESSION):
# a verb that needs it while it is stopped fails instead.
# fm-spawn/fm-send/fm-teardown keep owning the local endpoint mechanics.
# The home's own workers keep their ordinary backend selection.
# bin/fm-remote-doctor.sh owns that host's readiness for the selected backend.
# docs/remote-secondmates.md owns why.
#
# launch and relaunch refuse when the home's state/.lock names a live process
# and the recorded endpoint is not the live agent, because starting then would
# put a second agent beside the running one (the watcher's auto-relaunch runs
# through launch). Use adopt instead.
#
# adopt binds this host's endpoint record to an agent that is ALREADY running,
# for example one started by hand in the user's visible Herdr session. It
# never launches, relaunches, or stops anything. It finds the pane in the
# selected session whose Herdr agent session id is <agent_session_id>, and
# refuses unless: the recorded endpoint is not alive (or is already that pane,
# when adopt only prints the route, so a repeat converges); the pane's agent matches
# the recorded harness; the home's state/.lock names a live harness process
# inside that pane whose working directory is this home; and
# state/.lock-session equals <agent_session_id>. An agent started without
# Firstmate's launch flags is accepted when those checks pass. It then rewrites
# the host-side record (window and the herdr_* fields) under the metadata lock
# and prints the same route block `route` prints; the parent runs it through
# bin/fm-remote-secondmate-adopt.sh, which updates its own record from that.
#
# With <parent-commit>, sync follows the PARENT PRIMARY's default-branch commit,
# which the parent resolves on its own checkout and passes in, so a remote home
# tracks the primary exactly like a local one instead of stopping at whatever
# this host's Firstmate copy happens to hold. Omitting <parent-commit> targets
# this host's own code-root HEAD instead, which is what /updatefirstmate wants
# after it has refreshed that
# code root from origin. Because this home is a standalone clone, the target
# commit is imported here first and the fast-forward itself is the shared one in
# bin/fm-ff-lib.sh, so the clean, ancestry, and branch guards have a single owner.
# A private parent-route state directory stores only the remote secondmate
# agent's endpoint record; the home's own
# state/*.meta remains reserved for workers the secondmate supervises.
# Retirement closes only this secondmate's panes or workspace and never
# stops the remote Herdr service or removes a sibling secondmate's workspace or panes.
# It converges: a home that is already gone, or whose path holds only empty
# directories, answers `already-retired` and leaves the path absent, so a
# parent whose earlier attempt lost the result can rerun it and finish.
#
# Relaunch is not a second lifecycle implementation: it runs the ORDINARY local
# control plane here, because from this host the mate is a plain local
# secondmate. cmd_relaunch below owns why the parent must hand it the profile.
# It ends by printing the same route block `route` prints, so a caller that
# invoked it directly (rather than through bin/fm-remote-secondmate-relaunch.sh,
# which reads this block to keep the parent's own record in sync) still gets
# the confirmed identity.
#
# The optional launch traceparent is the per-task W3C trace-context carrier the
# PARENT home resolved for this secondmate; this host only delivers it to the
# pane, and fm-spawn validates it (bin/fm-trace-context-lib.sh). Omitting it is
# the default-off path. print_route echoes the carrier the endpoint actually
# holds, including for an already-alive endpoint that was not relaunched, so the
# parent records the identity the agent really received rather than an intent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
CONTROL_STATE="$TARGET_HOME/state/parent-route"
CONTROL_DATA="$TARGET_HOME/data/.parent-route"
REMOTE_HERDR_SESSION=
# Rex starts a missing server as exit-empty, which remote readiness refuses and
# cannot repair while it answers, so nothing this control plane runs may start
# one: bin/fm-remote-doctor.sh --fix alone starts the persistent server.
export FM_BACKEND_REX_NO_AUTOSTART=1

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac; }

# Sourcing fm-wake-lib.sh through the libraries below creates "$FM_HOME/state",
# so recognize an already-retired home before loading them rather than
# fabricating an unseeded home that every later retirement then refuses.
# The accepted arguments match the retire dispatcher's.
if [ "${1:-}" = retire ] && [ ! -e "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ]; then
  case "$#:${3:-}" in
    2:|3:|3:--force) validate_id "$2"; printf 'already-retired: %s\n' "$2"; exit 0 ;;
    *) usage ;;
  esac
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-remote-herdr-identity-lib.sh
. "$SCRIPT_DIR/fm-remote-herdr-identity-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# The Herdr session this code root's remote mates live in, resolved by the same
# owner the readiness doctor prepares the service under.
remote_herdr_session_resolve() {
  [ -z "$REMOTE_HERDR_SESSION" ] || return 0
  fm_remote_herdr_identity "$FM_ROOT" || return 1
  REMOTE_HERDR_SESSION=$FM_REMOTE_HERDR_SESSION
  [ "$FM_REMOTE_HERDR_SELECTED" != 1 ] || export FM_BACKEND_HERDR_NO_AUTOSTART_SESSION=$REMOTE_HERDR_SESSION
}

remote_herdr_session_error() {
  printf '%s' "${FM_REMOTE_HERDR_ERROR:-no SHA-256 tool resolves to name the Herdr session for code root $FM_ROOT}"
}

# True when the home path holds directories and nothing else, after removing
# them. The libraries sourced above create $TARGET_HOME/state on load, so every
# command aimed at a retired home, this one included, leaves that bare tree at
# the retired path. It carries no home to protect, and rmdir cannot delete
# content, so a tree that turns out to hold anything is left for the refusal.
clear_empty_home_leftover() {
  local content
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || return 1
  content=$(find "$TARGET_HOME" ! -type d -print -quit 2>/dev/null) || return 1
  [ -z "$content" ] || return 1
  find "$TARGET_HOME" -depth -type d -exec rmdir -- {} \; 2>/dev/null || return 1
  [ ! -e "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ]
}

validate_home() { # <id> [allow-absent]
  local id=$1 allow_absent=${2:-no} marker
  if [ "$allow_absent" = yes ]; then
    if [ ! -e "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ]; then return 2; fi
    if clear_empty_home_leftover; then return 2; fi
  fi
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "remote secondmate home is unavailable or unsafe"
  [ -f "$TARGET_HOME/.fm-secondmate-home" ] && [ ! -L "$TARGET_HOME/.fm-secondmate-home" ] \
    || die "remote home is not a seeded secondmate home"
  marker=$(cat "$TARGET_HOME/.fm-secondmate-home")
  [ "$marker" = "$id" ] || die "remote home belongs to $marker, not $id"
  [ -f "$TARGET_HOME/AGENTS.md" ] && [ -d "$TARGET_HOME/bin" ] || die "remote home is not a Firstmate checkout"
}

meta_path() { printf '%s/%s.meta\n' "$CONTROL_STATE" "$1"; }

remote_endpoint_load() {
  local id=$1 herdr_session rex_server
  REMOTE_ENDPOINT_ERROR=
  REMOTE_ENDPOINT_META=$(meta_path "$id")
  if ! fm_backend_validate_task_endpoint "$REMOTE_ENDPOINT_META" "$id" 2>/dev/null; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint metadata is invalid; refusing access until it is explicitly migrated"
    return 1
  fi
  REMOTE_ENDPOINT_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  REMOTE_ENDPOINT_TARGET=$FM_BACKEND_VALIDATED_TARGET
  case "$REMOTE_ENDPOINT_BACKEND" in
    herdr)
      if ! remote_herdr_session_resolve; then
        REMOTE_ENDPOINT_ERROR=$(remote_herdr_session_error)
        return 1
      fi
      herdr_session=$(fm_backend_meta_exact_value "$REMOTE_ENDPOINT_META" herdr_session 2>/dev/null || true)
      if [ "$herdr_session" != "$REMOTE_HERDR_SESSION" ]; then
        REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded in Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
        return 1
      fi
      case "$REMOTE_ENDPOINT_TARGET" in
        "$REMOTE_HERDR_SESSION":?*) ;;
        *)
          REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint target '$REMOTE_ENDPOINT_TARGET' is outside Herdr session '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
          return 1
          ;;
      esac
      ;;
    rex)
      # The validator above already binds rex_session_id/rex_window_id/
      # rex_block_id and the <session-uuid>:<block-uuid> target. The remote
      # contract adds the locality gate: the recorded server must be a unix://
      # endpoint on this host, because every endpoint operation here resolves
      # against that host-local socket.
      rex_server=$(fm_backend_meta_exact_value "$REMOTE_ENDPOINT_META" rex_server 2>/dev/null || true)
      case "$rex_server" in
        unix://*) ;;
        *)
          REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded on Rex server '${rex_server:-missing}', which is not a local unix:// endpoint; refusing access until it is explicitly migrated"
          return 1
          ;;
      esac
      ;;
    *)
      REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND'; a remote secondmate runs only on herdr or rex; refusing access until it is explicitly migrated"
      return 1
      ;;
  esac
}

# Refuse to start an agent while this home's session lock names a live process:
# that process is an agent already running here (a relaunch's own live agent is
# handled by the caller before this runs), and a second one beside it would
# fight it for the home. bin/fm-session-lock-lib.sh owns "live"; an unreadable
# lock refuses too, because a launch cannot prove nothing runs.
refuse_if_live_holder() { # <id> <verb>
  local id=$1 verb=$2 pid session=
  fm_session_lock_inspect "$TARGET_HOME/state"
  pid=$FM_LOCK_INSPECT_PID
  case "$FM_LOCK_INSPECT_STATE" in
    held) ;;
    unreadable) die "$verb refused: $TARGET_HOME/state/.lock cannot be read, so a running agent cannot be ruled out" ;;
    stale|free) return 0 ;;
    *) fm_session_lock_pid_blocks_reclaim "$pid" || return 0 ;;
  esac
  [ ! -f "$TARGET_HOME/state/.lock-session" ] || IFS= read -r session < "$TARGET_HOME/state/.lock-session" || true
  die "$verb refused: $TARGET_HOME/state/.lock names live process $pid${session:+ (agent session $session)}, so an agent is already running in this home and a second one would fight it. Bind the route to it with: fm-remote-secondmate-control.sh adopt $id <agent_session_id> (from the parent: bin/fm-remote-secondmate-adopt.sh $id <agent_session_id>)"
}

remote_endpoint_require() {
  remote_endpoint_load "$1" || die "$REMOTE_ENDPOINT_ERROR"
}

# A rex endpoint is pinned to the server endpoint its launch recorded: reads
# through a different ambient resolution (a re-pointed personal socket, or a
# second server on this host) could claim a live block missing, so the shared
# absence recheck proves server identity before its verdict counts. unproven
# reads as unreadable, never missing.
remote_agent_state() { # <backend> <target> <meta>
  local backend=$1 target=$2 meta=$3 rex_server verdict
  if [ "$backend" != rex ]; then
    fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable\n'
    return 0
  fi
  rex_server=$(fm_backend_meta_exact_value "$meta" rex_server 2>/dev/null || true)
  if ! fm_backend_source rex >/dev/null 2>&1; then
    printf 'unreadable\n'
    return 0
  fi
  verdict=$(fm_backend_rex_endpoint_absence_recheck "$target" "$rex_server" 2>/dev/null || printf 'unproven')
  case "$verdict" in
    alive|dead|missing) printf '%s\n' "$verdict" ;;
    *) printf 'unreadable\n' ;;
  esac
}

state_value() { # <id>; prints recovery-grade state
  local id=$1 meta
  meta=$(meta_path "$id")
  [ -f "$meta" ] && [ ! -L "$meta" ] || { printf 'missing\n'; return 0; }
  if ! remote_endpoint_load "$id"; then
    printf 'error: %s\n' "$REMOTE_ENDPOINT_ERROR" >&2
    printf 'unverified\n'
    return 0
  fi
  remote_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$REMOTE_ENDPOINT_META"
}

print_route() { # <id>
  local id=$1 harness model effort traceparent rex_session_id rex_server
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  model=$(fm_meta_get "$REMOTE_ENDPOINT_META" model)
  effort=$(fm_meta_get "$REMOTE_ENDPOINT_META" effort)
  traceparent=$(fm_meta_get "$REMOTE_ENDPOINT_META" traceparent)
  printf 'schema=fm-remote-secondmate-control.v1\n'
  printf 'backend=%s\n' "$REMOTE_ENDPOINT_BACKEND"
  printf 'target=%s\n' "$REMOTE_ENDPOINT_TARGET"
  case "$REMOTE_ENDPOINT_BACKEND" in
    herdr)
      printf 'herdr_session=%s\n' "$REMOTE_HERDR_SESSION"
      [ "${FM_REMOTE_HERDR_SELECTED:-0}" != 1 ] || printf 'herdr_session_source=selected\n'
      ;;
    rex)
      rex_session_id=$(fm_meta_get "$REMOTE_ENDPOINT_META" rex_session_id)
      rex_server=$(fm_meta_get "$REMOTE_ENDPOINT_META" rex_server)
      printf 'rex_session_id=%s\n' "$rex_session_id"
      printf 'rex_server=%s\n' "$rex_server"
      ;;
  esac
  printf 'harness=%s\n' "$harness"
  printf 'model=%s\n' "$model"
  printf 'effort=%s\n' "$effort"
  [ -z "$traceparent" ] || printf 'traceparent=%s\n' "$traceparent"
}

cmd_route() {
  local id=$1 meta
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    die "remote secondmate has no endpoint metadata"
  fi
  print_route "$id"
}

cmd_launch() {
  local id=$1 harness=$2 model=$3 effort=$4 selected_backend=$5 traceparent=${6:-}
  local current meta out
  local -a launch_env

  validate_id "$id"
  validate_home "$id"
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|omp) ;;
    *) die "unverified remote secondmate harness: $harness" ;;
  esac
  case "$effort" in -|low|medium|high|xhigh|max|ultra) ;; *) die "invalid remote secondmate effort: $effort" ;; esac
  if [ "$effort" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
  fi
  # The selected backend's session-provider server must survive every SSH
  # disconnection a remote route depends on: the herdr server belongs to the
  # GUI login session, and a persistent `rex server start` server is a
  # detached daemon no SSH session owns. bin/fm-remote-doctor.sh is the
  # readiness owner for whichever backend the parent selected.
  case "$selected_backend" in herdr|rex) ;; *) die "a remote secondmate runs only on the herdr or rex backend, not '$selected_backend'" ;; esac
  mkdir -p "$CONTROL_STATE" "$CONTROL_DATA"
  meta=$(meta_path "$id")
  if [ -f "$meta" ]; then
    # A recorded endpoint is refused against the backend this launch asked
    # for, not against the whole remote set: 'expected <selected>' names the
    # request exactly as the old herdr-only message did. Other load failures
    # (shape, herdr session, rex server locality) keep their own reason.
    if remote_endpoint_load "$id"; then
      [ "$REMOTE_ENDPOINT_BACKEND" = "$selected_backend" ] \
        || die "remote secondmate $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND', expected '$selected_backend'; refusing access until it is explicitly migrated"
    elif [ -n "$REMOTE_ENDPOINT_BACKEND" ] && [ "$REMOTE_ENDPOINT_BACKEND" != "$selected_backend" ]; then
      die "remote secondmate $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND', expected '$selected_backend'; refusing access until it is explicitly migrated"
    else
      die "$REMOTE_ENDPOINT_ERROR"
    fi
    current=$(remote_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$REMOTE_ENDPOINT_META")
    case "$current" in
      alive)
        print_route "$id"
        return 0
        ;;
      dead)
        refuse_if_live_holder "$id" launch
        fm_backend_kill "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null \
          || die "could not remove the confirmed agent-less endpoint"
        ;;
      missing) refuse_if_live_holder "$id" launch ;;
      *) die "remote endpoint state is $current; refusing duplicate launch" ;;
    esac
  else
    refuse_if_live_holder "$id" launch
  fi
  # The parent owns both convergence legs before it asks for this launch: it
  # already fast-forwarded this home to ITS primary commit and pushed inherited
  # local material, so this spawn must not redo either against this host's own
  # Firstmate copy, which would target the wrong checkout.
  ARGS=("$id" "$TARGET_HOME" --secondmate --harness "$harness" --backend "$selected_backend")
  [ "$model" = - ] || ARGS+=(--model "$model")
  [ "$effort" = - ] || ARGS+=(--effort "$effort")
  [ -z "$traceparent" ] || ARGS+=(--traceparent "$traceparent")
  launch_env=(FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT"
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA"
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1
    FM_SKIP_SECONDMATE_SYNC=1)
  if [ "$selected_backend" = herdr ]; then
    remote_herdr_session_resolve || die "$(remote_herdr_session_error)"
    launch_env=("HERDR_SESSION=$REMOTE_HERDR_SESSION" "${launch_env[@]}")
  fi
  if ! out=$(env "${launch_env[@]}" "$SCRIPT_DIR/fm-spawn.sh" "${ARGS[@]}" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die "remote host-local secondmate launch failed"
  fi
  [ -f "$meta" ] || die "remote launch returned without endpoint metadata"
  # remote_endpoint_load's per-backend record checks are the post-spawn
  # verification: this root's Herdr session plus target, or rex's id trio and a
  # local unix:// server endpoint.
  remote_endpoint_require "$id"
  print_route "$id"
}

# Restart the second-mate agent this host runs, by executing the ORDINARY local
# control plane here. From this host's point of view the mate is a plain local
# secondmate: its endpoint record under the private parent-route state directory
# was written by a host-local fm-spawn and carries no remote_host= field, so
# bin/fm-control.sh's remote refusal never fires, and every checkpoint, journal,
# rollback, and postcondition that plane owns applies unchanged. This verb is the
# transport hop, not a second implementation.
#
# harness/model/effort come from the PARENT and are passed explicitly, because
# config/secondmate-harness is deliberately not inherited into a secondmate home:
# the copy on this host is a different home's file, so letting the control plane
# re-resolve it here would silently drift the mate onto another runtime. `default`
# explicitly clears an absent parent pin; `-` remains its compatibility spelling.
cmd_relaunch() {
  local id=$1 harness=$2 model=$3 effort=$4
  local -a control_args relaunch_env

  validate_id "$id"
  validate_home "$id"
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|omp) ;;
    *) die "unverified remote secondmate harness: $harness" ;;
  esac
  case "$effort" in -|default|low|medium|high|xhigh|max|ultra) ;; *) die "invalid remote secondmate effort: $effort" ;; esac
  case "$model" in *[[:space:]]*) die "invalid remote secondmate model: $model" ;; esac
  if [ "$effort" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
  fi
  remote_endpoint_require "$id"
  # A live endpoint is the agent this relaunch replaces in place; any other
  # live holder of the home's lock is a different agent, so refuse.
  [ "$(remote_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$REMOTE_ENDPOINT_META")" = alive ] \
    || refuse_if_live_holder "$id" relaunch
  [ "$model" != - ] || model=default
  [ "$effort" != - ] || effort=default
  control_args=("$id" relaunch --harness "$harness" --model "$model" --effort "$effort")
  # The same launch-boundary facts cmd_launch establishes: the endpoint lives
  # in its backend's dedicated session placement, and the parent already owns
  # both convergence legs, so the host-local spawn must not re-sync or
  # re-inherit against this host's own Firstmate copy.
  relaunch_env=(FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT"
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA"
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1
    FM_SKIP_SECONDMATE_SYNC=1)
  [ "$REMOTE_ENDPOINT_BACKEND" != herdr ] || relaunch_env=("HERDR_SESSION=$REMOTE_HERDR_SESSION" "${relaunch_env[@]}")
  env "${relaunch_env[@]}" "$SCRIPT_DIR/fm-control.sh" "${control_args[@]}"
  # A parent tracking this route needs the identity the relaunch actually
  # produced, not the one it asked for, so it can republish its own record the
  # same way cmd_launch's caller already does. Reading it back from the
  # endpoint's own republished metadata - rather than trusting these argv
  # values - is what makes that record correct even when relaunch resolved
  # "default" against a configured pin this call never saw.
  print_route "$id"
}

# True when <pid> is the pane's shell, one of its foreground processes, or a
# descendant of its shell, read from Herdr's own process-info plus the process
# table (the same two sources bin/backends/herdr.sh's pane proofs use).
adopt_pid_in_pane() { # <session> <pane> <pid>
  local session=$1 pane=$2 pid=$3 info shell_pid fg ps_bin rows
  info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg pane "$pane" \
    '.result.type == "pane_process_info" and .result.process_info.pane_id == $pane' >/dev/null 2>&1 || return 1
  shell_pid=$(printf '%s' "$info" | jq -er '.result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || return 1
  [ "$pid" != "$shell_pid" ] || return 0
  fg=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[]?.pid | select(type == "number") | floor' 2>/dev/null) || fg=
  case " $(printf '%s' "$fg" | tr '\n' ' ') " in *" $pid "*) return 0 ;; esac
  ps_bin=${FM_HERDR_PS_BIN:-ps}
  rows=$(LC_ALL=C "$ps_bin" -axo pid=,ppid= 2>/dev/null) || return 1
  printf '%s\n' "$rows" | awk -v want="$pid" -v root="$shell_pid" '
    { ppid[$1] = $2 }
    END {
      p = want
      for (i = 0; i < 64 && p != "" && p > 1; i++) {
        if (p == root) exit 0
        p = ppid[p]
      }
      exit 1
    }'
}

# The working directory of a live process, resolved to a physical path.
adopt_pid_cwd() { # <pid>
  local pid=$1 dir
  if [ -d "/proc/$pid" ]; then
    dir=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 1
  elif command -v lsof >/dev/null 2>&1; then
    dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1) || return 1
  else
    return 1
  fi
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  (cd -- "$dir" && pwd -P)
}

adopt_agent_label_matches() { # <label> <harness>
  case "$1" in
    "$2") return 0 ;;
    pi) [ "$2" = pi-signed ] ;;
    *) return 1 ;;
  esac
}

cmd_adopt() {
  local id=$1 sid=$2 meta session pane list out agent_label harness found=0 candidate
  local pid lock_session holder_cwd home_phys info workspace tab old_state lock tmp line recorded_target
  validate_id "$id"
  validate_home "$id"
  case "$sid" in ''|*[!A-Za-z0-9._-]*) die "invalid agent session id" ;; esac
  meta=$(meta_path "$id")
  fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null \
    || die "remote secondmate $id has no valid endpoint record to rebind; adopt only rebinds an existing route"
  [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || die "adopt supports only a Herdr endpoint record, not '$FM_BACKEND_VALIDATED_BACKEND'"
  recorded_target=$FM_BACKEND_VALIDATED_TARGET
  harness=$(fm_meta_get "$meta" harness)
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || die "endpoint record for $id is not a secondmate record"
  remote_herdr_session_resolve || die "$(remote_herdr_session_error)"
  session=$REMOTE_HERDR_SESSION
  fm_backend_source herdr >/dev/null 2>&1 || die "the herdr backend adapter cannot be loaded"
  command -v jq >/dev/null 2>&1 || die "jq is required to read Herdr's pane records"
  [ "$(fm_backend_herdr_server_running_state "$session")" = running ] \
    || die "the Herdr server for session '$session' is not running; adopt never starts one"
  old_state=$(fm_backend_agent_state herdr "$recorded_target" 2>/dev/null || printf 'unreadable\n')
  # The pane: exactly one pane in the selected session holds this agent session.
  list=$(fm_backend_herdr_cli "$session" pane list 2>/dev/null) || die "cannot list panes in Herdr session '$session'"
  pane=
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    out=$(fm_backend_herdr_cli "$session" agent get "$candidate" 2>/dev/null) || continue
    if [ "$(printf '%s' "$out" | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null)" = "$sid" ]; then
      found=$((found + 1))
      pane=$candidate
      agent_label=$(printf '%s' "$out" | jq -r '.result.agent.agent // empty' 2>/dev/null)
    fi
  done < <(printf '%s' "$list" | jq -r '.result.panes[]?.pane_id // empty' 2>/dev/null)
  [ "$found" -ge 1 ] || die "no pane in Herdr session '$session' holds agent session $sid"
  [ "$found" -eq 1 ] || die "$found panes in Herdr session '$session' hold agent session $sid; refusing an ambiguous bind"
  adopt_agent_label_matches "$agent_label" "$harness" \
    || die "the pane's agent is '${agent_label:-unknown}', but the record for $id says harness '$harness'"
  # The home's lock must name a live harness process inside that pane, and its
  # session sidecar must carry the same agent session id.
  fm_session_lock_inspect "$TARGET_HOME/state"
  [ "$FM_LOCK_INSPECT_STATE" = held ] \
    || die "$TARGET_HOME/state/.lock does not name a live harness process (lock is $FM_LOCK_INSPECT_STATE); nothing to adopt"
  pid=$FM_LOCK_INSPECT_PID
  lock="$TARGET_HOME/state/.lock-session"
  [ -f "$lock" ] && [ ! -L "$lock" ] || die "$lock is missing, so the lock holder's agent session cannot be proven"
  IFS= read -r lock_session < "$lock" || true
  [ "$lock_session" = "$sid" ] \
    || die "$lock names agent session '${lock_session:-empty}', not $sid"
  adopt_pid_in_pane "$session" "$pane" "$pid" \
    || die "lock holder pid $pid is not inside pane $session:$pane"
  holder_cwd=$(adopt_pid_cwd "$pid") || die "cannot read the working directory of lock holder pid $pid"
  home_phys=$(cd -- "$TARGET_HOME" && pwd -P)
  [ "$holder_cwd" = "$home_phys" ] \
    || die "lock holder pid $pid runs in $holder_cwd, not this home $home_phys"
  # A live recorded endpoint is either this same pane, already adopted (a repeat
  # converges on the current route), or another agent: two agents is not a rebind.
  if [ "$old_state" = alive ]; then
    [ "$recorded_target" = "$session:$pane" ] \
      || die "the recorded endpoint $recorded_target is still alive; adopt rebinds only a dead or missing endpoint"
    print_route "$id"
    return 0
  fi
  info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || die "cannot read pane $pane"
  workspace=$(printf '%s' "$info" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  tab=$(printf '%s' "$info" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  [ -n "$workspace" ] && [ -n "$tab" ] || die "pane $pane reports no workspace or tab"
  if ! fm_backend_endpoint_atom_valid "$workspace" || ! fm_backend_endpoint_atom_valid "${tab//:/_}" \
    || ! fm_backend_endpoint_atom_valid "${pane//:/_}"; then
    die "pane $pane reports ids that are not valid endpoint ids"
  fi
  # Rewrite only the endpoint fields, in place and in order. The old endpoint's
  # process identity (proc_*) describes a process that is gone, so it goes too.
  local meta_lock
  meta_lock=$(fm_meta_lock_path "$meta") || die "remote secondmate metadata lock path is invalid"
  fm_task_inbox_lock_acquire "$meta_lock" \
    || die "remote secondmate endpoint metadata could not be locked"
  tmp=$(mktemp "$CONTROL_STATE/.fm-adopt-meta.XXXXXX") || { fm_lock_release "$meta_lock"; die "cannot stage the updated record"; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      window=*) printf 'window=%s:%s\n' "$session" "$pane" ;;
      herdr_session=*) printf 'herdr_session=%s\n' "$session" ;;
      herdr_workspace_id=*) printf 'herdr_workspace_id=%s\n' "$workspace" ;;
      herdr_tab_id=*) printf 'herdr_tab_id=%s\n' "$tab" ;;
      herdr_pane_id=*) printf 'herdr_pane_id=%s\n' "$pane" ;;
      proc_root=*|proc_root_id=*|proc_family=*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$meta" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$meta"
  fm_lock_release "$meta_lock"
  remote_endpoint_require "$id"
  print_route "$id"
}

cmd_send_body() {
  local id=$1 message=$2 delivery_mode=${3:-} rec ring_rc=0 meta meta_lock
  validate_id "$id"
  [ -z "$delivery_mode" ] || [ "$delivery_mode" = fire-and-forget ] || die "invalid send delivery mode"
  validate_home "$id"
  meta=$(meta_path "$id")
  meta_lock=$(fm_meta_lock_path "$meta") || die "remote secondmate metadata lock path is invalid"
  fm_task_inbox_lock_acquire "$meta_lock" \
    || die "remote secondmate endpoint metadata could not be locked for final delivery validation"
  if ! remote_endpoint_load "$id"; then
    fm_lock_release "$meta_lock"
    die "$REMOTE_ENDPOINT_ERROR"
  fi
  # A remote steer is delivered by durable record, never by submitting its payload
  # directly: write it into this secondmate's host-local steering inbox, then ring
  # the constant self-describing doorbell through the recorded backend endpoint,
  # best-effort (bin/fm-task-inbox-lib.sh owns the record and doorbell). The
  # write is idempotent - re-running the same request after an ambiguous
  # transport failure lands on the existing record instead of a duplicate - so
  # the parent may safely repeat this leg. Exit 0 once the record durably
  # exists; no ring outcome changes it, because the parent transport owns any
  # retry or reply-tracking policy from here.
  if ! rec=$(fm_task_inbox_write_idempotent "$CONTROL_STATE" "$id" "$message" "$delivery_mode"); then
    fm_lock_release "$meta_lock"
    die "steering-inbox record could not be written under $CONTROL_STATE/$id.inbox"
  fi
  fm_lock_release "$meta_lock"
  case "$rec" in
    */handled/*)
      # The dedup landed on a record the worker already acknowledged: the
      # steer was delivered and acted on, so there is nothing to announce.
      printf 'notice: this steer was already delivered and acknowledged at %s; nothing re-rung\n' "$rec" >&2
      return 0
      ;;
  esac
  fm_task_inbox_ring "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$rec" "fm-$id" || ring_rc=$?
  # The ring names its step and a sanitized reason (never message text) in
  # FM_TASK_INBOX_RING_STEP / _REASON; print them so a failure is diagnosable.
  ring_why=
  [ -z "${FM_TASK_INBOX_RING_STEP:-}" ] || ring_why=" [step=$FM_TASK_INBOX_RING_STEP: ${FM_TASK_INBOX_RING_REASON:-no reason recorded}]"
  case "$ring_rc" in
    1) printf 'notice: doorbell deferred%s; the steer is durably recorded at %s and the watcher will re-ring it\n' "$ring_why" "$rec" >&2 ;;
    2) printf 'notice: doorbell did not reach %s%s; the steer is durably recorded at %s\n' "$REMOTE_ENDPOINT_TARGET" "$ring_why" "$rec" >&2 ;;
    3) printf 'notice: doorbell not typed because the agent in %s has exited; the steer is durably recorded at %s for recovery\n' "$REMOTE_ENDPOINT_TARGET" "$rec" >&2 ;;
    4) printf 'notice: doorbell typed but not confirmed delivered%s; the steer is durably recorded at %s\n' "$ring_why" "$rec" >&2 ;;
  esac
}

cmd_send() {
  local id=$1 message=$2 delivery_mode=${3:-}
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
  cmd_send_body "$id" "$message" "$delivery_mode"
}

cmd_send_stdin() {
  local id=$1 delivery_mode=${2:-} message
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
  IFS= read -r -d '' message < /dev/stdin || :
  [ -n "${message//[[:space:]]/}" ] || die "remote steer message must be nonempty"
  cmd_send_body "$id" "$message" "$delivery_mode"
}

cmd_key() {
  local id=$1 key=$2
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" \
    "$SCRIPT_DIR/fm-send.sh" "fm-$id" --key "$key"
}

cmd_capture() {
  local id=$1 lines=${2:-20}
  validate_id "$id"
  validate_home "$id"
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le 100 ] || die "capture line count exceeds 100"
  remote_endpoint_require "$id"
  fm_backend_capture "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$lines" "fm-$id" | head -c 65536
}

cmd_observe() {
  local id=$1 harness
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  fm_pending_reply_backend_observation "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "fm-$id" "$harness"
  printf '\n'
}

# Make <commit> readable in this home's own object store without moving any other
# checkout. Ordered by cost: already present, then this host's Firstmate copy (a
# read-only fetch of that one commit, which never advances that copy's HEAD), then
# the home's own origin for that one commit. No pack transport beyond those two.
import_home_commit() { # <home> <commit>
  local home=$1 commit=$2
  if git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then return 0; fi
  if git -C "$home" fetch --quiet --no-tags -- "$FM_ROOT" "$commit" 2>/dev/null \
    && git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  if git -C "$home" remote get-url origin >/dev/null 2>&1 \
    && fm_git_retry git -C "$home" fetch --quiet --no-tags -- origin "$commit" 2>/dev/null \
    && git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  return 1
}

cmd_sync() {
  local id=$1 commit report out
  validate_id "$id"
  validate_home "$id"
  if [ "$#" -ge 2 ]; then
    commit=$2
    case "$commit" in *[!0-9a-f]*) die "sync target must be a full 40-character commit id" ;; esac
    [ "${#commit}" -eq 40 ] || die "sync target must be a full 40-character commit id"
  else
    commit=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null) || die "remote code root HEAD is unreadable"
  fi
  import_home_commit "$TARGET_HOME" "$commit" \
    || die "remote home could not import $commit from this host's Firstmate copy or the home's origin; run /updatefirstmate to refresh this host's copy, or push that commit first"
  # ff_target publishes its verdict in FF_STATUS, so it must run in THIS shell.
  report=$(mktemp "${TMPDIR:-/tmp}/fm-remote-sync.XXXXXX") || die "cannot stage the sync report"
  ff_target "$TARGET_HOME" "remote home" "$commit" yes yes "$id" "$TARGET_HOME/state" > "$report" 2>&1
  out=$(cat "$report")
  rm -f "$report"
  case "$FF_STATUS" in
    # instr= names the watched instruction paths this advance changed, with no
    # spaces so the whole result stays one parseable line. The parent needs it to
    # decide whether the running agent must reload; an older parent ignores the
    # suffix, and an older HOST omits it, which a parent must read as unknown
    # rather than as "nothing changed".
    updated) printf 'synced: %s instr=%s\n' "$commit" "$(printf '%s' "$FF_INSTR" | tr -d ' ')" ;;
    current) printf 'current: %s\n' "$commit" ;;
    *) die "remote secondmate home sync skipped: ${out#remote home: skipped: }" ;;
  esac
}

cmd_update() {
  local id=$1 update_out root_status
  validate_id "$id"
  validate_home "$id"
  if ! update_out=$(FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-update.sh" 2>&1); then
    [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
    die "remote code root update failed"
  fi
  root_status=$(printf '%s\n' "$update_out" | grep '^firstmate:' | tail -1)
  case "$root_status" in
    'firstmate: updated '*|'firstmate: already current'*) ;;
    *)
      [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
      die "remote code root did not complete a safe origin update"
      ;;
  esac
  cmd_sync "$id"
}

cmd_retire() {
  local id=$1 force=${2:-} recorded_server current_server rc=0
  validate_id "$id"
  validate_home "$id" yes || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'already-retired: %s\n' "$id"
    return 0
  fi
  [ -z "$force" ] || [ "$force" = --force ] || usage
  remote_endpoint_require "$id"
  if [ "$REMOTE_ENDPOINT_BACKEND" = rex ]; then
    recorded_server=$(fm_backend_meta_exact_value "$REMOTE_ENDPOINT_META" rex_server)
    if ! fm_backend_source rex || ! current_server=$(fm_backend_rex_server_endpoint) \
      || [ "$current_server" != "$recorded_server" ]; then
      die "cannot prove access to the recorded Rex server '$recorded_server'; restore access to the recorded Rex server on this account, then retry retirement; refusing block close and home deletion"
    fi
  fi
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" "$SCRIPT_DIR/fm-guard.sh" || true
  if [ -n "$force" ]; then
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id" --force
  else
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id"
  fi
}

case "${1:-}" in
  launch) shift; [ "$#" -ge 5 ] && [ "$#" -le 6 ] || usage; cmd_launch "$@" ;;
  relaunch) shift; [ "$#" -eq 4 ] || usage; cmd_relaunch "$@" ;;
  state) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; validate_home "$1"; state_value "$1" ;;
  route) shift; [ "$#" -eq 1 ] || usage; cmd_route "$1" ;;
  send) shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_send "$@" ;;
  send-stdin) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_send_stdin "$@" ;;
  key) shift; [ "$#" -eq 2 ] || usage; cmd_key "$@" ;;
  capture) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_capture "$@" ;;
  observe) shift; [ "$#" -eq 1 ] || usage; cmd_observe "$@" ;;
  sync) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_sync "$@" ;;
  update) shift; [ "$#" -eq 1 ] || usage; cmd_update "$@" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  adopt) shift; [ "$#" -eq 2 ] || usage; cmd_adopt "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
