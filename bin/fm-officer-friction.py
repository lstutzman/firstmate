#!/usr/bin/env python3
"""fm-officer-friction.py - the friction officer's deterministic daily pass.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration.md "Officers" owns the registry schema.

Usage:
  fm-officer-friction.py scan --archive <dir> --date <YYYY-MM-DD>
  fm-officer-friction.py run --archive <dir|host:dir> --date <YYYY-MM-DD>
                             --out <lane-dir> [--home <dir>]... [--hosts a,b]
                             [--captains-log <https-url>] [--channel <mate-id>]...
                             [--days <n>] [--model none] [--now <epoch>]
                             [--bosun-hosts a,b] [--fm-home <dir>]
                             [--start-home <home>=<projects>[=<role>[=<mandate>]]]...
                             [--writes none|linear] [--team PC] [--max-creates <n>]
                             [--max-linear-calls <n>] [--rubric <file>] [--jev <jev.py>]

Friction is anything that slowed an agent down, above all a step it had to
wait for Lee to do. One day's friction events come from three sources:

  status logs  every needs-decision and blocked line opened that day (local
               time) in a --home's live state/<task>.status logs and its fleet
               ledger's task.status records, deduplicated, plus paused lines
               that name Lee. These are the lines firstmate turns into Captain's
               Log cards, so they are that input. The wait runs from the line's
               at= stamp to the first later resolved line with the same key; an
               unkeyed line is measured to the task's next line (marked
               next-line). A line still open has no wait. A key asked again
               before it is resolved is a re-ask, counted but not measured
               again; a re-asked chain whose lines hand Lee `ssh ... <host> '`
               for the home's own host is ssh-to-self. Any other line whose
               text names an environment cause (a session restored in the
               wrong directory) is a report with no wait. A line's text rules
               classify it first; a line they leave unclassified joins the group
               of its stated [cause=...] tag (policy, credential, sudo, tool,
               decision, physical, external), and each finding tallies its lines by stated
               cause, with untagged ones as unstated.
  archive     each claude-code session of the archive day: a <bash-input>
               record is a command Lee ran himself (ssh to the session's own
               host is flagged); an assistant text block asking Lee to run or
               do something is an ask, collapsed per session and command and
               measured to the next message Lee typed; a tool result whose
               line starts with a guard refusal, a sudo prompt, an ssh key
               refusal, a 1Password refusal, a not-signed-in CLI, or
               `command not found` is agent-side friction; a not-found name
               that is no installable tool (plausible_tool) is skipped. A worker session
               whose cwd is outside the worktree its task record names started
               in the wrong directory.
  captain's log with --captains-log, the cards fleet-app serves at GET
               <fleet-app>/api/captains-log (src/captains-log.ts), read with
               curl and never written: a card asked that day whose id is no
               status line's card id (fleet-app's cardId of its task and key)
               is a Lee step the status logs missed, measured to its answer.
               An unreachable endpoint is a coverage gap in the digest, and
               the pass continues on the other two sources.

Repeated asks are a fourth kind of event. Lee's typed messages in the last
--days days (default 7), from the archive's interactive and worker sessions
and never a worker's launch brief, which quotes him, are cut into sentences
(a long dictated run-on into clauses) that give an instruction (keep, make
sure, always, never, don't, should, must, ...). The instruction words
themselves and common dictated-speech words are not content words. Two instructions on different
days are the same instruction when they share at least three content words
and at least 70% of the shorter one's words, or when both ask for upkeep (one
concept for keep, update, current, date, fresh, maintain, look, check, review,
watch, track, monitor, stale, and their -ed and -ing forms) and share at least two other content words, so
"keep the captain's log up to date" and "make sure the captain's log keeper is
looking at all pages" match while "make sure the captain's log renders" does
not. Each instruction is dated by its own message time in the archive's
timezone, and a session listed on several days is read once. A group spanning
two or more days, one
of them the run's day, becomes a repeat-ask event whose evidence is each day's
scrubbed quote. The fix is to make the instruction automatic work (a scheduled
check, a hook, or a standing rule) so Lee stops giving it.

Bosun unsure items are a separate finding class, `bosun-unsure`, read only
with --bosun-hosts (the registry's `bosun-hosts` field). For each host the
officer reads the `unsure` list of ~/services/bosun-maintenance/last-result.json
over `ssh -o BatchMode=yes` (the list is in the file, not in its counts). Each
item carries a bucket: `rule-settles` (a rule could decide it once a fact is
known) or `unreadable` (a check failed at run time; the Bosun retries it the
next night, so the officer never answers it). An item with no bucket (a result
written before the split) is counted and not answered. The officer answers a
`rule-settles` item only from fleet rules section 6 and the captain-shared
clean-up rule, with no model: a branch item and a copy item whose branch is
unmerged and whose pull request the Bosun could not read are answered from the
branch's pull requests and `git merge-base --is-ancestor <sha> origin/HEAD`,
read live (read-only git and gh on the host):

  open pull request                       keep    (never while one uses it)
  pull request merged or closed at the
  tip (branch) or at HEAD (copy)          delete  (unmerged-branch rule, rule c)
  tip or HEAD an ancestor of origin/HEAD  delete  (content already on the
                                                   default branch)
  anything else                           keep    (unique unlanded work is
                                                   never deleted)

A copy item names a pooled Treehouse slot (`<pool>/<n>`) as often as a checkout.
The officer reads the checkout as the Bosun does (fleet-app src/bosun/cleanup.ts
checkoutOf): the copy itself when it has a `.git`, else its single child that
has one. The sha, status and pull requests come from that checkout, and the
answer still names the item as the Bosun listed it. A copy with no checkout,
several, or an unreadable folder is unsettled.

A copy that would be answered delete is first checked with a read-only
`GIT_OPTIONAL_LOCKS=0 git status --porcelain` on its host: any modified,
staged or untracked entry makes it keep (unique unlanded work), and a failed
read leaves it unsettled. Like the Bosun's own rule c check (fleet-app
src/bosun/cleanup.ts), it does not pass --ignored, so "uncommitted or
untracked" excludes git-ignored files.

A pull request, tip or HEAD that cannot be read is no answer, and so is an
origin/HEAD that cannot be read when no pull request decides the item. A
file or log item that is a session log or transcript (never a branch or a
copy, which is a worktree or task copy) is answered keep (fleet rules
section 6: always kept, because it is training data), never delete. Every other item (an old scratch file, a log folder, a copy whose
state the officer does not read, a branch or copy whose tip or HEAD is not a
full 40-character sha) is unsettled.
Answers go to <out>/bosun-answers.json, never into the velocity file, which
fleet-app pulls and would show them as velocity findings:

  {"schema_version": 1, "source": "friction-officer", "date": <run date>,
   "answers": [{"host", "result_date", "kind", "item", "sha",
                "verdict": "delete"|"keep", "rule", "fact"}, ...]}

sorted by host, kind and item, one entry per item. `sha` is the full commit
the answer was decided on (a branch's tip, a copy's HEAD, read live) and is
present on branch and copy answers only; a session-log keep has none. A
`delete` is the rule's permission only: the Bosun reads the file the next
night, must refuse an answer whose `sha` no longer matches the tip or HEAD it
finds, and must itself re-check live worktrees, open pull requests, unpushed
work, uncommitted or untracked work and remote ownership before it deletes
anything. The digest lists each unsettled item for the Quartermaster, never
for Lee, and an unreachable host is a coverage gap there, never a note in the
velocity file. The officer never deletes anything.

Re-running a day with unchanged inputs rewrites identical digest bytes (with writes:
linear, once its items exist: the Linear call count differs between a first and a
second run); the one environment input is this host's name, which counts as the home's own
host for ssh-to-self.

`scan` reads only the archive and prints the per-session facts as JSON, so
`run` can send it, with the triage pass it imports, to `python3 -I -` over
`ssh -o BatchMode=yes <host>`. `run` joins sessions to tasks exactly as the
triage officer does, reads the status logs, classifies each event's root
cause by the first matching rule in RULES, groups events by cause and
service or tool, and writes into --out:

  <date>.json                    every event and finding, each with its state, and
                                 the start_requests (no wall-clock stamps: its
                                 generated_at is the end of the digest's day, so
                                 a re-run with unchanged inputs rewrites
                                 identical bytes; source friction-officer);
  <date>.md                      the digest;
  <date>.velocity-findings.json  the fleet-app velocity findings file
                                 (FINDINGS_SCHEMA schema_version 1, source
                                 friction-officer) holding up to MAX_CARDS
                                 findings that carry a title and a fix, the
                                 card bar's ones first (never a product
                                 decision, which is Lee's to make), each with
                                 a stable id, its event count, and its state
                                 (see below), plus totals of every event and
                                 finding of the day. Its
                                 generated_at is --now, the one clock field,
                                 because the page treats a file older than a
                                 day as not posted.

It prints `DIGEST <date> <n-actionable> <date>.md` as its last stdout line;
n-actionable counts findings that clear the card bar (severity and confidence
of at least 3, as the page's aggregation requires). It fails, writing nothing,
while the archive day is missing or not yet harvested. It never posts the
velocity file anywhere: the fleet app pulls it from the lane.

Each finding states what Lee had to do, how often, how long agents waited,
the root cause, a proposed fix that removes the step, an owner, and evidence
(task ids, status keys and times, session ids). Quoted evidence is one
scrubbed line: a status text excerpt with tokens redacted, a command head, the
matched refusal class, or, for a repeated ask, Lee's own sentence per day. No
other transcript prose is kept, and nothing is sent to a model or service.

A finding's id is a slug of its cause, sub and name alone, so it is the same
every night (at most 54 characters, which fleet-app's tap card needs). Its
state is read-only and as of the run's day, one of:

  settled             a line in a home's data/captain-shared.md that says
                      "standing rule" or "standing exception" names the id
                      (alone or as friction-<id>) or its category key written
                      "settles: <cause>/<sub>" (for example "settles:
                      policy/merge-word"; a finding about one tool, hook or
                      service also needs the line to name it, or the key to
                      carry it as "settles: <cause>/<sub>/<name>"); no looser
                      wording settles anything. The card quotes the line as
                      `rule` {text, source};
  started             a Start fix tap for it sits in a home's state/inbox (the
                      note fleet-app's shim files, "Captain's Log reply
                      [friction-<id>]: Start fix: <title>") or in
                      <captains-log>/replies?since=<30 days ago>, or a
                      started-by-default note, or a data/backlog.md line or a
                      task's branch= names it, and its fix has not merged. The
                      card carries `link` (the first pull request or https URL
                      those hold) and `task` (the backlog line's or branch's),
                      or `reopen` true when it has neither;
  fixed               the started fix merged (a task.merged record in a home's
                      fleet ledger, by its task or pull request) and the
                      finding has no event after the merge. The card carries
                      `fixed` {link, merged_at};
  reported-again      the fix merged and the finding has an event after the
                      merge (the newest stamped event, else the start of the
                      run's day) and no start newer than the merge;
  started-by-default  the fix is standing work (see below) and nothing started
                      it, or it was reported again after a merged fix;
  open                anything else.

Standing work (STANDING_START) is a finding in a card-bar group whose fix fleet
rules section 2 already starts ("Velocity findings go ahead by default: an
agent starts the fix unless Lee objects within a day"); credentials, approvals,
sudoers rules, the gate-edit and secret hooks, and product decisions are
reserved and stay open for Lee.

Linear. The officer follows the shared officer contract (docs/officers/contract.md;
bin/fm-officer-linear.py owns the mechanics) with its rubric
docs/officers/friction-rubric.md, which owns what counts as work, how a finding
is scored and what starts. With --writes linear (the registry's `writes:
linear`, with max-creates, max-linear-calls and jev) every finding that is
real, not tracked (state settled, started or fixed), and not a product choice
or a retired tool is filed once in team PC, project Fleet, labels Improvement,
the rubric's Source label (agent, from Lee's set) and area:fleet, keyed by its cause, sub and name.
A repeat night raises the item's `Found: N times` line in place, and the found
count is the priority lever: score = severity weight x log2(1 + found), with a
card-bar finding high, an uncarded one of friction severity 3 or more medium,
and the rest low. The item body holds counts, waits, the fix, owner and
identifiers, and never a transcript line, command or quoted ask. A label that
team PC lacks means the finding is reported and not filed. Whatever the
create cap, call budget or a rate limit leaves unfiled is named in the digest
and filed by the next run. The lane keeps filed-fingerprints.json, found.json
and review-state.json only when it writes.

Each standing-work finding whose Linear item exists and whose score reaches the
rubric minimum gets a start request in the digest's `start_requests` (and, for
this home, a <date>.start-requests.sh handoff), the shared start emitter's
fm-inbox.sh note call, addressed to the --start-home office that dispatches the
fleet repositories (the Quartermaster), else to --fm-home; an office's lane
check delivers it (bin/fm-office.sh). The note carries a marker line, so a
delivered request reads back as started, and a request is repeated each night
until it does. A finding that matches a reserved class is held instead, as one
keyed needs-decision line in the digest's `asks_for_lee`. Without writes: linear
nothing starts by default (each card offers Start fix and the digest names the
gap). An `Object` tap on the finding's card (a note or reply "Object") keeps it
from starting by default. Without --fm-home, or when the addressed home is not
one of the --home records read (a delivered note could never be read back),
nothing is started by default and the digest names the gap.
Each card carries `actions`: open and reported-again offer start-fix, a
started-by-default card offers object, a started card with no link or task
offers reopen, and the rest offer none, so a standing-work card never offers a
bare Start fix. docs/configuration.md "Officers" lists the card fields.

The proposed fix comes from the FIXES table. A group no rule names gets no
card, and neither does a missing tool in RETIRED_TOOLS (its events are still
counted, but the fleet no longer uses it, so installing it is never proposed);
propose_fix() is the seam where a later slice may ask a small model,
and slice 1 accepts only --model none.
"""

import argparse
import datetime
import gzip
import hashlib
import importlib.util
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
import zoneinfo


def _triage():
    mod = sys.modules.get("fm_officer_triage")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-triage.py")
        spec = importlib.util.spec_from_file_location("fm_officer_triage", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["fm_officer_triage"] = mod
    return mod


triage = _triage()


def _progress():
    """The progress officer's module, loaded only where start requests are written (never on the archive host)."""
    mod = sys.modules.get("fm_officer_progress")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-progress.py")
        spec = importlib.util.spec_from_file_location("fm_officer_progress", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["fm_officer_progress"] = mod
    return mod

SCORER = "friction-deterministic-v1"
MIN_SEVERITY = 3
MIN_CONFIDENCE = 3
MAX_CARDS = 25  # fleet-app's stored cap on bottlenecks
ID_MAX = 54  # fleet-app's stored finding id cap: its tap card friction-<id> must fit a 64-character card id

# Status logs that relay other tasks' lines rather than belong to a task: a
# second mate's parent channel (docs/secondmate-parent-channel.md), here and,
# as state/<mate-id>.status, in its parent home (each --channel <mate-id>).
CHANNEL_LOGS = {"parent-replies"}
LEE_RE = re.compile(r"\b(Lee|captain|Captain)\b")
STATUS_RE = re.compile(r"^([a-z][a-z-]*)\b([^:]*):\s?(.*)$")
AT_RE = re.compile(r"(?:^|[\s\[])at=(\d+)\b")
KEY_RE = re.compile(r"(?:^|[\s\[])key=([^\]\s]+)")
CAUSE_RE = re.compile(r"(?:^|[\s\[])cause=([^\]\s]+)")
# The causes a worker may state on a blocked or needs-decision line (bin/fm-classify-lib.sh
# status_line_cause owns the vocabulary) and the friction group each joins when no text rule
# recognised the line; anything else reads as unstated.
STATED_CAUSES = {"policy": ("policy", "approval"), "credential": ("credential", "missing"),
                 "sudo": ("sudo", "sudo"), "tool": ("missing-tool", "tool"),
                 "decision": ("decision", "decision"), "external": ("environment", "external"),
                 "physical": ("lee-command", "run")}
URL_RE = re.compile(r"https?://\S+")
CORR_RE = re.compile(r"\bcorr=[0-9a-f]+\s*")
SSH_HOST_RE = re.compile(r"\bssh (?:-\w+ )*(?:[\w.-]+@)?([\w.-]+) '")
CARD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
HOLD_KEY_RE = re.compile(r"^captain-hold-(.+)-\d+$")

# An assistant asking Lee to act. Only assistant text blocks are matched.
ASK_RE = re.compile(
    r"waiting (?:for|on) (?:Lee|you|the captain) to (?:run|do|type|approve|sign|create|save|set)"
    r"|asked Lee(?:,[^.]{0,40})? to (?:run|do|type|create|approve)"
    r"|(?:Lee|you) (?:needs?|ha(?:s|ve)) to (?:run|type|create|approve|sign)"
    r"|needs? Lee to (?:run|type|create|save|approve)"
    r"|(?:run|paste|type) (?:this|it|that|these|the (?:following|command|line)s?)(?: one)?(?: line)?"
    r" (?:in|from) your (?:own )?(?:[\w-]+ )?(?:terminal|window|shell|pane)"
    r"|in your own (?:signed-in )?terminal", re.I)
BACKTICK_RE = re.compile(r"`([^`\n]{2,200})`")
# A user record that is a wake or tool prompt rather than something Lee typed.
MACHINE_PROMPT_RE = re.compile(
    r"^\s*(?:[:<\[]|Firstmate |Continue |Caveat:|This session is being continued|Base directory for this skill)")
INSTALL_RE = re.compile(r"\b(?:install|i)\s+(?:-\S+\s+)*([A-Za-z][\w.+-]*)")
BASH_INPUT_RE = re.compile(r"^<bash-input>(.*?)</bash-input>", re.S)

# Agent-side refusals, matched only at the start of a tool-result line.
HIT_PATTERNS = [
    ("guard", re.compile(r"^PreToolUse:\w+ hook error: \[(?:[^\]]*/)?([^\]/]+)\]: BLOCKED \(([^)]+)\)", re.M)),
    ("sudo", re.compile(r"^sudo: (a terminal is required|a password is required|\d+ incorrect password)", re.M)),
    ("ssh-key", re.compile(r"Permission denied \(publickey", re.M)),
    ("op", re.compile(r"^\[ERROR\] [\d/: ]+(Too many requests|.*You do not have permission to perform"
                      r"|.*You are not currently signed in)", re.M)),
    ("cli-login", re.compile(r"^(?:ERROR: Please run 'az login'|You are not logged into any GitHub hosts"
                             r"|To get started with GitHub CLI, please run:  gh auth login)", re.M)),
    ("missing-tool", re.compile(r"^(?:/bin/|/usr/bin/)?(?:ba|z)?sh: (?:line \d+: )?([\w.+-]+): command not found",
                                re.M)),
]

SERVICES = [
    ("Cloudflare", re.compile(r"cloudflare|wrangler", re.I)),
    ("1Password", re.compile(r"1password|\bop(?:-agent)?\b|op://", re.I)),
    ("GitHub", re.compile(r"\bgh\b|github", re.I)),
    ("Azure", re.compile(r"\baz\b|azure|key vault", re.I)),
    ("Linear", re.compile(r"\blinear\b", re.I)),
    ("Stripe", re.compile(r"\bstripe\b", re.I)),
    ("Auth0", re.compile(r"\bauth0\b", re.I)),
]

SERVICE_NAMES = "|".join(p.pattern for _, p in SERVICES)
OP_FAILURE_RE = re.compile(r"do not have permission to perform|service[- ]account", re.I)

# Root-cause rules for status text and asks: (cause, sub, pattern); first match wins.
RULES = [
    ("guard-hook", "secret-hook", re.compile(
        r"secret[- ]exposure|secret[- ]?(?:file )?hook|pre-bash-secret|shell[- ](?:startup )?file.{0,40}"
        r"(?:hook|guard|block)|(?:hook|guard)s? block\w* .{0,40}(?:startup|shell) file", re.I)),
    ("guard-hook", "gate-edit", re.compile(r"ALLOW_GATE_EDIT|gate[- ]integrity guard", re.I)),
    ("guard-hook", "other", re.compile(
        r"BLOCKED \(|\bhook\b.{0,40}\b(?:block|den|refus)|\bguard\b.{0,40}\b(?:block|den|refus)", re.I)),
    ("service-limit", "rate-limit", re.compile(
        r"too many requests|rate[- ]limit|pool (?:is )?exhausted|pool to reset|daily (?:pool|allowance)"
        r"|whole read_write allowance", re.I)),
    ("sudo", "sudo", re.compile(
        r"\bsudo\b|\bas root\b|root-owned|systemctl (?:restart|enable|start)|update-grub|apt(?:-get)? install"
        r"|sudoers|needs? root\b|\broot on\b|requires a password for", re.I)),
    ("policy", "credential-approval", re.compile(
        r"credential change|(?:credential|secret)\b.{0,80}Lee'?s (?:own )?words?|credential[- ]naming", re.I)),
    ("credential", "create-denied", re.compile(
        r"(?:can'?t|cannot|not permitted to|no permission to|do not have permission to).{0,60}"
        r"(?:create|write|save)|create items|item create", re.I)),
    ("credential", "scope", re.compile(
        r"authentication error|code 10000|insufficient (?:permission|privilege)s?"
        r"|(?<![\w-])(?:403|forbidden)(?![\w-]).{0,60}(?:token|credential|api key|service account|%(svc)s)"
        r"|(?:token|credential|api key|service account|%(svc)s).{0,60}(?<![\w-])(?:403|forbidden)(?![\w-])"
        r"|refus\w*\b.{0,60}token|token.{0,40}refus|do not have permission to perform"
        r"|%(cred)s(?: \w+){0,3} (?:lacks?|missing|without|needs?|requires?|refused|denied)\b.{0,30}\bscopes?\b"
        r"|\b(?:missing|lacks?|insufficient|required|without)\b.{0,20}\bscopes?\b.{0,30}%(cred)s"
        r"|%(cred)s.{0,30}\bno\b(?: [\w-]+){0,2} scopes?\b|%(cred)s.{0,30}\bscopes? (?:is |are )?too narrow"
        r"|widen(?:ed|ing)? (?:the )?(?:\w+ )?token"
        % {"svc": SERVICE_NAMES, "cred": r"(?<![^\W_]|-)(?:token|key|grant)s?(?![^\W_])"}, re.I)),
    ("credential", "login", re.compile(
        r"not logged in|not currently signed in|op signin|auth login|az login|sign[- ]in required|gh auth", re.I)),
    ("credential", "missing", re.compile(
        r"\b(?:secret|credential|token|api key|password)\b.{0,40}\b(?:missing|absent|not set|not found|needed)"
        r"|needs? (?:a|the|one) (?:database )?(?:credential|secret|token|password)", re.I)),
    ("missing-tool", "tool", re.compile(r"command not found|not installed|no such command|missing tool", re.I)),
    ("environment", "wrong-cwd", re.compile(
        r"wrong (?:directory|cwd|worktree)|restored .{0,40}(?:directory|cwd)|after (?:a |the )?reboot", re.I)),
    ("credential", "console-step", re.compile(
        r"\bin (?:the )?(?:Cloudflare|Azure|Auth0|Stripe|GitHub|1Password|Google Workspace)\b.{0,40}"
        r"(?:dashboard|console|portal|admin|zone|>)", re.I)),
    ("policy", "merge-word", re.compile(r"merge word", re.I)),
    ("policy", "approval", re.compile(
        r"Lee'?s (?:word|go|approval|sign-?off)|needs? Lee'?s|production (?:write|deploy|change)"
        r"|recorded word|destructive|discard", re.I)),
    ("lee-command", "run", re.compile(
        r"Lee,? (?:please )?(?:runs?|to run|pastes?|types?)\b|for Lee to run|line (?:from|for) Lee"
        r"|ssh -t \S+ '", re.I)),
    ("decision", "decision", re.compile(r"\([a-dA-D]\)|\boptions?\b|\bdecide\b|\bchoose\b|\bpick\b", re.I)),
]

# Rules for a command Lee typed, tried before RULES.
COMMAND_RULES = [
    ("sudo", "sudo", re.compile(r"\bsudo\b")),
    ("missing-tool", "tool", re.compile(r"^(?:brew|apt(?:-get)?|dnf|pip3?|npm|pipx) (?:install|i)\b")),
    ("credential", "create-denied", re.compile(r"^op\b.*\b(?:item|document) create\b")),
    ("credential", "login", re.compile(r"^(?:op signin|gh auth|az login|az logout)|\bgh auth\b|\baz log(?:in|out)\b")),
    ("credential", "lee-session", re.compile(r"^op (?:run|read|inject)\b")),
    ("guard-hook", "gate-edit", re.compile(r"ALLOW_GATE_EDIT")),
]

CATEGORY = {"guard-hook": "tooling", "missing-tool": "tooling", "credential": "waiting", "sudo": "waiting",
            "policy": "waiting", "decision": "waiting", "environment": "environment",
            "service-limit": "environment", "lee-command": "waiting", "repeat-ask": "waiting", "other": "other"}

# (cause, sub) -> title, what Lee had to do, the fix, owner, effort.
# {service}, {tool} and {machine} are filled from the group, never in a title, so a
# title is the same for every group of its cause; the bottleneck's tldr names the group.
FIXES = {
    ("guard-hook", "secret-hook"): (
        "Secret-exposure hook blocks safe shell-file edits, so Lee makes them",
        "make a shell startup or secret-file edit the secret-exposure hook refused",
        "Give the secret-exposure hook a sanctioned path for writing op:// reference lines (never literal values)"
        " to shell startup files, with a fixture test, so agents make the edit themselves.",
        "skills (global hooks)", "S"),
    ("guard-hook", "gate-edit"): (
        "Gate-file guard needs Lee to set ALLOW_GATE_EDIT by hand",
        "set ALLOW_GATE_EDIT in a worker's terminal so it could edit a gate file",
        "Let firstmate set ALLOW_GATE_EDIT for one named file and PR from Lee's recorded sign-off, through a"
        " logged wrapper, instead of Lee typing the export into the worker's pane.",
        "PropertyCompass2 (gate hooks)", "M"),
    ("guard-hook", "refused"): (
        "Hook refusals slow agents down",
        "nothing directly; agents retried around the refusal",
        "Where the refusal is right, make its message name the allowed command so the agent's next try"
        " succeeds; where it is a false positive, report it to the hook's owner with a fixture.",
        "skills (global hooks)", "S"),
    ("guard-hook", "other"): (
        "A guard or hook refuses agent commands",
        "unblock work a guard or hook refused",
        "Read the refused commands: where the guard is right, name the allowed alternative in its refusal text;"
        " where it is a false positive, report it to the hook's owner with a fixture.",
        "skills (global hooks)", "S"),
    ("service-limit", "rate-limit"): (
        "Service rate limits stall agents until the limit resets",
        "wait for, or raise, a {service} rate limit",
        "Serve repeat reads from a cache (op-agent's for 1Password) and count calls per host, so one busy"
        " worker cannot exhaust the shared limit; warn at 80% instead of failing at 100%.",
        "skills (op-agent)", "M"),
    ("sudo", "sudo"): (
        "Agents hand Lee sudo steps to run by hand",
        "run a sudo command or script by hand",
        "Install a root-owned script for the step with a NOPASSWD sudoers rule naming that exact path (or a"
        " systemd unit the agent may start), approved once by Lee, so the agent runs it itself.",
        "{machine} home (Lee approves the sudoers rule)", "M"),
    ("policy", "credential-approval"): (
        "New staging credentials wait on Lee's per-credential word",
        "approve a new credential by name",
        "Adopt a standing naming rule for new staging-only credentials (name pattern, vault, owner) so a name"
        " that follows it is pre-approved; production credentials stay direct-only.",
        "Lee (fleet rules section 5)", "S"),
    ("credential", "create-denied"): (
        "Agents cannot create secret items, so Lee creates them",
        "create a secret or item the agents' account may not create",
        "Give the agents' service account create rights in one dedicated staging vault, or a create-only"
        " broker that generates the value and never prints it.",
        "Lee ({service} admin)", "S"),
    ("credential", "scope"): (
        "An agent token lacks a scope, so Lee widens it",
        "widen or roll a {service} token for the agents",
        "Keep the agent token's required scopes in one checked list and probe them at session start, so a"
        " widening is asked for once, with the full list, before work starts.",
        "Lee (token owner); main keeps the scope list", "S"),
    ("credential", "login"): (
        "A service CLI is not signed in for agents",
        "sign a CLI in, or out, by hand",
        "Authenticate the CLI from a service-account token through op-agent instead of an interactive login,"
        " and check it in the machine's session-start doctor.",
        "{machine} home", "S"),
    ("credential", "lee-session"): (
        "Lee runs commands under his own signed-in session",
        "run a command under his own signed-in {service} session",
        "Where a staging-scoped key would do, let the agent run it under op-agent; where it needs a production"
        " key, keep it Lee's but hand it as one ready line from main.",
        "main (firstmate)", "S"),
    ("credential", "ssh-key"): (
        "Agents lack an ssh key for a fleet host",
        "run an ssh step by hand because the agent's key was refused",
        "Install the agent's key in the target host's authorized_keys, or give it an ssh alias that reaches"
        " the host, and record it in the machine's bootstrap so the refusal cannot come back.",
        "{machine} home", "S"),
    ("credential", "console-step"): (
        "Lee does console steps an agent token could do",
        "click through {service} console steps by hand",
        "Check whether the agent token's API covers the step; if it does, widen the token once and let the"
        " agent do it; if it does not, hand it as one ready line or link with the exact values.",
        "Lee (token owner); main checks the API", "S"),
    ("credential", "missing"): (
        "Agents wait for a credential they do not have",
        "supply a credential an agent lacked",
        "Store the credential in the agents' 1Password vault, or record that it is direct-only, so agents"
        " stop waiting on it.",
        "Lee", "S"),
    ("missing-tool", "tool"): (
        "A tool agents need is missing",
        "install a tool by hand",
        "Add {tool} to {machine}'s bootstrap and its doctor check, so it is present before the next session.",
        "{machine} home", "S"),
    ("environment", "ssh-to-self"): (
        "Lee-step ssh lines target the machine they run on",
        "run an ssh -t <host> line inside a session on that same host, where ssh to itself has no key",
        "Make Lee-step one-liners host-aware: print `bash <script>` when the session already runs on the"
        " target host and `ssh -t <host> ...` only from another machine, or install a loopback key.",
        "main (firstmate)", "S"),
    ("environment", "wrong-cwd"): (
        "Worker sessions resume in the wrong directory after a restart",
        "put restored worker sessions back in their task copies",
        "Resume each worker in the worktree its task record names (cd to its meta worktree= first) and refuse"
        " a resume whose directory differs.",
        "main (firstmate)", "M"),
    ("policy", "merge-word"): (
        "Merge-word asks reach Lee one at a time",
        "give his merge word on a PR the rules reserve to him",
        "Collect the day's merge-word asks into one Captain's Log card with each PR's category, gate result"
        " and diff size inline, so Lee answers them in one pass instead of one wake each.",
        "main (firstmate)", "M"),
    ("lee-command", "run"): (
        "Lee runs commands by hand with no recorded reason",
        "run a command or script by hand",
        "Make every Lee-step ask name why the agent cannot run it (sudo, credential, policy or tool), so the"
        " cause can be removed; then remove it, starting with the most repeated.",
        "main (firstmate)", "S"),
    ("environment", "external"): (
        "Agents block on a service, machine or agent they cannot reach",
        "nothing directly; the line says the agent waits on something outside the task",
        "Name the dependency and when it should recover in the line, and let firstmate re-check it on a timer"
        " instead of holding the task; fix the dependency's own outage or access if it repeats.",
        "main (firstmate)", "S"),
    ("other", "other"): (
        "Blocked steps carry no recorded cause",
        "answer an ask whose reason no rule recognised",
        "Workers now tag blocked and needs-decision lines with [cause=policy|credential|sudo|tool|decision|"
        "external]; find the tasks and homes this group's evidence names that still write untagged lines, update"
        " their briefs, then remove the most repeated cause.",
        "main (firstmate)", "S"),
    ("repeat-ask", "instruction"): (
        "Lee gives the same instruction on several days",
        "repeat an instruction he has already given",
        "Turn the instruction into automatic work: a scheduled officer check, a hook, or a standing rule in"
        " captain-shared.md that firstmate applies without being told, and say so to Lee once.",
        "main (firstmate)", "S"),
    ("policy", "approval"): (
        "Routine steps wait on Lee's explicit word",
        "give his word for a step the rules reserve to him",
        "Name the recurring approval class in the fleet rules with a standing yes for its safe subset, so"
        " agents ask only for the rest.",
        "Lee (fleet rules)", "S"),
}
# Groups reported in the digest but never carded: a product or design choice is Lee's to make.
NOT_CARDED = {("decision", "decision")}
# Tools the fleet no longer uses: a miss is still counted, but never becomes an "install it" fix or card.
# Retiring another tool is a one-line change here.
RETIRED_TOOLS = {"railway"}
# Groups whose fix is standing work: fleet rules section 2 ("Velocity findings go ahead by default: an agent starts
# the fix unless Lee objects within a day"), with the reserved classes of section 8 left out. A finding in one of
# these groups that clears the card bar is started by default and carries an Object action, never a bare Start fix.
# Everything else (credentials, secrets, approvals and merge words, sudoers rules, the gate-edit and secret-exposure
# hooks, product decisions) grants new authority or touches a reserved class, so it stays Lee's to start.
STANDING_START = {
    ("guard-hook", "refused"), ("guard-hook", "other"), ("service-limit", "rate-limit"), ("missing-tool", "tool"),
    ("environment", "ssh-to-self"), ("environment", "wrong-cwd"), ("environment", "external"),
    ("lee-command", "run"), ("repeat-ask", "instruction"), ("other", "other"),
}
# The standing-work causes are the sources the rubric (docs/officers/friction-rubric.md) may let start.
START_SOURCES = tuple(sorted({cause for cause, _ in STANDING_START}))
RUBRIC_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "officers", "friction-rubric.md")
TYPE_LABEL = "Improvement"
# Lee's Linear setup (2026-10-13) allows these Source labels; "agent" is for any worker filing on his behalf. The rubric's
# `source-label` setting picks one, and any other value is ignored.
SOURCE_LABELS, DEFAULT_SOURCE_LABEL = ("agent", "bug-sweep", "scheduled-review", "slack-desk", "captain"), "agent"
# The actions the page may draw for each state; a standing-work finding is never offered a bare Start fix.
STATE_ACTIONS = {"open": ["start-fix"], "reported-again": ["start-fix"], "started-by-default": ["object"],
                 "started": [], "fixed": [], "settled": []}


def iso_utc(epoch):
    return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch_of(stamp):
    """Epoch seconds of an ISO stamp such as 2026-10-23T22:38:56.218Z, or None."""
    if not isinstance(stamp, str):
        return None
    try:
        dt = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return int(dt.timestamp())


def day_bounds(date):
    """Epoch seconds of local midnight starting and ending <date>."""
    start = datetime.datetime.strptime(date, "%Y-%m-%d")
    end = start + datetime.timedelta(days=1)
    return int(time.mktime(start.timetuple())), int(time.mktime(end.timetuple()))


def scrub(text, limit=140):
    """One status-text excerpt: tokens redacted, whitespace collapsed, cut."""
    s = triage.TOKEN_RE.sub("<token>", text or "")
    s = re.sub(r"\s+", " ", s).strip()
    return s if len(s) <= limit else s[:limit - 3].rstrip() + "..."


def clean(text):
    """Status text without URLs or correlation ids, which carry no cause."""
    return CORR_RE.sub("", URL_RE.sub("<url>", text or ""))


def classify(text, rules=RULES):
    """(cause, sub, position of the match) by the first rule that matches."""
    for cause, sub, pattern in rules:
        candidate = text or ""
        if cause == "missing-tool" and rules is RULES:
            candidate = re.sub(
                r"\b(?:service|unit|update) (?:is |was )?not installed\b",
                lambda m: " " * len(m.group(0)), candidate, flags=re.I)
            if (re.search(r"merge[- ]word|Lee'?s (?:word|go|approval|sign-?off)|needs? Lee'?s", candidate, re.I)
                    and not re.search(r"command not found|no such command", candidate, re.I)):
                continue
        m = pattern.search(candidate)
        if m:
            return cause, sub, m.start()
    return "other", "other", 0


def service_of(text, near=0, scope=False):
    """The service named closest to position `near`, or None."""
    best = None
    # 1Password named only as the store of a token is not the failing provider.
    stored_only = scope and not OP_FAILURE_RE.search(text or "")
    for name, pattern in SERVICES:
        if name == "1Password" and stored_only and any(
                p.search(text or "") for n, p in SERVICES if n != "1Password"):
            continue
        for m in pattern.finditer(text or ""):
            distance = abs(m.start() - near)
            if best is None or distance < best[0]:
                best = (distance, name)
    return best[1] if best else None


def script_name(words):
    for word in words:
        base = word.rsplit("/", 1)[-1]
        if re.fullmatch(r"[\w.-]+\.(?:sh|py|js|cjs|ts)", base):
            return base
    return None


def command_signature(command):
    """A command Lee typed, reduced to its command words: no values, paths or quoted text."""
    first = (triage.command_segments(command) or [""])[0]
    try:
        words = shlex.split(command.strip().split("\n")[0])
    except ValueError:
        words = command.split()
    if words and words[0].rsplit("/", 1)[-1] == "ssh":
        host, i = None, 1
        while i < len(words):
            w = words[i]
            if w in ("-o", "-i", "-p", "-l", "-J", "-F", "-L", "-R", "-D"):
                i += 2
                continue
            if w.startswith("-"):
                i += 1
                continue
            host = w
            break
        rest = " ".join(words[i + 1:]).split()
        flags = [w for w in words[1:i] if w.startswith("-") and w not in ("-o",)]
        parts = ["ssh"] + [f for f in flags if re.fullmatch(r"-[A-Za-z]+", f)]
        if host:
            parts.append(re.sub(r"^[^@]*@", "", host))
        if rest:
            name = script_name(rest)
            lead = rest[0].rsplit("/", 1)[-1]
            parts.append(lead if re.fullmatch(r"[a-z][\w-]*", lead) else "...")
            if name and name != lead:
                parts.append(name)
        return triage.TOKEN_RE.sub("<token>", " ".join(parts)), host
    head = []
    for word in first.split():
        word = word.rsplit("/", 1)[-1] if not head else word
        if word.startswith("-") or (head and not re.fullmatch(r"[a-z][a-z0-9-]*", word)):
            break
        head.append(word)
        if len(head) == 3:
            break
    sig = " ".join(head) or "..."
    return triage.TOKEN_RE.sub("<token>", sig), None


def ask_signature(text):
    m = BACKTICK_RE.search(text)
    if not m:
        return "..."
    sig, _ = command_signature(m.group(1))
    return sig


def records_of(path):
    try:
        with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
            return [json.loads(line) for line in fh if line.strip()]
    except (OSError, ValueError, EOFError):
        return None


def user_text(rec):
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    return None


# Record fields that mark a user-role record as harness-injected rather than typed by Lee.
INJECTED_FLAGS = ("isMeta", "isSidechain", "isCompactSummary", "isVisibleInTranscriptOnly",
                  "toolUseResult", "sourceToolUseID", "sourceToolAssistantUUID")


# Blocks Claude Code and its hooks wrap around guidance they add to a user-role record.
INJECTED_BLOCK_RE = re.compile(
    r"<(system-reminder|task-notification|command-[\w-]+|local-command-[\w-]+|user-prompt-submit-hook"
    r"|hook-[\w-]+|available-deferred-tools|new-diagnostics|ide_[\w]+)\b[^>]*>.*?(?:</\1>|\Z)", re.S)


def typed_text(rec, stamped=False):
    """user_text, but only for a record Lee typed: never a peer or agent message, hook context,
    tool result, sub-agent prompt, or guidance the harness wrapped into the message. Claude Code stamps
    typed text origin.kind == "human"; a record without an origin counts only in a transcript where no
    record carries one (older versions), and unless another marker flags it. `stamped` says the
    transcript's records carry origins."""
    if any(rec.get(flag) for flag in INJECTED_FLAGS):
        return None
    if rec.get("userType") not in (None, "external"):
        return None
    origin = rec.get("origin")
    if origin is None and stamped:
        return None
    if origin is not None and (not isinstance(origin, dict) or origin.get("kind") != "human"):
        return None
    text = user_text(rec)
    if text is None:
        return None
    return INJECTED_BLOCK_RE.sub("\n", text)


def classify_command(command, machine=None, after=""):
    """(cause, sub) of a command Lee typed on `machine`; `after` is its shell output."""
    _, host = command_signature(command)
    if host and machine and re.sub(r"^[^@]*@", "", host) == machine:
        return "environment", "ssh-to-self"
    if host and "Permission denied (publickey" in after:
        return "credential", "ssh-key"
    cause, sub, _ = classify(command, COMMAND_RULES)
    if cause == "other":
        cause, sub, _ = classify(command)
    if cause in ("other", "decision"):
        cause, sub = "lee-command", "run"
    return cause, sub


def bash_output_after(records, n):
    for later in records[n + 1:n + 3]:
        text = user_text(later) or ""
        if text.startswith("<bash-stdout>") or text.startswith("<bash-stderr>"):
            return text
    return ""


def hit_event(hit, m):
    """The event for one agent-side refusal match."""
    tool = service = None
    if hit == "guard":
        cause, sub, tool = "guard-hook", "refused", m.group(1)
        sig = "%s: %s" % (m.group(1), m.group(2))
    elif hit == "sudo":
        cause, sub, sig = "sudo", "sudo", "sudo: " + m.group(1)
    elif hit == "ssh-key":
        cause, sub, sig = "credential", "ssh-key", "ssh: Permission denied (publickey)"
    elif hit == "op":
        reason = m.group(1)
        if "Too many requests" in reason:
            cause, sub = "service-limit", "rate-limit"
        elif "signed in" in reason:
            cause, sub = "credential", "login"
        else:
            cause, sub = "credential", "scope"
        sig, service = "1Password: " + triage.normalise(reason, 60), "1Password"
    elif hit == "cli-login":
        cause, sub, service = "credential", "login", service_of(m.group(0))
        sig = triage.normalise(m.group(0), 60)
    else:
        cause, sub, tool = "missing-tool", "tool", m.group(1)
        sig = "%s: command not found" % tool
    return {"kind": "agent-hit", "cause": cause, "sub": sub, "lee": False,
            "service": service, "tool": tool, "signature": sig}


SHELL_SHEBANG_RE = re.compile(r"#!\S*(?:/|\s)(?:ba)?sh\b")


def tool_inputs(records):
    """Every Bash command of one transcript by tool_use id, and its shell code joined: the commands and
    the bodies written or edited into shell files (.sh, .bash or a sh/bash shebang)."""
    by_id, bodies = {}, []
    for rec in records:
        content = (rec.get("message") or {}).get("content")
        if rec.get("type") != "assistant" or not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                inp = block.get("input") or {}
                command = inp.get("command") if isinstance(inp.get("command"), str) else None
                by_id[block.get("id")] = command
                texts = [v for k, v in inp.items() if k in ("content", "new_string") and isinstance(v, str)]
                if command is not None:
                    bodies.append(command)
                elif str(inp.get("file_path") or "").endswith((".sh", ".bash")) \
                        or any(SHELL_SHEBANG_RE.match(t) for t in texts):
                    bodies.extend(texts)
    return by_id, "\n".join(bodies)


def plausible_tool(name, command, bodies):
    """Whether `name` from a "command not found" line is an installable command a person could add:
    not a dotted field name, not a shell function the session itself defined (a test helper, a function
    used outside its script), and not a word the command that ran held only as a `name:` label
    (a command that never names it reached it through a script: a real miss)."""
    if re.fullmatch(r"[A-Za-z_]+(?:\.[A-Za-z_]+)+", name):
        return False
    esc = re.escape(name)
    if re.search(r"(?m)^\s*(?:function\s+%s\b|%s\s*\(\s*\))" % (esc, esc), bodies or ""):
        return False
    word = r"(?<![\w.-])%s(?![\w.-])" % esc
    if command is None or not re.search(word, command):
        return True
    return re.search(word + "(?!:)", command) is not None


def session_events(records, machine):
    """Friction events in one transcript, in record order."""
    events = []
    commands, bodies = tool_inputs(records)
    asks = {}
    pending = []    # asks waiting for Lee's next typed message
    for n, rec in enumerate(records):
        kind = rec.get("type")
        at = epoch_of(rec.get("timestamp"))
        content = (rec.get("message") or {}).get("content")
        text = user_text(rec) if kind == "user" else None
        if text is not None:
            cmd = BASH_INPUT_RE.match(text.strip())
            if (cmd is not None or not MACHINE_PROMPT_RE.match(text)) and at is not None:
                for ask in pending:
                    ask["answered_at"] = at
                    ask["wait_s"] = max(0, at - ask["at"])
                pending = []
            if cmd:
                command = cmd.group(1).strip()
                sig, _ = command_signature(command)
                cause, sub = classify_command(command, machine, bash_output_after(records, n))
                tool = None
                if cause == "missing-tool":
                    m = INSTALL_RE.search(command)
                    tool = m.group(1) if m else None
                events.append({"kind": "lee-command", "at": at, "cause": cause, "sub": sub, "lee": True,
                               "service": service_of(command, 0, (cause, sub) == ("credential", "scope")),
                               "tool": tool, "signature": sig})
            continue
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if kind == "assistant" and block.get("type") == "text":
                body = block.get("text") or ""
                m = ASK_RE.search(body)
                if not m:
                    continue
                start = body.rfind("\n", 0, m.start()) + 1
                end = body.find("\n", m.end())
                line = body[start:end if end >= 0 else len(body)]
                sig = ask_signature(line)
                if sig in asks:
                    asks[sig]["count"] += 1
                    if at is not None:
                        asks[sig]["last_at"] = at
                    continue
                cause, sub, pos = classify(line)
                if cause in ("other", "decision"):
                    cause, sub = classify_command(sig) if sig != "..." else ("lee-command", "run")
                ask = {"kind": "lee-ask", "at": at, "last_at": at, "count": 1, "cause": cause, "sub": sub,
                       "lee": True, "service": service_of(line, pos, (cause, sub) == ("credential", "scope")),
                       "tool": None, "signature": sig,
                       "answered_at": None, "wait_s": None}
                asks[sig] = ask
                events.append(ask)
                if at is not None:
                    pending.append(ask)
            elif kind == "user" and block.get("type") == "tool_result":
                body = triage.result_text(block)
                for hit, pattern in HIT_PATTERNS:
                    m = pattern.search(body)
                    if m and hit == "missing-tool":
                        command = commands.get(block.get("tool_use_id"))
                        m = next((x for x in pattern.finditer(body)
                                  if plausible_tool(x.group(1), command, bodies)), None)
                        if m is None:
                            break
                    if m:
                        events.append(dict(hit_event(hit, m), at=at))
                        break
    return events


INSTRUCTION_RE = re.compile(
    r"\b(?:keep|make sure|always|never|don'?t|do not|should|shouldn'?t|need(?:s)? to|must|remember|stop|"
    r"have to|has to|supposed to|ought to)\b", re.I)
# Words that carry no instruction, the instruction markers themselves, and the fillers of dictated speech.
FILLER = frozenset("""make sure need needs should shouldnt must dont always never remember stop ought supposed please up
a about all also am an and any are as at be been being but by can could did do does for from
got had has have he her him his how i if in into is it its just like me more my no not of on one only or our out
so some than that the their them then there these they this those to too us was we were what when which who will
with would yeah um uh er you your youre ive id im thats there
want know think going gonna wanna get getting go really hey say come back constantly having lets okay ok yes thanks
maybe actually basically kind sort lot bit way thing things stuff time""".split())
ASK_MIN_SHARED = 3
ASK_MIN_OVERLAP = 0.7
UPKEEP = "upkeep"
UPKEEP_WORDS = frozenset("keep update current date fresh maintain look check review watch track monitor stale".split())
ASK_MIN_SHARED_UPKEEP = 2
MAX_ASK_LEN = 300


def ask_tokens(sentence):
    words = re.findall(r"[a-z]+", sentence.lower().replace("'", ""))
    stems = (w[:-1] if len(w) > 4 and w.endswith("s") else w for w in words if w not in FILLER and len(w) > 1)
    return frozenset(UPKEEP if is_upkeep(w) else w for w in stems)


def is_upkeep(word):
    if word.endswith("ing"):
        return word[:-3] in UPKEEP_WORDS or word[:-3] + "e" in UPKEEP_WORDS
    if word.endswith("ed"):
        return word[:-2] in UPKEEP_WORDS or word[:-1] in UPKEEP_WORDS
    return word in UPKEEP_WORDS


def same_ask(a, b):
    shared = a & b
    if len(shared) >= ASK_MIN_SHARED and len(shared) >= ASK_MIN_OVERLAP * min(len(a), len(b)):
        return True
    return UPKEEP in shared and len(shared - {UPKEEP}) >= ASK_MIN_SHARED_UPKEEP


def lee_clauses(text):
    """Sentences of a typed message; a long run-on of dictated speech is cut into clauses."""
    for sentence in re.split(r"(?<=[.!?])\s+|\n+", text):
        if len(sentence) > MAX_ASK_LEN:
            yield from re.split(r",\s+|;\s+|\s+(?:and|but|so)\s+", sentence)
        else:
            yield sentence


def lee_instructions(records, worker):
    """Instruction clauses Lee typed in one transcript: (epoch, clause) in record order.
    A worker session's first prompt is firstmate's launch brief, which quotes Lee, so it is skipped."""
    out = []
    skip = worker
    stamped = any(isinstance(rec.get("origin"), dict) for rec in records)
    for rec in records:
        first = user_text(rec) if rec.get("type") == "user" else None
        if first is not None and skip:
            skip = False
            continue
        text = typed_text(rec, stamped) if first is not None else None
        if text is None:
            continue
        if MACHINE_PROMPT_RE.match(text) or BASH_INPUT_RE.match(text.strip()) or len(text) > 6000:
            continue
        for clause in lee_clauses(text):
            clause = clause.strip()
            if 12 <= len(clause) <= MAX_ASK_LEN and INSTRUCTION_RE.search(clause) and len(ask_tokens(clause)) >= ASK_MIN_SHARED:
                out.append((epoch_of(rec.get("timestamp")), clause))
    return out


def scan_asks(archive, date, days):
    """Lee's instruction sentences over the `days` days ending at <date>, from interactive and worker sessions."""
    out, seen = [], set()
    end = datetime.date.fromisoformat(date)
    window = {(end - datetime.timedelta(days=back)).isoformat() for back in range(days)}
    for day in sorted(window, reverse=True):
        manifest = triage.load_json(os.path.join(archive, "by-date", day, "manifest.json"))
        try:
            tz = zoneinfo.ZoneInfo((manifest or {}).get("timezone") or "UTC")
        except (zoneinfo.ZoneInfoNotFoundError, ValueError):
            tz = datetime.timezone.utc
        for entry in (manifest or {}).get("sessions") or []:
            if entry.get("harness") != "claude-code":
                continue
            folder = os.path.join(archive, entry.get("folder") or "")
            index = triage.load_json(os.path.join(folder, "index.json")) or {}
            kind = triage.classify(index.get("first_prompt") or "")
            if kind not in ("other", "worker"):
                continue
            records = records_of(os.path.join(folder, "transcript.jsonl.gz"))
            session = "%s:%s" % (entry.get("machine"), entry.get("session_id") or entry.get("name"))
            for at, sentence in lee_instructions(records or [], kind == "worker"):
                said = datetime.datetime.fromtimestamp(at, tz).date().isoformat() if at is not None else day
                if said not in window or (session, at, sentence) in seen:
                    continue
                seen.add((session, at, sentence))
                out.append({"date": said, "at": at, "session": session, "text": scrub(sentence, MAX_ASK_LEN)})
    return sorted(out, key=lambda a: (a["date"], a["at"] or 0, a["session"], a["text"]))


def repeat_ask_events(asks, date):
    """One event per instruction Lee gave on two or more days, when one of them is <date>."""
    toks = [ask_tokens(a["text"]) for a in asks]
    parent = list(range(len(asks)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(asks)):
        for j in range(i + 1, len(asks)):
            if asks[i]["date"] != asks[j]["date"] and same_ask(toks[i], toks[j]):
                parent[find(j)] = find(i)
    groups = {}
    for i in range(len(asks)):
        groups.setdefault(find(i), []).append(i)
    events = []
    for members in groups.values():
        days = sorted({asks[i]["date"] for i in members})
        if len(days) < 2 or date not in days:
            continue
        common = frozenset.intersection(*(toks[i] for i in members))
        first = {}
        for i in members:
            first.setdefault(asks[i]["date"], asks[i])
        topic = " ".join(sorted(common)[:6]) or " ".join(sorted(toks[members[0]])[:6])
        quotes = [{"date": d, "session": first[d]["session"], "quote": first[d]["text"]} for d in days]
        events.append({"kind": "repeat-ask", "at": max(a["at"] or 0 for a in (asks[i] for i in members)) or None,
                       "cause": "repeat-ask", "sub": "instruction", "lee": True, "service": None, "tool": None,
                       "signature": "%d days: %s" % (len(days), quotes[-1]["quote"]), "topic": topic, "asks": quotes,
                       "wait_s": None, "measured_by": None})
    return sorted(events, key=lambda e: (e["topic"], e["signature"]))


def scan(archive, date, days=1):
    """Per-session friction facts for one archive day; reads only the archive."""
    manifest = triage.load_json(os.path.join(archive, "by-date", date, "manifest.json"))
    out = {"date": date, "manifest": manifest is not None, "sessions": [], "not_analysed": {},
           "not_collected": {}, "harvester_last_run": triage.harvester_last_run(archive),
           "lee_asks": scan_asks(archive, date, days)}
    if manifest is None:
        return out
    out["not_collected"] = manifest.get("not_collected") or {}
    for entry in manifest.get("sessions") or []:
        harness = entry.get("harness")
        if harness in ("firstmate", "no-mistakes"):
            continue
        folder = os.path.join(archive, entry.get("folder") or "")
        transcript = os.path.join(folder, "transcript.jsonl.gz")
        records = records_of(transcript) if harness == "claude-code" else None
        if records is None:
            out["not_analysed"][harness or "unknown"] = out["not_analysed"].get(harness or "unknown", 0) + 1
            continue
        index = triage.load_json(os.path.join(folder, "index.json")) or {}
        facts = triage.analyse_transcript(transcript) or {}
        machine = entry.get("machine")
        out["sessions"].append({
            "session": "%s:%s" % (machine, entry.get("session_id") or entry.get("name")),
            "machine": machine,
            "cwd": entry.get("cwd"),
            "class": triage.classify(index.get("first_prompt") or ""),
            "join": facts.get("join"),
            "traces": facts.get("traces") or [],
            "events": session_events(records, machine),
        })
    out["sessions"].sort(key=lambda s: s["session"])
    return out


def remote_program():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "fm-officer-triage.py"), encoding="utf-8") as fh:
        triage_src = fh.read()
    with open(os.path.abspath(__file__), encoding="utf-8") as fh:
        friction_src = fh.read()
    prelude = ("import sys, types\n_m = types.ModuleType('fm_officer_triage')\n"
               "exec(compile(%r, 'fm-officer-triage.py', 'exec'), _m.__dict__)\n"
               "sys.modules['fm_officer_triage'] = _m\n" % triage_src)
    return (prelude + friction_src).encode("utf-8")


def remote_scan(host, archive, date, days):
    proc = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host,
         "python3 -I - scan --archive %s --date %s --days %d" % (triage.shell_quote(archive), date, days)],
        input=remote_program(), capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError("archive host %s unreachable or scan failed (ssh exit %d)"
                           % (host, proc.returncode))
    return json.loads(proc.stdout.decode("utf-8"))


BOSUN_RESULT = "~/services/bosun-maintenance/last-result.json"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]*$")
# Session logs and transcripts are always kept (fleet rules section 6): a file or log item under them is only ever answered keep.
SESSION_LOG_RE = re.compile(r"\.jsonl(?:\.gz)?$|/\.(?:claude|codex|pi|omp|kimi)(?:/|$)|/transcript-archive(?:/|$)|/herdr(?:/|$)")
BRANCH_ITEM_RE = re.compile(r"^(/.+) (\S+) \((local|remote)\)$")
COPY_BRANCH_RE = re.compile(r"^branch (\S+) is not merged and its pull request is missing or unreadable$")
BRANCH_RULE = "fleet rules section 6, unmerged-branch rule (%s)"
COPY_RULE = "fleet rules section 6, rule c (%s)"
SESSION_LOG_RULE = "fleet rules section 6 (Agent session logs and transcripts are always kept, because they are training data)"


def _read(cmd, cwd, env=None):
    """stdout of a read-only command, or None when it fails."""
    try:
        proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout.strip() if proc.returncode == 0 else None


def _on_default(sha, cwd):
    """True when sha is an ancestor of origin/HEAD, False when it is not, None when that cannot be read."""
    if not sha:
        return None
    try:
        proc = subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/HEAD"], cwd=cwd,
                              capture_output=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return {0: True, 1: False}.get(proc.returncode)


def _pull_requests(cwd, branch):
    out = _read(["gh", "pr", "list", "--head=" + branch, "--state", "all", "--limit", "30",
                 "--json", "number,state,headRefOid,url"], cwd)
    try:
        prs = json.loads(out) if out is not None else None
    except ValueError:
        return None
    return prs if isinstance(prs, list) else None


def _checkout_of(copy):
    """The git checkout of a copy, as the Bosun resolves it (fleet-app src/bosun/cleanup.ts checkoutOf): the copy itself
    when it has a .git, else its single child that has one; None when there are none, several, or the copy cannot be listed."""
    if os.path.exists(os.path.join(copy, ".git")):
        return copy
    try:
        found = [p for p in (os.path.join(copy, n) for n in sorted(os.listdir(copy))) if os.path.exists(os.path.join(p, ".git"))]
    except OSError:
        return None
    return found[0] if len(found) == 1 else None


def bosun_probe(entry):
    """The live facts one rule-settles item needs, read on the host with read-only git and gh."""
    kind, item, why = entry["kind"], entry["item"], entry["why"]
    m = BRANCH_ITEM_RE.match(item) if kind == "branch" else None
    if m and os.path.isdir(m.group(1)):
        repo, branch, where = m.groups()
        ref = ("refs/heads/" if where == "local" else "refs/remotes/origin/") + branch
        sha = _read(["git", "rev-parse", "--verify", "-q", ref], repo)
        return {"sha": sha, "prs": _pull_requests(repo, branch), "on_default": _on_default(sha, repo)}
    m = COPY_BRANCH_RE.match(why) if kind == "copy" else None
    root = _checkout_of(item) if m and os.path.isdir(item) else None
    if root:
        sha = _read(["git", "rev-parse", "HEAD"], root)
        status = _read(["git", "status", "--porcelain"], root, dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
        return {"sha": sha, "prs": _pull_requests(root, m.group(1)), "on_default": _on_default(sha, root),
                "dirty": None if status is None else bool(status)}
    return None


def bosun_read():
    """Runs on a Bosun host: the unsure list of its last result, with the live facts of each rule-settles item."""
    with open(os.path.expanduser(BOSUN_RESULT), encoding="utf-8") as fh:
        result = json.load(fh)
    unsure = [u for u in result.get("unsure") or []
              if isinstance(u, dict) and all(isinstance(u.get(k), str) for k in ("kind", "item", "why"))]
    return {"date": result.get("date"), "unsure": unsure,
            "facts": [bosun_probe(u) if u.get("bucket") == "rule-settles" else None for u in unsure]}


def remote_bosun(host):
    proc = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, "python3 -I - bosun-read"],
        input=remote_program(), capture_output=True, check=False)
    try:
        if proc.returncode != 0:
            raise ValueError
        read = json.loads(proc.stdout.decode("utf-8"))
        if not (isinstance(read["unsure"], list) and len(read["facts"]) == len(read["unsure"])):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise RuntimeError("Bosun host %s unreachable or its last result unreadable (ssh exit %d), so its unsure"
                           " items are not answered." % (host, proc.returncode))
    return read


def bosun_decide(entry, facts):
    """(answer, None) for one rule-settles item, or (None, why it is unsettled)."""
    kind, item, why = entry["kind"], entry["item"], entry["why"]
    if kind == "branch" and BRANCH_ITEM_RE.match(item):
        rule = BRANCH_RULE
    elif kind == "copy" and COPY_BRANCH_RE.match(why):
        rule = COPY_RULE
    elif kind not in ("branch", "copy") and SESSION_LOG_RE.search(item):
        return {"kind": kind, "item": item, "verdict": "keep", "rule": SESSION_LOG_RULE,
                "fact": "its path is a session log or transcript"}, None
    else:
        return None, "no rule settles it from facts the officer reads: " + why
    sha = (facts or {}).get("sha")
    prs = (facts or {}).get("prs")
    if not (isinstance(sha, str) and SHA_RE.match(sha)) or not isinstance(prs, list):
        return None, "its commit or pull requests could not be read now"
    short = sha[:7]
    opened = next((p for p in prs if isinstance(p, dict) and p.get("state") == "OPEN"), None)
    ended = next((p for p in prs if isinstance(p, dict) and p.get("headRefOid") == sha
                  and p.get("state") in ("MERGED", "CLOSED")), None)
    if opened:
        verdict, why_rule, fact = "keep", "never while an open pull request uses it", "pull request %s is open, read live" % opened.get("url")
    elif ended:
        verdict, why_rule = "delete", "pull request merged or closed"
        fact = "pull request %s %s at %s, read live" % (ended.get("url"), ended["state"].lower(), short)
    elif facts.get("on_default") is None:
        return None, "whether it is on the default branch could not be read now"
    elif facts["on_default"]:
        verdict, why_rule = "delete", "content already on the default branch"
        fact = "%s is an ancestor of origin/HEAD, read live" % short
    else:
        verdict, why_rule = "keep", "unique unlanded work is never deleted"
        fact = "no pull request ended at %s (%d found, read live) and it is not an ancestor of origin/HEAD" % (short, len(prs))
    if verdict == "delete" and rule is COPY_RULE:
        if facts.get("dirty") is None:
            return None, "its working state (git status) could not be read now"
        if facts["dirty"]:
            verdict, why_rule = "keep", "unique unlanded work is never deleted"
            fact = ("git status --porcelain lists uncommitted or untracked work in it, read live "
                    "(git-ignored files excluded, as in the Bosun's rule c check, fleet-app src/bosun/cleanup.ts)")
    return {"kind": kind, "item": item, "sha": sha, "verdict": verdict, "rule": rule % why_rule, "fact": fact}, None


def bosun_section(hosts):
    """The bosun-unsure class: answers, unsettled items and coverage gaps for each host's last result."""
    out = {"hosts": [], "answers": [], "unsettled": [], "gaps": []}
    for host in hosts:
        try:
            read = remote_bosun(host)
        except RuntimeError as exc:
            out["gaps"].append(str(exc))
            continue
        row = {"host": host, "result_date": read["date"], "unsure": len(read["unsure"]),
               "answered": 0, "unreadable": 0, "no_bucket": 0, "unsettled": 0}
        for entry, facts in zip(read["unsure"], read["facts"]):
            bucket = entry.get("bucket")
            if bucket == "unreadable":
                row["unreadable"] += 1
            elif bucket != "rule-settles":
                row["no_bucket"] += 1
            else:
                answer, reason = bosun_decide(entry, facts)
                if answer:
                    row["answered"] += 1
                    out["answers"].append(dict(answer, host=host, result_date=read["date"]))
                else:
                    row["unsettled"] += 1
                    out["unsettled"].append({"host": host, "kind": entry["kind"], "item": entry["item"], "reason": reason})
        out["hosts"].append(row)
    key = lambda x: (x["host"], x["kind"], x["item"])
    out["answers"].sort(key=key)
    out["unsettled"].sort(key=key)
    return out


def parse_status_line(line):
    """(state, key, at, text, stated cause or None) of one status line, or None."""
    m = STATUS_RE.match(line.strip())
    if not m:
        return None
    markers = m.group(2)
    at = AT_RE.search(markers)
    key = KEY_RE.search(markers)
    cause = CAUSE_RE.search(markers)
    cause = cause.group(1) if cause and cause.group(1) in STATED_CAUSES else None
    return m.group(1), key.group(1) if key else None, int(at.group(1)) if at else None, m.group(3), cause


def status_streams(home):
    """Per task, its status lines in order as dicts, from the live log and the ledger."""
    streams = {}
    state = os.path.join(home.path, "state")
    try:
        names = sorted(os.listdir(state))
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".status") or name.startswith("."):
            continue
        task = name[:-len(".status")]
        try:
            with open(os.path.join(state, name), encoding="utf-8", errors="replace") as fh:
                lines = [l for l in fh if l.strip()]
        except OSError:
            continue
        for line in lines:
            parsed = parse_status_line(line)
            if parsed and parsed[2] is not None:
                state_word, key, at, text, cause = parsed
                streams.setdefault(task, []).append(
                    {"state": state_word, "key": key, "at": at, "text": text, "source": "status",
                     "stated": cause})
    for task, events in sorted(home.ledger.items()):
        seen = {(e["state"], e["key"], e["text"].strip()) for e in streams.get(task, [])}
        for rec in events:
            if rec.get("event") != "task.status" or not isinstance(rec.get("ts"), int):
                continue
            item = (rec.get("state"), rec.get("key"), (rec.get("text") or "").strip())
            if item in seen:
                continue
            seen.add(item)
            streams.setdefault(task, []).append(
                {"state": rec.get("state"), "key": rec.get("key"), "at": rec["ts"],
                 "text": (rec.get("text") or "").strip(), "source": "ledger",
                 "stated": rec.get("cause") if rec.get("cause") in STATED_CAUSES else None})
    for events in streams.values():
        events.sort(key=lambda e: e["at"])
    return streams


def host_names(home):
    """Names the home's own machine answers to: its directory name and this host's short name."""
    return {place(home.path), socket.gethostname().split(".")[0]}


def waits_stated(ev):
    """True when a blocked or needs-decision line states one of the known causes."""
    return ev["state"] in ("needs-decision", "blocked") and ev.get("stated") in STATED_CAUSES


def status_events(homes, date, channels):
    """Waits opened on <date>: one event per ask, re-asks of an open key marked and not re-measured."""
    start, end = day_bounds(date)
    out = []
    for home in homes:
        own = host_names(home)
        for task, stream in sorted(status_streams(home).items()):
            chains = {}     # key -> the asks since its last resolution
            for i, ev in enumerate(stream):
                if ev["state"] == "resolved":
                    chains.pop(ev["key"], None)
                    continue
                text = clean(ev["text"])
                cause, sub, pos = classify(text)
                if waits_stated(ev) and (cause, sub) == ("other", "other"):
                    cause, sub = STATED_CAUSES[ev["stated"]]
                names_lee = bool(LEE_RE.search(text))
                waits = ev["state"] in ("needs-decision", "blocked") or (ev["state"] == "paused" and names_lee)
                if not waits and cause != "environment":
                    continue
                chain = chains.setdefault(ev["key"], []) if ev["key"] and waits else []
                chain.append(ev)
                if not start <= ev["at"] < end:
                    continue
                answer = measured_by = answered_by = None
                if waits and len(chain) == 1:
                    if ev["key"]:
                        answer = next((e for e in stream[i + 1:] if e["state"] == "resolved"
                                       and e["key"] == ev["key"]), None)
                        measured_by = "resolved-key" if answer else None
                    else:
                        answer = next((e for e in stream[i + 1:] if e["at"] >= ev["at"]), None)
                        measured_by = "next-line" if answer else None
                    if answer and answer["state"] == "resolved":
                        answered_by = "lee" if LEE_RE.search(answer["text"]) else "firstmate"
                out.append({
                    "kind": "status-wait" if waits else "status-report", "home": home.path, "task": task,
                    "channel": task in channels,
                    "state": ev["state"], "key": ev["key"], "at": ev["at"], "source": ev["source"],
                    "reask": len(chain) > 1, "answered_at": answer["at"] if answer else None,
                    "wait_s": max(0, answer["at"] - ev["at"]) if answer else None,
                    "measured_by": measured_by, "answered_by": answered_by,
                    "lee": names_lee or answered_by == "lee",
                    "cause": cause, "sub": sub, "stated": ev.get("stated") if waits else None,
                    "service": service_of(text, pos, (cause, sub) == ("credential", "scope")), "tool": None,
                    "signature": scrub(text), "_chain": chain, "_own": own,
                })
    # A Lee step asked again because an ssh line to the home's own machine did not take.
    for ev in out:
        chain = ev.pop("_chain")
        own = ev.pop("_own")
        if len(chain) > 1 and any(m.group(1) in own for c in chain for m in SSH_HOST_RE.finditer(c["text"])):
            ev["cause"], ev["sub"] = "environment", "ssh-to-self"
    return collapse_relays(out)


def collapse_relays(events):
    """A channel log's copy of a keyed ask is a relay: it folds into a task log's copy of that key
    in any home. Two task logs, or two channel logs, are never merged."""
    copies = {}
    for ev in events:
        if ev["key"]:
            copies.setdefault(ev["key"], []).append(ev)
    drop = set()
    for evs in copies.values():
        if any(not e["channel"] for e in evs):
            drop.update(id(e) for e in evs if e["channel"])
    return [ev for ev in events if id(ev) not in drop]


def _hashed_card_id(task, key):
    text = re.sub(r"^-+", "", re.sub(r"[^a-z0-9-]", "-", "-".join(x for x in (task, key) if x).lower())) or "card"
    digest = hashlib.sha256(("%s\0%s" % (task, key or "")).encode("utf-8")).hexdigest()[:10]
    return "%s-%s" % (text[:53], digest)


def card_id(task, key):
    """The Captain's Log card id of a status line, as fleet-app's cardId() derives it."""
    m = HOLD_KEY_RE.match(key) if key is not None else None
    hold = task if key is None else (m.group(1) if m else None)
    if hold is not None:
        return hold if CARD_ID_RE.match(hold) else _hashed_card_id(hold, None)
    return _hashed_card_id(task, key)


def load_captains_log(source):
    """The cards fleet-app serves at GET <fleet-app>/api/captains-log; read-only."""
    proc = subprocess.run(["curl", "-fsS", "--max-time", "30", source], capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError("unreachable (curl exit %d)" % proc.returncode)
    try:
        state = json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        raise RuntimeError("unreadable (not JSON)")
    value = state.get("value") if isinstance(state, dict) else None
    cards = value.get("cards") if isinstance(value, dict) else None
    if not isinstance(cards, list):
        raise RuntimeError("unreadable (no card list)")
    return [c for c in cards if isinstance(c, dict)]


def card_events(cards, homes, date):
    """Cards asked on <date> that no status line in the homes accounts for: Lee steps seen only as cards."""
    start, end = day_bounds(date)
    known = set()
    for home in homes:
        for task, stream in status_streams(home).items():
            known.add(card_id(task, None))
            known.update(card_id(task, e["key"]) for e in stream if e["key"])
    out = []
    for card in cards:
        at = epoch_of(card.get("asked"))
        if at is None or not start <= at < end or card.get("id") in known:
            continue
        text = clean("%s %s" % (card.get("question") or "", card.get("advice") or ""))
        cause, sub, pos = classify(text)
        answer = card.get("answer") if isinstance(card.get("answer"), dict) else {}
        answered_at = epoch_of(answer.get("at"))
        out.append({"kind": "card-only", "at": at, "card": card.get("id"), "cause": cause, "sub": sub,
                    "lee": True, "service": service_of(text, pos, (cause, sub) == ("credential", "scope")), "tool": None,
                    "signature": scrub(card.get("question") or ""), "answered_at": answered_at,
                    "wait_s": max(0, answered_at - at) if answered_at is not None else None,
                    "measured_by": "card-answer" if answered_at is not None else None})
    return out


def wrong_cwd_events(scanned, homes):
    by_path = {h.path: h for h in homes}
    out = []
    for s in scanned["sessions"]:
        join = s.get("join") or {}
        if s["class"] != "worker" or join.get("via") != "launch-brief":
            continue
        home = by_path.get((join.get("home") or "").rstrip("/"))
        meta = (home.metas.get(join.get("task")) or {}) if home else {}
        worktree = (meta.get("worktree") or "").rstrip("/")
        cwd = (s.get("cwd") or "").rstrip("/")
        if worktree and cwd and cwd != worktree and not cwd.startswith(worktree + "/"):
            out.append({"kind": "session-cwd", "at": None, "cause": "environment", "sub": "wrong-cwd",
                        "lee": False, "service": None, "tool": None,
                        "signature": "worker started outside its task worktree"})
            s["events"].append(out[-1])
    return out


def all_events(scanned, homes, date, cards, channels):
    events = []
    wrong_cwd_events(scanned, homes)
    for s in scanned["sessions"]:
        join = s.get("join") or {}
        for ev in s["events"]:
            events.append(dict(ev, session=s["session"], machine=s["machine"], task=join.get("task"),
                               home=join.get("home")))
    events.extend(status_events(homes, date, channels))
    events.extend(card_events(cards, homes, date))
    events.extend(repeat_ask_events(scanned.get("lee_asks") or [], date))
    events.sort(key=lambda e: (e.get("at") or 0, e["kind"],
                               e.get("session") or e.get("task") or e.get("card") or "", e["signature"]))
    return events


def propose_fix(cause, sub, model):
    """The fix for a root cause: the FIXES table, or the later-slice model seam."""
    if (cause, sub) in FIXES:
        return FIXES[(cause, sub)]
    if model != "none":
        raise RuntimeError("model-written fixes are not available in slice 1 (model: %s)" % model)
    return None


def human_span(seconds):
    if seconds is None:
        return "not measured"
    if seconds < 3600:
        return "%d min" % max(1, round(seconds / 60))
    return "%.1f h" % (seconds / 3600.0)


def place(home_or_machine):
    return os.path.basename((home_or_machine or "").rstrip("/")) or "unknown"


def group_findings(events, model):
    groups = {}
    for ev in events:
        if ev["cause"] == "repeat-ask":
            name = ev["topic"]
        elif ev["cause"] == "missing-tool" or ev["sub"] == "refused":
            name = ev["tool"]
        else:
            name = ev.get("service") if ev["cause"] in ("credential", "service-limit") else None
        key = (ev["cause"], ev["sub"], name or "")
        groups.setdefault(key, []).append(ev)
    findings = []
    for (cause, sub, name), evs in sorted(groups.items()):
        lee = any(e["lee"] for e in evs)
        waits = sorted(e["wait_s"] for e in evs if e.get("wait_s") is not None)
        total = sum(waits) if waits else None
        places = {}
        for e in evs:
            p = place(e.get("machine") or e.get("home"))
            places[p] = places.get(p, 0) + 1
        machine = sorted(places.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
        severity = 2 + (1 if lee else 0) + (1 if total and total >= 3600 else 0) \
            + (1 if total and total >= 6 * 3600 else 0) + (1 if len(evs) >= 3 else 0)
        severity = max(1, min(5, severity))
        if any(e["kind"] in ("status-wait", "card-only") and e.get("wait_s") is not None for e in evs):
            confidence = 5
        elif any(e["kind"] == "lee-command" for e in evs):
            confidence = 4
        else:
            confidence = 3
        fix = None if cause == "missing-tool" and name in RETIRED_TOOLS else propose_fix(cause, sub, model)
        fill = {"service": name or "the service", "tool": name or "a tool", "machine": machine}
        tasks = sorted({e["task"] for e in evs if e.get("task") and not e.get("channel")})
        sessions = sorted({e["session"] for e in evs if e.get("session")})
        keys = sorted({"%s@%s" % (e["key"], iso_utc(e["at"])) for e in evs if e.get("key")})
        cards = sorted({e["card"] for e in evs if e.get("card")})
        carded = fix is not None and (cause, sub) not in NOT_CARDED \
            and severity >= MIN_SEVERITY and confidence >= MIN_CONFIDENCE
        finding = {
            "cause": cause, "sub": sub, "name": name or None, "lee_step": lee,
            "events": len(evs), "lee_events": sum(1 for e in evs if e["lee"]),
            "kinds": dict(sorted(_count(e["kind"] for e in evs).items())),
            "waits_measured": len(waits), "wait_total_s": total,
            "wait_median_s": waits[len(waits) // 2] if waits else None,
            "wait_max_s": waits[-1] if waits else None,
            "open": sum(1 for e in evs if (e["kind"] == "card-only" or e["kind"] == "status-wait"
                                           and not e["reask"]) and e.get("wait_s") is None),
            "reasks": sum(1 for e in evs if e.get("reask")),
            "stated_causes": dict(sorted(_count(e.get("stated") or "unstated"
                                                for e in evs if e["kind"] == "status-wait").items())),
            "severity": severity, "confidence": confidence, "carded": carded,
            "last_seen_at": max((e["at"] for e in evs if e.get("at")), default=None),
            "owner": None, "title": None, "lee_did": None, "fix": None, "effort": None,
            "category": CATEGORY.get(cause, "other"),
            "evidence": {"tasks": tasks, "sessions": sessions, "status_keys": keys, "cards": cards,
                         "example": sorted(e["signature"] for e in evs)[0],
                         "asks": [a for e in evs for a in e.get("asks") or []]},
            "where": dict(sorted(places.items())),
        }
        if fix:
            title, lee_did, improvement, owner, effort = (s.format(**fill) for s in fix)
            finding.update(title=title, lee_did=lee_did if lee else "nothing directly (agent-side friction)",
                           fix=improvement, owner=owner, effort=effort)
        findings.append(finding)
    name_shared_titles(findings)
    assign_ids(findings)
    findings.sort(key=lambda f: (not f["carded"], -(f["severity"] * f["confidence"]), -f["events"],
                                 f["cause"], f["sub"], f["name"] or ""))
    return findings


def name_shared_titles(findings):
    """Two findings of one run never share a title: a shared one gets its subject (the tool, hook, host or service)."""
    shared = {t for t, n in _count(f["title"] for f in findings if f["title"]).items() if n > 1}
    for f in findings:
        if f["title"] in shared and f["name"]:
            room = 90 - len(f["title"]) - 2
            f["title"] = "%s: %s" % (f["title"], clip(f["name"], max(room, 8)))


def assign_ids(findings):
    """A stable slug per finding, from its cause, sub and name alone, so it is the same every night.

    fleet-app keeps the slug within ID_MAX characters (its tap card is friction-<id>). A slug that is
    too long, or that another finding in the same run also reduces to, ends in a hash of the full key.
    """
    keys = [(f["cause"], f["sub"], f["name"] or "") for f in findings]
    slugs = [re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", "-".join(p for p in k if p).lower())).strip("-") or "finding"
             for k in keys]
    seen = _count(slugs)
    for f, key, slug in zip(findings, keys, slugs):
        if len(slug) > ID_MAX or seen[slug] > 1:
            digest = hashlib.sha256("\0".join(key).encode("utf-8")).hexdigest()[:8]
            slug = "%s-%s" % (slug[:ID_MAX - 9].strip("-"), digest)
        f["id"] = slug


def _count(items):
    out = {}
    for item in items:
        out[item] = out.get(item, 0) + 1
    return out


def clip(text, limit):
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"

STANDING_RE = re.compile(r"standing (?:rule|exception)", re.I)
PULL_URL_RE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+")
TASK_LINE_RE = re.compile(r"^\s*- \[[ xX]\] ([\w.-]+)")
MAX_NOTE_BYTES = 65536
REPLY_DAYS = 30


SETTLES_RE = re.compile(r"settles:\s*([a-z0-9-]+)/([a-z0-9-]+)(?:/([^\s,;)]+))?")


def settles(line, f, rx):
    """Whether a lowercased standing-rule line covers a finding: it names the id, or its key as settles: <cause>/<sub>.

    For a finding about one tool, hook or service the key also needs its name: settles: <cause>/<sub>/<name>,
    or the name elsewhere on the line.
    """
    if rx.search(line):
        return True
    name = (f["name"] or "").lower()
    for cause, sub, named in SETTLES_RE.findall(line):
        if (cause, sub) != (f["cause"], f["sub"]):
            continue
        if named.rstrip(".") == name if named else (not name or name in line):
            return True
    return False


def id_re(finding_id):
    """The finding id as a whole token, alone or as a tap card friction-<id>."""
    return re.compile(r"(?<![a-z0-9-])(?:friction-)?%s(?![a-z0-9-])" % re.escape(finding_id))


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(4 * 1024 * 1024).splitlines()
    except OSError:
        return []


def inbox_notes(home):
    """The text of every note in a home's inbox, waiting or handled; read-only."""
    inbox = os.path.join(home.path, "state", "inbox")
    out = []
    for folder in (inbox, os.path.join(inbox, "handled")):
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            continue
        for name in names:
            path = os.path.join(folder, name)
            try:
                if name.endswith(".note") and os.path.getsize(path) <= MAX_NOTE_BYTES:
                    out.append("\n".join(read_lines(path)))
            except OSError:
                continue
    return out


def task_link(home, task):
    """The newest pull request URL a task's status log names, or None."""
    for line in reversed(read_lines(os.path.join(home.path, "state", task + ".status"))):
        m = PULL_URL_RE.search(line)
        if m:
            return m.group(0)
    return None


def load_replies(captains_log, now):
    """The tap replies fleet-app serves beside the cards, GET <captains-log>/replies?since=<30 days ago>.

    Read-only and best effort; the 30 days reach past the page's own 3-day window, so a tap stays a start.
    """
    since = iso_utc(now - REPLY_DAYS * 86400)
    proc = subprocess.run(["curl", "-fsS", "--max-time", "30", "%s/replies?since=%s" % (captains_log.rstrip("/"), since)],
                          capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError("unreachable (curl exit %d)" % proc.returncode)
    try:
        body = json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        raise RuntimeError("unreadable (not JSON)")
    found = []

    def walk(node):
        if isinstance(node, list):
            found.extend(x for x in node if isinstance(x, dict) and isinstance(x.get("card"), str))
        elif isinstance(node, dict):
            for value in node.values():
                if isinstance(value, (list, dict)):
                    walk(value)
    walk(body)
    return found


def default_start_marker(finding_id):
    """The note body line a started-by-default request carries; finding_states reads it back as a start."""
    return "Friction finding [friction-%s]: started by default" % finding_id


def merge_index(homes):
    """({pull request URL: newest merge epoch}, {task: newest merge epoch}) from the homes' fleet ledgers."""
    by_pr, by_task = {}, {}
    for home in homes:
        for task, records in home.ledger.items():
            for rec in records:
                if rec.get("event") != "task.merged" or not isinstance(rec.get("ts"), int):
                    continue
                by_task[task] = max(by_task.get(task, 0), rec["ts"])
                if isinstance(rec.get("pr"), str):
                    by_pr[rec["pr"]] = max(by_pr.get(rec["pr"], 0), rec["ts"])
    return by_pr, by_task


def https_link(url):
    return url if url and url.startswith("https://") and len(url) <= 300 else None


def note_at(text):
    m = re.search(r"^at=(\S+)$", text, re.M)
    return epoch_of(m.group(1)) if m else None


def settled_by(f, rx, homes):
    """The first standing-rule line of a home's data/captain-shared.md that covers the finding, quoted with its source."""
    for home in homes:
        path = os.path.join(home.path, "data", "captain-shared.md")
        for number, line in enumerate(read_lines(path), 1):
            if STANDING_RE.search(line) and settles(line.lower(), f, rx):
                return {"text": clip(line.strip().lstrip("-* ").strip(), 300),
                        "source": clip("%s data/captain-shared.md line %d" % (place(home.path), number), 120)}
    return None


def finding_states(findings, homes, replies, date="1970-01-01", eligible=()):
    """{finding id: state record}: what the velocity page draws for each finding, as of the run.

    A record holds state (one of STATES), link (a pull request or https URL), task (the task that holds the fix),
    reopen (a started finding that names neither), rule ({text, source} of the standing-rule line, for settled),
    fixed ({link, merged_at}, for fixed and reported-again), generation (the merged fix link a later start follows)
    and actions (STATE_ACTIONS). Order of precedence:

      settled           a standing-rule line in a home's data/captain-shared.md names the finding id or key;
      started           a Start fix tap (in a home's state/inbox or the Captain's Log replies), a started-by-default
                        note, a data/backlog.md line or a task's branch= names it, and that fix has not merged. Its
                        link is the first pull request or https URL those hold, its task the backlog line's or branch's
                        task; with neither, reopen is true;
      fixed             the started fix merged (a task.merged record in a fleet ledger, by the task or its pull request)
                        and the finding was not seen again after the merge;
      reported-again    the fix merged and the finding has an event after the merge (last_seen_at; the start of the run's
                        day when the finding carries no stamped event), with no newer start;
      started-by-default  the finding is in `eligible` (a carded standing-work group; see STANDING_START), nothing
                        started it (or it was reported again after a merged fix), and Lee did not Object;
      open              anything else.

    A start is current unless it merged. A tap or note is also not current when a merge is known and it is no newer
    than the merge (one with no stamp is then older); a backlog line or branch is judged by its own task's merge. An `Object` tap (inbox note or reply) on a finding keeps it from starting by default.
    """
    day_start, _ = day_bounds(date)
    notes = [(t.lower(), note_at(t)) for h in homes for t in inbox_notes(h)]
    backlog = [(h, l) for h in homes for l in read_lines(os.path.join(h.path, "data", "backlog.md"))]
    by_pr, by_task = merge_index(homes)
    out = {}
    for f in findings:
        rx = id_re(f["id"])
        rule = settled_by(f, rx, homes)
        if rule:
            out[f["id"]] = {"state": "settled", "link": None, "task": None, "reopen": False, "rule": rule,
                            "fixed": None, "generation": None, "actions": STATE_ACTIONS["settled"]}
            continue
        hits = []   # {"link", "task", "at"}: one per start found
        objected = False
        escaped = re.escape(f["id"])
        tap = re.compile(r"captain's log reply \[friction-%s\]: start fix" % escaped)
        default = re.compile(re.escape(default_start_marker(f["id"]).lower()))
        objection = re.compile(r"captain's log reply \[friction-%s\]: object" % escaped)
        for text, at in notes:
            if tap.search(text) or default.search(text):
                hits.append({"link": None, "task": None, "at": at})
            if objection.search(text):
                objected = True
        for reply in replies:
            if reply["card"] != "friction-" + f["id"]:
                continue
            said = str(reply.get("text") or "").lower()
            if said.startswith("object"):
                objected = True
            if said.startswith("start fix"):
                answer = reply.get("answer") if isinstance(reply.get("answer"), dict) else {}
                urls = re.findall(r"https://[^\s\"\\]+", json.dumps(reply.get("answer") or ""))
                hits.append({"link": urls[0].rstrip(".,)") if urls else None, "task": None,
                             "at": epoch_of(answer.get("at"))})
        for home, line in backlog:
            if rx.search(line.lower()):
                m = TASK_LINE_RE.match(line)
                url = URL_RE.search(line)
                task = m.group(1) if m else None
                hits.append({"link": url.group(0).rstrip(".,)") if url else (task_link(home, task) if task else None),
                             "task": task, "at": None,
                             "tracked": bool(task or (url and PULL_URL_RE.match(url.group(0))))})
        for home in homes:
            for task, meta in sorted(home.metas.items()):
                if rx.search((meta.get("branch") or "").lower()):
                    hits.append({"link": task_link(home, task), "task": task, "at": None, "tracked": True})
        for hit in hits:
            hit["link"] = https_link(hit["link"])
            stamps = [by_pr[hit["link"]]] if hit["link"] in by_pr else []
            stamps += [by_task[hit["task"]]] if hit["task"] in by_task else []
            hit["merged"] = max(stamps) if stamps else None
        latest = max((h["merged"] for h in hits if h["merged"]), default=None)
        current = [h for h in hits if not h["merged"]
                   and (h.get("tracked") or not (latest and (h["at"] is None or h["at"] <= latest)))]
        rec = {"state": "open", "link": None, "task": None, "reopen": False, "rule": None, "fixed": None,
               "generation": None}
        if current:
            rec.update(state="started", link=next((h["link"] for h in current if h["link"]), None),
                       task=next((h["task"] for h in current if h["task"]), None))
            rec["reopen"] = not rec["link"] and not rec["task"]
        elif latest:
            merged = max((h for h in hits if h["merged"]), key=lambda h: h["merged"])
            seen = f.get("last_seen_at") or day_start
            rec.update(state="reported-again" if seen > latest else "fixed",
                       fixed={"link": merged["link"], "merged_at": iso_utc(latest)},
                       task=merged["task"], generation=merged["link"] or merged["task"] or "merged")
        if rec["state"] in ("open", "reported-again") and f["id"] in eligible and not objected:
            rec["state"] = "started-by-default"
        rec["actions"] = ["reopen"] if rec["reopen"] else STATE_ACTIONS[rec["state"]]
        out[f["id"]] = rec
    return out


def bottleneck(f, date):
    ev = f["evidence"]
    parts = ["%d event(s) on %s" % (f["events"], date)]
    if ev["tasks"]:
        parts.append("tasks " + ", ".join(ev["tasks"][:4]))
    if ev["status_keys"]:
        parts.append("status " + ", ".join(ev["status_keys"][:3]))
    if ev["cards"]:
        parts.append("cards " + ", ".join(ev["cards"][:3]))
    if ev["sessions"]:
        parts.append("sessions " + ", ".join(s.split(":")[0] + ":" + s.split(":")[-1][:8]
                                             for s in ev["sessions"][:3]))
    parts.append("e.g. " + ev["example"])
    if ev["asks"]:
        parts.append("asked " + "; ".join('%s "%s"' % (a["date"], clip(a["quote"], 60)) for a in ev["asks"][:4]))
    if f["wait_total_s"] is not None:
        saved = "about %s a day: %d measured wait(s) on %s totalling %s, from ask to answer" % (
            human_span(f["wait_total_s"]), f["waits_measured"], date, human_span(f["wait_total_s"]))
    else:
        saved = "not measured: %d step(s) on %s with no recorded answer time" % (f["events"], date)
    return {
        "title": clip(f["title"], 90),
        "tldr": clip(("%s: " % f["name"] if f["name"] else "") + ("Lee had to %s: %d time(s) on %s; agents waited %s." % (
            f["lee_did"], f["lee_events"], date, human_span(f["wait_total_s"]))) if f["lee_step"] else (
            "Agents hit this %d time(s) on %s and worked around it." % (f["events"], date)), 180),
        "category": f["category"],
        "severity": f["severity"],
        "confidence": f["confidence"],
        "evidence": clip("; ".join(parts), 400),
        "improvement": clip(f["fix"], 400),
        "impact": clip("Removes %d Lee step(s) and %s of agent waiting seen on %s." % (
            f["lee_events"], human_span(f["wait_total_s"]), date), 250),
        "effort": f["effort"],
        "owner": clip(f["owner"], 60),
        "time_saved": clip(saved, 200),
        "id": f["id"],
        "events": f["events"],
    }


def velocity_doc(doc, now, states=None):
    start, end = day_bounds(doc["date"])
    # findings are sorted carded first, so the cap drops the least important
    cards = [bottleneck(f, doc["date"]) for f in card_findings(doc)]
    for card in cards:
        rec = (states or {}).get(card["id"]) or {"state": "open", "link": None, "task": None, "reopen": False,
                                                 "rule": None, "fixed": None, "actions": STATE_ACTIONS["open"]}
        card["state"] = rec["state"]
        card["actions"] = list(rec["actions"])
        for field in ("link", "task", "rule", "fixed"):
            if rec.get(field):
                card[field] = rec[field]
        if rec.get("reopen"):
            card["reopen"] = True
        if rec.get("request_id"):
            card["request_id"] = rec["request_id"]
    cov = doc["coverage"]
    notes = [clip(n, 400) for n in cov["notes"]][:12]
    evidence = [{"name": "session archive", "state": "read", "detail": clip(
        "%d session(s) analysed; harvester last ran %s" % (cov["sessions_analysed"],
                                                          cov["harvester_last_run"] or "never"), 400)}]
    for home in cov["homes"][:10]:
        evidence.append({"name": clip("status logs " + place(home["path"]), 40), "state": "read",
                         "detail": clip("%d task log(s); fleet ledger %s" % (
                             home["status_logs"], "read" if home["ledger"] else "absent"), 400)})
    log = cov["captains_log"]
    if log["state"] == "read":
        detail = "%d card(s) read; %d asked on %s with no status line counted" % (
            log["cards"], log["card_only"], doc["date"])
    elif log["state"] == "unreachable":
        detail = "Not read: the endpoint is %s; counted from status logs only." % log["reason"]
    else:
        detail = "Not read: the registry line sets no captains-log URL; counted from status logs only."
    evidence.append({"name": "Captain's Log", "state": "read" if log["state"] == "read" else "missing",
                     "detail": clip(detail, 400)})
    return {
        "schema_version": 1,
        "source": "friction-officer",
        "run_id": "friction-" + doc["date"].replace("-", ""),
        "generated_at": iso_utc(now),
        "window": {"from": iso_utc(start), "to": iso_utc(end)},
        "outcome": "ok" if doc["events"] else "no-data",
        "summary": clip("%d friction event(s), %d naming Lee; %d finding(s), %d carded." % (
            len(doc["events"]), sum(1 for e in doc["events"] if e["lee"]), len(doc["findings"]),
            sum(1 for f in doc["findings"] if f["carded"])), 300),
        "notes": notes,
        "cost_usd": 0,
        "evidence": evidence[:12],
        "bottlenecks": cards,
        "totals": {"events": len(doc["events"]), "findings": len(doc["findings"])},
    }


def card_findings(doc):
    """The findings the velocity file carries as cards, in its order and within its cap."""
    return [f for f in doc["findings"]
            if f["title"] and f["fix"] and (f["cause"], f["sub"]) not in NOT_CARDED][:MAX_CARDS]


def _lib():
    """The shared Linear filing library, loaded where findings are filed (the archive host never has it)."""
    mod = sys.modules.get("fm_officer_linear")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-linear.py")
        spec = importlib.util.spec_from_file_location("fm_officer_linear", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["fm_officer_linear"] = mod
    return mod


def officer(lib):
    """The friction officer as the contract (docs/officers/contract.md) knows it: Fleet work, standing-work causes may start."""
    return lib.Officer("friction", "Friction officer", "Friction officer", RUBRIC_FILE, START_SOURCES,
                       severities=("high", "critical"), project=lib.FLEET_PROJECT)


def source_label(path, gaps):
    """The Source label the rubric names (docs/officers/friction-rubric.md `source-label`), else "agent"."""
    try:
        with open(path, encoding="utf-8") as fh:
            body = fh.read().partition("## Settings the code reads")[2]
    except OSError:
        return DEFAULT_SOURCE_LABEL
    m = re.search(r"^- source-label: *(\S+) *$", body, re.M)
    if m and m.group(1).lower() not in SOURCE_LABELS:
        gaps.append("rubric source-label names %s, which is not one of Lee's Source labels; using %s" % (m.group(1), DEFAULT_SOURCE_LABEL))
    return m.group(1).lower() if m and m.group(1).lower() in SOURCE_LABELS else DEFAULT_SOURCE_LABEL


def lib_findings(lib, doc, states, eligible):
    """One shared-library finding per friction finding (docs/officers/friction-rubric.md scores it).

    A card-bar finding is high, an uncarded one of severity 3 or more medium, the rest low. A product choice is a
    decision and a retired tool a won't fix; neither is filed. Only an `eligible` finding that is still
    started-by-default carries the start wording, so only those can start.
    """
    out = []
    for f in doc["findings"]:
        state = states[f["id"]]
        klass = "decision" if (f["cause"], f["sub"]) in NOT_CARDED else \
            "wont-fix" if f["cause"] == "missing-tool" and f["name"] in RETIRED_TOOLS else "real"
        title = f["title"] or "%s / %s%s (no rule names a fix)" % (f["cause"], f["sub"], " / " + f["name"] if f["name"] else "")
        summary = "%d event(s), %d naming Lee, agents waited %s. %s" % (
            f["events"], f["lee_events"], human_span(f["wait_total_s"]), f["fix"] or "No fix proposed yet.")
        lf = lib.make_finding(f["cause"], f["sub"], "/".join((f["cause"], f["sub"], f["name"] or "")), title, summary, klass,
                              "high" if f["carded"] else "medium" if f["severity"] >= 3 else "low",
                              state["state"] in ("settled", "started", "fixed"), {}, fix=f["fix"] or "")
        lf.update(id=f["id"], raw=f, start=False)
        if f["id"] in eligible and state["state"] == "started-by-default":
            lf.update(start=True, start_generation=state["generation"] or "", start_what=(
                "%s: %s. Start this fix without a Start fix tap or another approval question, under fleet rules section 2 "
                "('Velocity findings go ahead by default: an agent starts the fix unless Lee objects within a day'); Lee may "
                "Object. Name friction-%s in the task's branch or its data/backlog.md line, so the friction officer can read its "
                "merge back. Loosening a guard or gate check is outside this authority; if Lee objects, preserve the branch."
                % (default_start_marker(f["id"]), title, f["id"])),
                start_row={"friction_id": f["id"], "card": bottleneck(f, doc["date"])})
        out.append(lf)
    return out


def description(lf, date, off, near=None, recurrence=None):
    """The Linear item body. It holds counts and identifiers only: no transcript line, command or quoted ask goes to Linear."""
    f = lf["raw"]
    lines = ["Filed by the friction officer from the %s friction events." % date,
             "What it is for: a step that slowed agents down, fixed once so it is not hit again.",
             "Epic: not assigned; whoever triages this picks one.", "",
             "Severity: %s (friction severity %d, confidence %d). Root cause: %s / %s%s." % (
                 lf["severity"], f["severity"], f["confidence"], f["cause"], f["sub"], ", " + f["name"] if f["name"] else ""),
             off.found_line(1, date, date)]
    if recurrence:
        lines.append(recurrence)
    if near:
        lines.append("Near match (not treated as the same issue): %s, local-jev %.2f." % near)
    lines += ["What Lee had to do: %s." % (f["lee_did"] or "not stated"),
              "Events on %s: %d, %d naming Lee; %d wait(s) measured, total %s; %d still open; %d re-ask(s)." % (
                  date, f["events"], f["lee_events"], f["waits_measured"], human_span(f["wait_total_s"]), f["open"], f["reasks"]),
              "Proposed fix: %s" % (f["fix"] or "none yet"),
              "Owner: %s; effort %s." % (f["owner"] or "not stated", f["effort"] or "not stated")]
    ev = f["evidence"]
    for label, items in (("Tasks", ev["tasks"]), ("Status keys", ev["status_keys"]), ("Cards", ev["cards"])):
        if items:
            lines.append("%s: %s" % (label, ", ".join(items[:6])))
    # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
    return "\n".join(lines) + "\n%s:%s" % (off.marker, lf["fingerprint"])


def file_findings(lib, off, findings, args, date, out, ledger, found, jev, lin, source):
    """Files the real, untracked findings, highest score first; returns (writes done, why Linear stopped or None)."""
    todo = [f for f in findings if f["class"] == "real" and not f["tracked"]]
    filer = lib.Filer(off, lin, args.team, date, out, ledger, found, jev, args.max_creates)

    def stop(reason, rate_limited=False):
        for f in todo:
            f["filing"] = f["filing"] or {"action": "not-filed", "reason": reason}
        if rate_limited:
            lib.pause_for_rate_limit(out, args.now)
        return lib.summary_rows(todo), reason

    for f in todo:
        if f["fingerprint"] in ledger:
            f["filing"], f["issue_hint"] = {"action": "exists", "issue": ledger[f["fingerprint"]]}, ledger[f["fingerprint"]]
            filer.bumps.append(f)
    due = [f for f in filer.bumps if found.get("issues", {}).get(f["filing"]["issue"], {}).get("last") != date]
    if not any(not f["filing"] for f in todo) and not due:
        return lib.summary_rows(todo), None
    stopped = lib.paused_until(out, args.now)
    if stopped:
        return stop(stopped)
    try:
        names = lib.label_names(lin, args.team)
    except lib.LinearError as exc:
        return stop("label lookup failed: %s" % exc, exc.code == "RATE_LIMITED")

    def label_set(f):
        wanted = [TYPE_LABEL, source, lib.FLEET_AREA]
        return wanted, [w for w in wanted if w.lower() not in names]

    def describe(f, near=None, recurrence=None):
        return description(f, date, off, near, recurrence)

    try:
        for f in todo:
            if not f["filing"]:
                filer.file_single(f, label_set, describe)
        filer.settle_bumps(label_set, describe)
    except lib.LinearError as exc:
        if exc.code == "RATE_LIMITED":
            return stop("Linear rate limit reached: %s" % exc, True)
        return stop("%s; the next run continues from the ledger" % exc)
    return lib.summary_rows(todo), None


def linear_pass(doc, states, eligible, args, offices, main_home):
    """Files every finding in Linear (writes: linear) and hands the standing-work ones to the owning office.

    Mutates `states` (a finding whose request could not be written is no longer started by default; a request
    names its id) and returns the digest fields. A start needs the finding's Linear item, so without writes: linear
    nothing starts by default and the card offers Start fix. A reserved class (docs/officers/contract.md) is held.
    """
    lib = _lib()
    off = officer(lib)
    out, date, linear = args.out, doc["date"], args.writes == "linear"
    lin = lib.Linear(args.max_linear_calls)
    state = lib.read_json(os.path.join(out, lib.STATE_FILE), {})
    found = lib.read_json(os.path.join(out, lib.FOUND_FILE), {})
    ledger = lib.read_json(os.path.join(out, lib.LEDGER_FILE), {})
    findings = lib_findings(lib, doc, states, eligible)
    rubric = lib.load_rubric(args.rubric, off)
    jev = lib.Jev(args.jev)
    label_gaps = []
    source = source_label(args.rubric, label_gaps)
    lib.apply_found(findings, found, ledger)
    writes, blocked = file_findings(lib, off, findings, args, date, out, ledger, found, jev, lin, source) if linear else ([], None)
    lib.apply_found(findings, found, ledger)
    # Only a hold is remembered across nights (it asks Lee once). A start is repeated until its delivered note reads back
    # as started (finding_states), so an office that missed one still gets it.
    handled = state.setdefault("handled", {})
    candidates = [f for f in findings if f["start"]]
    starts, held, asks = lib.plan_starts(off, candidates, rubric, date, args.writes, main_home, offices, handled)
    by_fp = {f["fingerprint"]: f for f in candidates}
    for rank, row in enumerate(starts, 1):
        f = by_fp[row["fingerprint"]]
        handled.pop(row["issue"], None)
        row.update(id=f["id"], rank=rank, generation=f["start_generation"] or None, owner_home=row["execute"]["env"]["FM_HOME"])
        states[f["id"]]["request_id"] = row["execute"]["request_id"]
    started_fps = {r["fingerprint"] for r in starts}
    unstarted = 0
    for f in candidates:
        if f["fingerprint"] in started_fps:
            continue
        rec = states[f["id"]]
        rec["state"] = "reported-again" if rec.get("fixed") else "open"
        rec["actions"] = STATE_ACTIONS[rec["state"]]
        unstarted += 1
    gaps = rubric.gaps + label_gaps + ([jev.gap] if jev.gap and linear else [])
    if unstarted:
        gaps.append("%d finding(s) due to start by default were not started because %s; each card offers Start fix." % (
            unstarted, "its Linear item was not filed or it is held for Lee (see Linear)" if linear else "the run writes no Linear items (set writes: linear)"))
    if linear:
        lib.write_json(os.path.join(out, lib.LEDGER_FILE), ledger)
        lib.write_json(os.path.join(out, lib.STATE_FILE), state)
        lib.write_json(os.path.join(out, lib.FOUND_FILE), found)
    for lf in findings:
        lf["raw"]["linear"] = {"class": lf["class"], "severity": lf["severity"], "found": lf["found"], "score": lf["score"],
                               **{k: v for k, v in (lf["filing"] or {}).items() if k in ("action", "issue", "reason", "found", "recurrence_of")}}
    return {"writes": args.writes, "writes_done": writes, "writes_blocked": blocked, "linear_calls": lin.n,
            "linear_call_budget": lin.budget, "linear_gaps": gaps, "not_filed": lib.not_filed_lines(findings),
            "held": held, "asks_for_lee": asks}, starts


def coverage(scanned, homes, hosts, log):
    present = sorted({s["machine"] for s in scanned["sessions"] if s.get("machine")})
    home_rows = []
    notes = []
    for home in homes:
        logs = 0
        try:
            logs = sum(1 for n in os.listdir(os.path.join(home.path, "state")) if n.endswith(".status"))
        except OSError:
            pass
        ledger = os.path.exists(os.path.join(home.path, "state", "fleet-ledger.jsonl"))
        home_rows.append({"path": home.path, "status_logs": logs, "ledger": ledger})
        if not ledger:
            notes.append("Home %s keeps no fleet ledger, so status lines of tasks already cleaned up there"
                         " are not read." % place(home.path))
    for host in hosts:
        if host not in present:
            notes.append("No archived sessions from expected host %s." % host)
    for host in sorted(scanned.get("not_collected") or {}):
        notes.append("The archive did not collect host %s." % host)
    for harness, n in sorted((scanned.get("not_analysed") or {}).items()):
        notes.append("%d %s session(s) were not analysed (claude-code transcripts only)." % (n, harness))
    if log["state"] == "unreachable":
        notes.append("The Captain's Log is %s, so Lee steps seen only as cards are not counted; findings come"
                     " from status logs and the archive." % log["reason"])
    elif log["state"] == "not-set":
        notes.append("No captains-log URL is set, so Lee steps seen only as Captain's Log cards are not counted.")
    notes.append("A worker that resumed in the wrong directory is found only while its task record survives.")
    return {"hosts_expected": hosts, "hosts_present": present, "homes": home_rows, "captains_log": log,
            "harvester_last_run": scanned.get("harvester_last_run"),
            "sessions_analysed": len(scanned["sessions"]), "notes": notes}


def summarise(scanned, homes, hosts, model, cards, log, channels):
    events = all_events(scanned, homes, scanned["date"], cards, channels)
    if log["state"] == "read":
        log = dict(log, cards=len(cards), card_only=sum(1 for e in events if e["kind"] == "card-only"))
    findings = group_findings(events, model)
    for e in events:
        if e.get("home"):
            e["home"] = place(e["home"])
    return {
        "officer_role": "friction",
        "scorer": SCORER,
        "model": model,
        "date": scanned["date"],
        "coverage": coverage(scanned, homes, hosts, log),
        "events": events,
        "findings": findings,
        "actionable": sum(1 for f in findings if f["carded"]),
    }


def render_md(doc):
    lines = ["# Friction officer digest for %s" % doc["date"], ""]
    lines.append("%d actionable finding(s) (severity and confidence of at least 3); scorer %s." % (
        doc["actionable"], doc["scorer"]))
    lines.append("%d friction event(s), %d naming Lee." % (
        len(doc["events"]), sum(1 for e in doc["events"] if e["lee"])))
    lines += ["", "## Coverage", ""]
    cov = doc["coverage"]
    lines.append("- Hosts present: %s (expected: %s)." % (
        ", ".join(cov["hosts_present"]) or "none", ", ".join(cov["hosts_expected"]) or "not set"))
    lines.append("- Sessions analysed: %d; archive harvester last ran %s." % (
        cov["sessions_analysed"], cov["harvester_last_run"] or "never"))
    for home in cov["homes"]:
        lines.append("- Home %s: %d status log(s), fleet ledger %s." % (
            place(home["path"]), home["status_logs"], "read" if home["ledger"] else "absent"))
    if cov["captains_log"]["state"] == "read":
        lines.append("- Captain's Log: %d card(s) read, %d Lee step(s) seen only as a card." % (
            cov["captains_log"]["cards"], cov["captains_log"]["card_only"]))
    for note in cov["notes"]:
        lines.append("- " + note)
    bosun = doc.get("bosun")
    if bosun:
        lines += ["", "## Bosun unsure items", ""]
        for row in bosun["hosts"]:
            lines.append("- %s (result of %s): %d unsure; %d answered, %d unreadable (the Bosun retries them), %d without a bucket,"
                         " %d unsettled." % (row["host"], row["result_date"] or "unknown date", row["unsure"], row["answered"],
                                             row["unreadable"], row["no_bucket"], row["unsettled"]))
        for gap in bosun["gaps"]:
            lines.append("- " + gap)
        if bosun["unsettled"]:
            lines += ["", "Unsettled, for the Quartermaster (no rule settles them from facts the officer reads):", ""]
            for u in bosun["unsettled"]:
                lines.append("- %s %s `%s`: %s" % (u["host"], u["kind"], u["item"].replace("`", "'"), u["reason"]))
    lines += ["", "## Linear", ""]
    lines.append("- Writes: %s; %d of %d Linear call(s) used%s." % (
        doc["writes"], doc["linear_calls"], doc["linear_call_budget"],
        "; stopped: " + doc["writes_blocked"] if doc["writes_blocked"] else ""))
    lines += ["- " + n for n in doc["not_filed"] + doc["linear_gaps"]]
    lines += ["- " + a["line"] for a in doc["asks_for_lee"]]
    lines += ["", "## Findings", ""]
    if not doc["findings"]:
        lines.append("- None.")
    for f in doc["findings"]:
        title = f["title"] or "%s / %s%s (no rule names a fix)" % (
            f["cause"], f["sub"], " / " + f["name"] if f["name"] else "")
        lines.append("### %s" % title.replace("`", "'"))
        lines.append("")
        lines.append("- Root cause: %s (%s)%s; severity %d, confidence %d; %s." % (
            f["cause"], f["sub"], ", " + f["name"] if f["name"] else "", f["severity"], f["confidence"],
            "carded" if f["carded"] else "not carded"))
        lines.append("- What Lee had to do: %s; %d of %d event(s) named Lee." % (
            f["lee_did"] or "not stated", f["lee_events"], f["events"]))
        lines.append("- Waits: %d measured, total %s, median %s, longest %s; %d still open; %d re-ask(s)." % (
            f["waits_measured"], human_span(f["wait_total_s"]), human_span(f["wait_median_s"]),
            human_span(f["wait_max_s"]), f["open"], f["reasks"]))
        st = f["state"]
        lines.append("- State: %s%s." % (st["state"], "".join(
            " (%s %s)" % (k, st[k]) for k in ("link", "task") if st.get(k)) + (
                " (reopen: no task or link names it)" if st["reopen"] else "") + (
                " (rule: %s - %s)" % (st["rule"]["text"], st["rule"]["source"]) if st["rule"] else "")))
        lin = f.get("linear")
        if lin:
            lines.append("- Linear: %s %s; found %d, score %.1f (%s)%s." % (
                lin["class"], lin.get("issue") or lin.get("action", "not filed"), lin["found"], lin["score"], lin["severity"],
                ": " + lin["reason"] if lin.get("reason") else ""))
        lines.append("- Proposed fix: %s" % (f["fix"] or "none yet; the model seam is off (model: none)."))
        lines.append("- Owner: %s; effort %s." % (f["owner"] or "not stated", f["effort"] or "not stated"))
        ev = f["evidence"]
        lines.append("- Evidence: tasks %s; status %s; cards %s; sessions %s; e.g. `%s`." % (
            ", ".join(ev["tasks"]) or "none", ", ".join(ev["status_keys"]) or "none",
            ", ".join(ev["cards"]) or "none",
            ", ".join(ev["sessions"][:6]) or "none", ev["example"].replace("`", "'")))
        for a in ev["asks"]:
            lines.append("- Asked %s (%s): \"%s\"" % (a["date"], a["session"], a["quote"].replace("`", "'")))
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def main(argv):
    if argv == ["bosun-read"]:
        json.dump(bosun_read(), sys.stdout, sort_keys=True)
        return 0
    parser = argparse.ArgumentParser(prog="fm-officer-friction.py")
    parser.add_argument("action", choices=["scan", "run"])
    parser.add_argument("--archive", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--out")
    parser.add_argument("--home", action="append", default=[])
    parser.add_argument("--hosts", default="")
    parser.add_argument("--captains-log")
    parser.add_argument("--channel", action="append", default=[])
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--model", default="none")
    parser.add_argument("--now", type=int)
    parser.add_argument("--bosun-hosts", default="")
    parser.add_argument("--fm-home")
    parser.add_argument("--start-home", action="append", default=[])
    parser.add_argument("--team", default="PC")
    parser.add_argument("--writes", choices=["none", "linear"], default="none")
    parser.add_argument("--max-creates", type=int, default=100)
    parser.add_argument("--max-linear-calls", type=int, default=450)
    parser.add_argument("--triage-label", default="triage")
    parser.add_argument("--rubric", default=RUBRIC_FILE)
    parser.add_argument("--jev", default=os.path.expanduser("~/.claude/skills/local-jev/jev.py"))
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        parser.error("--date must be YYYY-MM-DD")
    if args.action == "scan":
        json.dump(scan(args.archive, args.date, args.days), sys.stdout, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if not args.out:
        parser.error("run needs --out")
    now = args.now if args.now is not None else int(time.time())
    bosun_hosts = [h for h in (x.strip() for x in args.bosun_hosts.split(",")) if h]
    if not all(HOST_RE.match(h) for h in bosun_hosts):
        parser.error("--bosun-hosts must be comma-separated host names")
    remote = re.match(r"^([A-Za-z0-9][A-Za-z0-9._@-]*):(/.*)$", args.archive)
    try:
        if args.model != "none":
            raise RuntimeError("model-written fixes are not available in slice 1 (model: %s)" % args.model)
        if remote:
            scanned = remote_scan(remote.group(1), remote.group(2), args.date, args.days)
        else:
            scanned = scan(args.archive, args.date, args.days)
        triage.require_harvested(scanned)
        homes = [triage.Home(h) for h in args.home]
        triage.join_sessions(scanned, homes)
        triage.classify_mates(scanned, homes)
        hosts = [h for h in (x.strip() for x in args.hosts.split(",")) if h]
        cards, log, replies, replies_gap = [], {"state": "not-set"}, [], None
        if args.captains_log:
            try:
                cards, log = load_captains_log(args.captains_log), {"state": "read"}
            except RuntimeError as exc:
                log = {"state": "unreachable", "reason": str(exc)}
            try:
                replies = load_replies(args.captains_log, now)
            except RuntimeError as exc:
                replies_gap = exc
        doc = summarise(scanned, homes, hosts, args.model, cards, log, CHANNEL_LOGS | set(args.channel))
        if bosun_hosts:
            doc["bosun"] = bosun_section(bosun_hosts)
        if replies_gap:
            doc["coverage"]["notes"].append(
                "The Captain's Log replies are %s, so Start fix taps seen only there are not counted; states come"
                " from inboxes, the backlog and task records." % replies_gap)
    except (RuntimeError, ValueError) as exc:
        print("fm-officer-friction: %s" % exc, file=sys.stderr)
        return 1
    offices = [_progress().parse_office(a) for a in args.start_home]
    # A finding starts by default only when the home its request is addressed to is one this pass reads, because the
    # delivered note is the only thing that stops the next night asking again. Without such a home none is started.
    lib = _lib()
    args.now = now
    lib.check_common_args(parser, args)
    target = lib.office_home(lib.FLEET_PROJECT, args.fm_home, offices) if args.fm_home else None
    readable = {os.path.realpath(h.path) for h in homes}
    if target and os.path.realpath(target) not in readable:
        doc["coverage"]["notes"].append(
            "Start requests would go to %s, which this pass does not read, so no finding is started by default."
            % place(target))
        target = None
    eligible = {f["id"] for f in card_findings(doc) if f["carded"] and (f["cause"], f["sub"]) in STANDING_START} \
        if target else set()
    states = finding_states(doc["findings"], homes, replies, args.date, eligible)
    # The end of the digest's day, not the clock: a re-run stays byte-identical, and an office delivers the start
    # requests only within 36 hours of it (bin/fm-office.sh), so a digest for a long-past day starts nothing.
    doc["source"], doc["generated_at"] = "friction-officer", iso_utc(day_bounds(args.date)[1])
    linear, doc["start_requests"] = linear_pass(doc, states, eligible, args, offices, args.fm_home)
    doc.update(linear)
    doc["coverage"]["notes"].extend(linear["linear_gaps"])
    for f in doc["findings"]:
        f["state"] = states[f["id"]]
    if args.fm_home:
        _progress().write_handoff(os.path.join(args.out, args.date + ".start-requests.sh"),
                                  [r["execute"] for r in doc["start_requests"]
                                   if r["execute"]["env"]["FM_HOME"] == args.fm_home])
    triage.write_if_changed(os.path.join(args.out, args.date + ".json"),
                            json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    triage.write_if_changed(os.path.join(args.out, args.date + ".md"), render_md(doc))
    triage.write_if_changed(os.path.join(args.out, args.date + ".velocity-findings.json"),
                            json.dumps(velocity_doc(doc, now, states), sort_keys=True, indent=1,
                                       ensure_ascii=False) + "\n")
    if bosun_hosts:
        triage.write_if_changed(os.path.join(args.out, "bosun-answers.json"), json.dumps(
            {"schema_version": 1, "source": "friction-officer", "date": args.date, "answers": doc["bosun"]["answers"]},
            sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    print("DIGEST %s %d %s.md" % (args.date, doc["actionable"], args.date))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
