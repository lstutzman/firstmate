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
               wrong directory) is a report with no wait.
  archive      each claude-code session of the archive day: a <bash-input>
               record is a command Lee ran himself (ssh to the session's own
               host is flagged); an assistant text block asking Lee to run or
               do something is an ask, collapsed per session and command and
               measured to the next message Lee typed; a tool result whose
               line starts with a guard refusal, a sudo prompt, an ssh key
               refusal, a 1Password refusal, a not-signed-in CLI, or
               `command not found` is agent-side friction. A worker session
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
not. A group spanning two or more days, one
of them the run's day, becomes a repeat-ask event whose evidence is each day's
scrubbed quote. The fix is to make the instruction automatic work (a scheduled
check, a hook, or a standing rule) so Lee stops giving it.

Re-running a day with unchanged inputs rewrites identical digest bytes; the
one environment input is this host's name, which counts as the home's own
host for ssh-to-self.

`scan` reads only the archive and prints the per-session facts as JSON, so
`run` can send it, with the triage pass it imports, to `python3 -I -` over
`ssh -o BatchMode=yes <host>`. `run` joins sessions to tasks exactly as the
triage officer does, reads the status logs, classifies each event's root
cause by the first matching rule in RULES, groups events by cause and
service or tool, and writes into --out:

  <date>.json                    every event and finding (no wall-clock stamps,
                                 so a re-run with unchanged inputs rewrites
                                 identical bytes);
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
every night (at most 54 characters, which fleet-app's tap card needs). Its state
is read-only: settled when a line in a home's data/captain-shared.md that says
"standing rule" or "standing exception" names the id (alone or as friction-<id>)
or its category key written "settles: <cause>/<sub>" (for example "settles:
policy/merge-word"; a finding about one tool, hook or service also needs the
line to name it, or the key to carry it as "settles: <cause>/<sub>/<name>");
no looser wording settles anything; else started when a Start
fix tap for it sits in a home's state/inbox (the note fleet-app's shim files,
"Captain's Log reply [friction-<id>]: Start fix: <title>") or in
<captains-log>/replies?since=<30 days ago>, or a data/backlog.md line or a task's branch= names it
(its link is the first pull request or https URL those hold); else open. The
state is as of the run's generated_at.

The proposed fix comes from the FIXES table. A group no rule names gets no
card; propose_fix() is the seam where a later slice may ask a small model,
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
        r"authentication error|code 10000|insufficient (?:permission|privilege)s?|forbidden|\b403\b"
        r"|refuses? (?:the |its )?(?:agents?'? )?(?:\w+ )?token|token.{0,40}refus"
        r"|(?:token|key|grant)s?.{0,30}\bscopes?\b|\bscopes?\b.{0,30}(?:token|key)"
        r"|widen(?:ed|ing)? (?:the )?(?:\w+ )?token", re.I)),
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
    ("other", "other"): (
        "Blocked steps carry no recorded cause",
        "answer an ask whose reason no rule recognised",
        "Make every blocked or needs-decision line say why the agent cannot go on (policy, credential, sudo, tool"
        " or decision), so the next run can group it and name its fix; then remove the most repeated cause.",
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


def service_of(text, near=0):
    """The service named closest to position `near`, or None."""
    best = None
    for name, pattern in SERVICES:
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


def session_events(records, machine):
    """Friction events in one transcript, in record order."""
    events = []
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
                               "service": service_of(command), "tool": tool, "signature": sig})
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
                       "lee": True, "service": service_of(line, pos), "tool": None, "signature": sig,
                       "answered_at": None, "wait_s": None}
                asks[sig] = ask
                events.append(ask)
                if at is not None:
                    pending.append(ask)
            elif kind == "user" and block.get("type") == "tool_result":
                body = triage.result_text(block)
                for hit, pattern in HIT_PATTERNS:
                    m = pattern.search(body)
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
    for rec in records:
        text = user_text(rec) if rec.get("type") == "user" else None
        if text is None:
            continue
        if skip:
            skip = False
            continue
        if MACHINE_PROMPT_RE.match(text) or BASH_INPUT_RE.match(text.strip()) or len(text) > 6000:
            continue
        for clause in lee_clauses(text):
            clause = clause.strip()
            if 12 <= len(clause) <= MAX_ASK_LEN and INSTRUCTION_RE.search(clause) and len(ask_tokens(clause)) >= ASK_MIN_SHARED:
                out.append((epoch_of(rec.get("timestamp")), clause))
    return out


def scan_asks(archive, date, days):
    """Lee's instruction sentences over the `days` days ending at <date>, from interactive sessions only."""
    out = []
    end = datetime.date.fromisoformat(date)
    for back in range(days):
        day = (end - datetime.timedelta(days=back)).isoformat()
        manifest = triage.load_json(os.path.join(archive, "by-date", day, "manifest.json"))
        for entry in (manifest or {}).get("sessions") or []:
            if entry.get("harness") != "claude-code":
                continue
            folder = os.path.join(archive, entry.get("folder") or "")
            index = triage.load_json(os.path.join(folder, "index.json")) or {}
            kind = triage.classify(index.get("first_prompt") or "")
            if kind not in ("other", "worker"):
                continue
            records = records_of(os.path.join(folder, "transcript.jsonl.gz"))
            for at, sentence in lee_instructions(records or [], kind == "worker"):
                out.append({"date": day, "at": at, "session": "%s:%s" % (entry.get("machine"), entry.get("session_id") or entry.get("name")),
                            "text": scrub(sentence, MAX_ASK_LEN)})
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


def parse_status_line(line):
    """(state, key, at, text) of one status line, or None."""
    m = STATUS_RE.match(line.strip())
    if not m:
        return None
    markers = m.group(2)
    at = AT_RE.search(markers)
    key = KEY_RE.search(markers)
    return m.group(1), key.group(1) if key else None, int(at.group(1)) if at else None, m.group(3)


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
                state_word, key, at, text = parsed
                streams.setdefault(task, []).append(
                    {"state": state_word, "key": key, "at": at, "text": text, "source": "status"})
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
                 "text": (rec.get("text") or "").strip(), "source": "ledger"})
    for events in streams.values():
        events.sort(key=lambda e: e["at"])
    return streams


def host_names(home):
    """Names the home's own machine answers to: its directory name and this host's short name."""
    return {place(home.path), socket.gethostname().split(".")[0]}


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
                    "cause": cause, "sub": sub, "service": service_of(text, pos), "tool": None,
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
                    "lee": True, "service": service_of(text, pos), "tool": None,
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
        fix = propose_fix(cause, sub, model)
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
            "severity": severity, "confidence": confidence, "carded": carded,
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


def finding_states(findings, homes, replies):
    """{finding id: (state, link)}: open, started (a tap, task or pull request names it) or settled.

    A standing-rule line in a home's data/captain-shared.md that names the finding id or key settles it, and wins
    over a start. Started comes from a Start fix tap in a home's inbox or in the replies, or a backlog
    line or task branch that names the id; its link is the first pull request or https URL found there.
    """
    notes = [t.lower() for h in homes for t in inbox_notes(h)]
    shared = [l.lower() for h in homes for l in read_lines(os.path.join(h.path, "data", "captain-shared.md"))
              if STANDING_RE.search(l)]
    backlog = [(h, l) for h in homes for l in read_lines(os.path.join(h.path, "data", "backlog.md"))]
    out = {}
    for f in findings:
        rx = id_re(f["id"])
        if any(settles(l, f, rx) for l in shared):
            out[f["id"]] = ("settled", None)
            continue
        hits = []  # one entry per start found: its link, or None
        tap = re.compile(r"captain's log reply \[friction-%s\]: start fix" % re.escape(f["id"]))
        for note in notes:
            if tap.search(note):
                hits.append(None)
        for reply in replies:
            if reply["card"] == "friction-" + f["id"] and str(reply.get("text") or "").lower().startswith("start fix"):
                urls = re.findall(r"https://[^\s\"\\]+", json.dumps(reply.get("answer") or ""))
                hits.append(urls[0].rstrip(".,)") if urls else None)
        for home, line in backlog:
            if rx.search(line.lower()):
                m = TASK_LINE_RE.match(line)
                url = URL_RE.search(line)
                hits.append(url.group(0).rstrip(".,)") if url else (task_link(home, m.group(1)) if m else None))
        for home in homes:
            for task, meta in sorted(home.metas.items()):
                if rx.search((meta.get("branch") or "").lower()):
                    hits.append(task_link(home, task))
        link = next((u for u in hits if u and u.startswith("https://") and len(u) <= 300), None)
        out[f["id"]] = ("started" if hits else "open", link)
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
    cards = [bottleneck(f, doc["date"]) for f in doc["findings"]
             if f["title"] and f["fix"] and (f["cause"], f["sub"]) not in NOT_CARDED][:MAX_CARDS]
    for card in cards:
        state, link = (states or {}).get(card["id"], ("open", None))
        card["state"] = state
        if link:
            card["link"] = link
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
        if replies_gap:
            doc["coverage"]["notes"].append(
                "The Captain's Log replies are %s, so Start fix taps seen only there are not counted; states come"
                " from inboxes, the backlog and task records." % replies_gap)
    except (RuntimeError, ValueError) as exc:
        print("fm-officer-friction: %s" % exc, file=sys.stderr)
        return 1
    states = finding_states(doc["findings"], homes, replies)
    triage.write_if_changed(os.path.join(args.out, args.date + ".json"),
                            json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    triage.write_if_changed(os.path.join(args.out, args.date + ".md"), render_md(doc))
    triage.write_if_changed(os.path.join(args.out, args.date + ".velocity-findings.json"),
                            json.dumps(velocity_doc(doc, now, states), sort_keys=True, indent=1,
                                       ensure_ascii=False) + "\n")
    print("DIGEST %s %d %s.md" % (args.date, doc["actionable"], args.date))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
