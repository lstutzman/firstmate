# Triage officer digest for 2026-10-23

6 actionable finding(s); scorer deterministic-v1.

## Coverage

- Hosts present: alpha (expected: alpha, beta).
- Sessions: 9, of which 9 analysed.
- Archive harvester last ran: 2026-10-24T01:00:00+00:00.
- Worker sessions whose home is not readable here: 1.
- Desk sessions are not archived: the Slack desk runs with --no-session-persistence, so 0 desk sessions is expected.

## Session mix

- classifier: 1
- mate: 3
- no-mistakes: 1
- other: 1
- reviewer: 1
- worker: 2

## Worker outcomes

- 2 worker session(s), $1.00.
- done: 1
- unresolved: 1
- Joined via: launch-brief 2.

## Wasted-turn patterns

- re-read: 1
- repeated-call: 3
- retry-after-refusal: 1
- sleep-then-check: 2

## Top error signatures

- 2 x `hook-refusal: PreToolUse hook error: BLOCKED by guard`
- 1 x `tool-error: InvalidSignature for secret <token> rejected`
- 1 x `tool-error: bash: <token>: command not found`

## Findings

- [high] coverage: no archived sessions from expected host beta
- [medium] rule-violation: networkidle: 1 call(s), e.g. Edit content sets waitUntil networkidle (alpha:w1)
- [medium] rule-violation: pkill-f: 1 call(s), e.g. pkill -f ... (alpha:w1)
- [medium] rule-violation: pr-body-headings: 1 call(s), e.g. PR body lacks Testing, Risk, How to revert (alpha:w1)
- [medium] rule-violation: rm-not-trash: 1 call(s), e.g. rm -f ... (alpha:w1)
- [medium] rule-violation: startup-file-print: 1 call(s), e.g. cat ... (alpha:w1)
