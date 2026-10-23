#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Default usage prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --branch-prefix instead prints one value: the project's registered ship-branch
# prefix, "fm/" when the project registers none, is unregistered, or the registry
# is absent, so every existing installation keeps its current "fm/<task-id>"
# branch names unchanged.
# With --forge it prints one word instead: the project's registered forge,
# none|gerrit|forgejo|external. The forge is asked for explicitly, so the
# default output stays the same two words for every project, bound or not.
# With --merger it prints the project's registered merger home id, or nothing
# when the project registers none, is unregistered, or the registry is absent.
# With --landing-lag it prints the project's registered landing-lag limit in
# hours, or nothing under those same conditions.
# With --admission it prints the project's registered admission config name the
# same way.
# With --ready-evidence it prints the project's registered ready-evidence name the
# same way, or nothing.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode,
# yolo, and ship-branch prefix are resolved by firstmate at intake and passed
# explicitly to bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md
# section 7; bin/fm-brief.sh's own header owns the --branch-prefix flag it accepts).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh and bin/fm-remote-home-seed.sh (refuse local-only seeding,
# run no-mistakes init), bin/fm-spawn.sh's advisory registry-deviation notice,
# and --forge for bin/fm-spawn.sh's forge agreement and yolo refusal and for
# bin/fm-promote.sh, which takes the forge binding from here because it is a
# project fact rather than a task choice, --merger and --admission for
# bin/fm-pr-merge.sh's merger-home and admission refusals, --landing-lag for
# bin/fm-spawn.sh's landing-lag admission, and --ready-evidence for
# bin/fm-dod-lib.sh's ready gate.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                                 -> no-mistakes off fm/  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                        -> <mode> off fm/
#   - <name> [<mode> +yolo] - <desc> (added <date>)                  -> <mode> on fm/
#   - <name> [<mode> +yolo branch=<prefix>] - <desc> (added <date>)  -> <mode> <yolo> <prefix>
#   - <name> [<mode> forge=gerrit] - <desc> (added <date>)           -> <mode> off, --forge gerrit
#   - <name> [<mode> forge=forgejo] - <desc> (added <date>)          -> <mode> <yolo>, --forge forgejo
#   - <name> [direct-PR forge=external] - <desc> (added <date>)      -> direct-PR off, --forge external
#   - <name> [<mode> +yolo merger=<home>] - <desc> (added <date>)    -> <mode> on, --merger <home>
#   - <name> [<mode> landing-lag=<hours>] - <desc> (added <date>)    -> <mode> off, --landing-lag <hours>
#   - <name> [<mode> admission=<config>] - <desc> (added <date>)     -> <mode> off, --admission <config>
#   - <name> [<mode> ready-evidence=<n>] - <desc> (added <date>)     -> <mode> off, --ready-evidence <n>
#   <name> may contain spaces; it ends at the literal " [" or " - " that follows it.
#   Bracket tokens are order-independent: +yolo, branch=<prefix>, forge=<value>,
#   merger=<home>, landing-lag=<hours>, admission=<config>, and ready-evidence=<n>
#   are recognized by
#   their own shape wherever they appear, and whichever token is
#   left over is the mode. <prefix> must not contain a space; an empty override
#   ("branch=") resolves to "" for a bare "<task-id>" ship branch instead of the
#   legacy "fm/<task-id>".
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
# branch=<prefix> (orthogonal) = overrides the "fm/" ship-branch prefix so a
#   project's branch and PR do not read as firstmate-authored, e.g. for a
#   third-party repo that does not use this tooling. Query it with
#   --branch-prefix; it never appears in the default "<mode> <yolo>" output, so
#   existing mechanical callers are unaffected by its presence.
# forge (orthogonal, and orthogonal to yolo too) = which forge the project's
#   remote actually is, never inferred from mode, remote name, host, or protocol.
#   `none` means a forge whose pull requests and checks no-mistakes already
#   drives, `gerrit` means a Gerrit server: no pull requests, so the worker
#   publishes a change with gerrit-axi instead, and `forgejo` means a Forgejo or
#   Gitea server, whose pull requests the worker handles with tea rather than
#   gh-axi, and `external` means the project's reviews are created by a review
#   tool that uploads its own snapshot of the worker's local commits: the
#   worker never needs to push a branch, and must never push a task branch to
#   the project's shared origin. Firstmate cannot observe, approve, or merge
#   such a review, so that rail always escalates (bin/fm-dod-lib.sh owns what
#   each changes for a worker in each publishing mode;
#   docs/forgejo-tea-integration.md holds the tea evidence and
#   docs/external-review-forge.md the external design).
#   The binding is EXPLICIT because a provider family must never be guessed;
#   bin/fm-forge-detect.sh proposes gerrit from a protocol fact at project-add
#   intake, forgejo has no such fact and is proposed from the captain's own
#   account of the host, external is never detected or proposed because no
#   protocol fact identifies a snapshot-uploading review tool, and the captain's
#   confirmation is what this record holds.
#   A forge describes what a mode publishes, so it composes with no-mistakes and
#   direct-PR and is REFUSED on local-only, which publishes nothing: that mode
#   lands by fast-forwarding local main, which on a review-server project
#   advances it with content the server has never seen
#   (docs/gerrit-forge-integration.md section 3).
# merger=<home> (orthogonal) = the one firstmate home allowed to merge this
#   project's PRs, named by its secondmate id, or `main` for the primary home.
#   bin/fm-pr-merge.sh refuses a merge from any other home and owns how a home
#   knows its own id. A project with no merger token keeps every home's merge
#   authority exactly as before. Under --merger an empty or non-id value
#   (outside [A-Za-z0-9._-]) is refused with exit status 3, because reading it
#   as "no merger" would hand every home the merge the binding exists to stop;
#   the other output forms ignore the token.
# landing-lag=<hours> (orthogonal) = how many hours this project's oldest ready
#   PR may wait to land before bin/fm-spawn.sh defers a fresh ship
#   (bin/fm-project-capacity-lib.sh owns the admission). A project with no
#   landing-lag token is never deferred for lag. Under --landing-lag a value that
#   is not a positive integer of at most six digits is refused with exit status
#   3, because reading it as "no limit" would drop the captain's limit; the
#   other output forms ignore the token.
# admission=<config> (orthogonal) = the name of this home's
#   config/admission/<config> file, which names the project's diff classifier
#   and the classes whose PRs need the captain's recorded word before merging.
#   bin/fm-pr-merge.sh owns the file's format and the refusal. A project with
#   no admission token merges exactly as before. Under --admission an empty or
#   non-name value (outside [A-Za-z0-9._-], or a leading dot) is refused with
#   exit status 3, because reading it as "no admission" would merge the very
#   classes the binding exists to stop; the other output forms ignore the token.
# ready-evidence=<n> (orthogonal) = the project's ready-evidence command set,
#   the file config/ready-evidence/<n> in this home, which bin/fm-dod-lib.sh
#   runs before it accepts a ship done (that file owns how it runs). A project
#   with no token keeps today's done gate exactly. Under --ready-evidence an
#   empty or non-id value is refused with exit status 3 like merger=, because
#   reading it as "no evidence" would accept the done the binding exists to check.
#
# A registered `forge=gerrit` project reports yolo=off with an explicit stderr
# refusal, on the captain's decision of 2026-09-15: a Gerrit Code-Review+2 is a
# positive attributed claim that a named human approved, read by colleagues and
# by any audit, and firstmate must not manufacture one. A registered
# `forge=external` project reports yolo=off the same way, because firstmate can
# neither observe nor perform the review tool's approval or merge.
#
# --raw prints the registered mode annotation unmapped, so a caller that must
# tell a conditional policy apart from a flat mode sees "no-mistakes-prod-only"
# itself. Not combined with --branch-prefix, which has no conditional-policy leg.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" (or
# "fm/" under --branch-prefix) and warns to stderr, so a typo never silently
# drops the gate. Other annotation tokens are ignored, as they always were, keyed
# ones included: a `<key>=<value>` token whose key is not exactly `forge`,
# `branch`, `merger`, or `ready-evidence` resolves as it did before the forge existed, and in the mode slot it
# is read as an unknown mode. A key one or two edits from `forge` (such as
# `forg=` or `Forge=`) is still ignored, with one stderr warning naming the token
# and the forge=gerrit, forge=forgejo, and forge=external spellings. The one
# refusal is a malformed forge binding - a `forge=` token whose value is empty or outside the
# closed set - which is REFUSED in the default and --forge output forms: nothing
# on stdout, exit status 3, the token named. Resolving it to "no registered
# forge" would hand a Gerrit project the pull-request contract the binding
# exists to prevent.
# local-only with a forge is refused the same way. --branch-prefix does not make
# that check: it answers only the registered prefix, and a prefix is orthogonal
# to the forge binding, so it prints even when the forge token is malformed;
# every path that reads the forge binding (default, --forge, and spawn's
# forge-agreement check) still refuses.
# Usage: fm-project-mode.sh [--raw|--branch-prefix|--forge|--merger|--landing-lag|--admission|--ready-evidence] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
BRANCH_PREFIX_QUERY=0
WANT_FORGE=0
WANT_MERGER=0
WANT_LANDING_LAG=0
WANT_ADMISSION=0
WANT_EVIDENCE=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --branch-prefix) BRANCH_PREFIX_QUERY=1; shift ;;
  --forge) WANT_FORGE=1; shift ;;
  --merger) WANT_MERGER=1; shift ;;
  --landing-lag) WANT_LANDING_LAG=1; shift ;;
  --admission) WANT_ADMISSION=1; shift ;;
  --ready-evidence) WANT_EVIDENCE=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--branch-prefix|--forge|--merger|--landing-lag|--admission|--ready-evidence] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  [ "$WANT_MERGER" -eq 0 ] && [ "$WANT_LANDING_LAG" -eq 0 ] && [ "$WANT_ADMISSION" -eq 0 ] && [ "$WANT_EVIDENCE" -eq 0 ] || exit 0
  if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "fm/"
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none; else echo "no-mistakes off"; fi
  exit 0
fi

# awk emits one "near <token>" line per keyed token whose key is a near miss of
# `forge`, then
# "posture <mode> <yolo> <forge> <merger> <landing-lag> <admission> <evidence> <branch-prefix>" (branch-prefix is
# the raw prefix, defaulting to "fm/"; forge, merger, landing-lag, admission, and evidence are `none` or the whole
# `<key>=<value>` token, so an empty value survives the split), or nothing if the project is
# absent. Every other token beside the mode is ignored, exactly as before either
# annotation existed.
parsed=$(awk -v n="$NAME" '
  function dist(x, y,   i, j, lx, ly, d, c, v) {
    lx = length(x); ly = length(y);
    for (i=0; i<=lx; i++) d[i,0] = i;
    for (j=0; j<=ly; j++) d[0,j] = j;
    for (i=1; i<=lx; i++) for (j=1; j<=ly; j++) {
      c = (substr(x,i,1) == substr(y,j,1)) ? 0 : 1;
      v = d[i-1,j] + 1;
      if (d[i,j-1] + 1 < v) v = d[i,j-1] + 1;
      if (d[i-1,j-1] + c < v) v = d[i-1,j-1] + c;
      d[i,j] = v;
    }
    return d[lx,ly];
  }
  {
    # Exact whole-name match on the raw line text (never a regex, so a name
    # containing dots or brackets is compared literally): the line must start
    # with "- " n, and the text right after the name must be empty, or start
    # with " [" or " - ", so a name that is a leading prefix of a longer
    # registered name does not match that longer row.
    prefix = "- " n; plen = length(prefix);
    if (substr($0, 1, plen) != prefix) next
    after = substr($0, plen + 1);
    if (after != "" && substr(after, 1, 2) != " [" && substr(after, 1, 3) != " - ") next
    mode="no-mistakes"; yolo="off"; branch="fm/"; forge="none"; merger="none"; lag="none"; admission="none"; evidence="none";
    if (substr(after, 1, 2) == " [") {
      s="";
      nk = split(after, rest, " ");
      for (i=1; i<=nk; i++) { s = s (s==""?"":" ") rest[i]; if (rest[i] ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # Tokens are order-independent: +yolo, branch=<prefix>, and forge=<value>
      # are recognized by their own shape wherever they appear, keyed tokens
      # that are neither are ignored (with a near-miss warning for the forge
      # spelling), and the first token left over is the mode.
      mode_set = 0
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") { yolo="on"; continue }
        if (a[j] ~ /^branch=/) { branch = substr(a[j], 8); continue }
        if (a[j] ~ /^forge=/) { forge = a[j]; continue }
        if (a[j] ~ /^merger=/) { merger = a[j]; continue }
        if (a[j] ~ /^landing-lag=/) { lag = a[j]; continue }
        if (a[j] ~ /^admission=/) { admission = a[j]; continue }
        if (a[j] ~ /^ready-evidence=/) { evidence = a[j]; continue }
        if (a[j] ~ /^[^=]+=/) {
          key = substr(a[j], 1, index(a[j], "=") - 1);
          e = dist(key, "forge");
          if (e >= 1 && e <= 2) print "near", a[j];
          if (mode_set == 0) { mode = a[j]; mode_set = 1 }
          continue
        }
        if (a[j] != "" && mode_set == 0) { mode = a[j]; mode_set = 1 }
      }
    }
    # branch is printed LAST: an empty branch= override must survive as an
    # empty final field, which only holds when nothing follows it.
    print "posture", mode, yolo, forge, merger, lag, admission, evidence, branch; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  [ "$WANT_MERGER" -eq 0 ] && [ "$WANT_LANDING_LAG" -eq 0 ] && [ "$WANT_ADMISSION" -eq 0 ] && [ "$WANT_EVIDENCE" -eq 0 ] || exit 0
  if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "fm/"
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none; else echo "no-mistakes off"; fi
  exit 0
fi

posture=
while IFS=' ' read -r kind rest; do
  case "$kind" in
    near) echo "warn: ignoring \"$rest\" registered for $NAME in $REG; it is not a forge binding, and the forge binding is spelled forge=gerrit, forge=forgejo, or forge=external" >&2 ;;
    posture) posture=$rest ;;
  esac
done <<EOF
$parsed
EOF
while IFS=' ' read -r m y f r l a e b; do
  mode=$m; yolo=$y; rest_forge=$f; merger=$r; lag=$l; admission=$a; evidence=$e; branch=$b
done <<EOF
$posture
EOF
forge=${rest_forge:-none}
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; branch=fm/ ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
  echo "$branch"
  exit 0
fi
if [ "$WANT_MERGER" -eq 1 ]; then
  case "$merger" in
    none) ;;
    merger=*[!A-Za-z0-9._-]*|merger=)
      echo "refused: merger binding \"$merger\" registered for $NAME in $REG is not a home id; name the merging home's secondmate id, or main for the primary home, or drop the token" >&2
      exit 3 ;;
    *) echo "${merger#merger=}" ;;
  esac
  exit 0
fi
if [ "$WANT_LANDING_LAG" -eq 1 ]; then
  case "$lag" in
    none) ;;
    landing-lag=[1-9]*[!0-9]*|landing-lag=[!1-9]*|landing-lag=|landing-lag=???????*)
      echo "refused: landing-lag binding \"$lag\" registered for $NAME in $REG is not a whole number of hours; write landing-lag=<hours> with a positive integer of at most six digits, or drop the token" >&2
      exit 3 ;;
    *) echo "${lag#landing-lag=}" ;;
  esac
  exit 0
fi
if [ "$WANT_ADMISSION" -eq 1 ]; then
  case "$admission" in
    none) ;;
    admission=*[!A-Za-z0-9._-]*|admission=|admission=.*)
      echo "refused: admission binding \"$admission\" registered for $NAME in $REG is not a config name; name a file in config/admission/, or drop the token" >&2
      exit 3 ;;
    *) echo "${admission#admission=}" ;;
  esac
  exit 0
fi
if [ "$WANT_EVIDENCE" -eq 1 ]; then
  case "$evidence" in
    none) ;;
    ready-evidence=*[!A-Za-z0-9._-]*|ready-evidence=)
      echo "refused: ready-evidence binding \"$evidence\" registered for $NAME in $REG is not a file name; name a file under config/ready-evidence/, or drop the token" >&2
      exit 3 ;;
    *) echo "${evidence#ready-evidence=}" ;;
  esac
  exit 0
fi

case "$forge" in
  none|forge=gerrit|forge=forgejo|forge=external) forge=${forge#forge=} ;;
  forge=)
    echo "refused: empty forge binding \"forge=\" registered for $NAME in $REG; the accepted values are forge=gerrit, forge=forgejo, and forge=external, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
  *)
    echo "refused: unknown forge \"${forge#forge=}\" registered for $NAME in $REG; the accepted values are forge=gerrit, forge=forgejo, and forge=external, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
esac
if [ "$forge" != none ] && [ "$mode" = local-only ]; then
  echo "refused: $NAME is registered local-only with forge=$forge in $REG; local-only publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; register no-mistakes or direct-PR to publish through the forge, or drop the forge token to keep the project local" >&2
  exit 3
fi
if [ "$WANT_FORGE" -eq 1 ]; then
  echo "$forge"
  exit 0
fi
if [ "$forge" = gerrit ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=gerrit, so this reports yolo=off: a Gerrit Code-Review+2 is a positive attributed claim that a named human approved, and firstmate must not manufacture one (captain's decision 2026-09-15)" >&2
  yolo=off
fi
if [ "$forge" = external ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=external, so this reports yolo=off: firstmate can neither observe nor perform the review tool's approval or merge, so every review escalates" >&2
  yolo=off
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
