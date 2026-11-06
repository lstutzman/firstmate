# Friction officer digest for 2026-10-23

8 actionable finding(s) (severity and confidence of at least 3); scorer friction-deterministic-v1.
18 friction event(s), 13 naming Lee.

## Coverage

- Hosts present: alpha (expected: alpha).
- Sessions analysed: 2; archive harvester last ran 2026-10-24T01:00:00+00:00.
- Home fixturehost: 7 status log(s), fleet ledger read.
- No captains-log URL is set, so Lee steps seen only as Captain's Log cards are not counted.
- A worker that resumed in the wrong directory is found only while its task record survives.
- 3 finding(s) due to start by default were not started because the run writes no Linear items (set writes: linear); each card offers Start fix.

## Linear

- Writes: none; 0 of 450 Linear call(s) used.

## Findings

### Lee-step ssh lines target the machine they run on

- Root cause: environment (ssh-to-self); severity 5, confidence 5; carded.
- What Lee had to do: run an ssh -t <host> line inside a session on that same host, where ssh to itself has no key; 3 of 3 event(s) named Lee.
- Waits: 1 measured, total 2.0 h, median 2.0 h, longest 2.0 h; 0 still open; 1 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 4.0 (high).
- Proposed fix: Make Lee-step one-liners host-aware: print `bash <script>` when the session already runs on the target host and `ssh -t <host> ...` only from another machine, or install a loopback key.
- Owner: main (firstmate); effort S.
- Evidence: tasks task-swap; status swap-c2@2026-10-23T10:00:00Z, swap-c2@2026-10-23T10:30:00Z; cards none; sessions alpha:s-mate; e.g. `arm 2 done. Lee, please run: ssh -t fixturehost 'bash /x/swap.sh c2' -- it should end with OK. Options: (a) run it now; (b) skip`.

### Agents hand Lee sudo steps to run by hand

- Root cause: sudo (sudo); severity 4, confidence 5; carded.
- What Lee had to do: run a sudo command or script by hand; 2 of 3 event(s) named Lee.
- Waits: 2 measured, total 55 min, median 40 min, longest 40 min; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 4.0 (high).
- Proposed fix: Install a root-owned script for the step with a NOPASSWD sudoers rule naming that exact path (or a systemd unit the agent may start), approved once by Lee, so the agent runs it itself.
- Owner: fixturehost home (Lee approves the sudoers rule); effort M.
- Evidence: tasks gone, task-lic, task-wt; status fleet-sudo@2026-10-23T10:00:00Z; cards none; sessions alpha:s-worker; e.g. `sudo: a terminal is required`.

### An agent token lacks a scope, so Lee widens it

- Root cause: credential (scope), Cloudflare; severity 4, confidence 5; carded.
- What Lee had to do: widen or roll a Cloudflare token for the agents; 1 of 1 event(s) named Lee.
- Waits: 1 measured, total 1.0 h, median 1.0 h, longest 1.0 h; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 4.0 (high).
- Proposed fix: Keep the agent token's required scopes in one checked list and probe them at session start, so a widening is asked for once, with the full list, before work starts.
- Owner: Lee (token owner); main keeps the scope list; effort S.
- Evidence: tasks task-cf; status cf-scope@2026-10-23T10:00:00Z; cards none; sessions none; e.g. `Cloudflare refuses the agent token for Email Routing and KV (code 10000); one widening Lee needs`.

### New staging credentials wait on Lee's per-credential word

- Root cause: policy (credential-approval); severity 4, confidence 5; carded.
- What Lee had to do: approve a new credential by name; 1 of 1 event(s) named Lee.
- Waits: 1 measured, total 1.5 h, median 1.5 h, longest 1.5 h; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 4.0 (high).
- Proposed fix: Adopt a standing naming rule for new staging-only credentials (name pattern, vault, owner) so a name that follows it is pre-approved; production credentials stay direct-only.
- Owner: Lee (fleet rules section 5); effort S.
- Evidence: tasks task-mail; status mailbox-token@2026-10-23T10:00:00Z; cards none; sessions none; e.g. `creating staging secret E2E_MAILBOX_TOKEN is a credential change: the rules need Lee's own words naming it`.

### Secret-exposure hook blocks safe shell-file edits, so Lee makes them

- Root cause: guard-hook (secret-hook); severity 3, confidence 5; carded.
- What Lee had to do: make a shell startup or secret-file edit the secret-exposure hook refused; 1 of 1 event(s) named Lee.
- Waits: 1 measured, total 10 min, median 10 min, longest 10 min; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 4.0 (high).
- Proposed fix: Give the secret-exposure hook a sanctioned path for writing op:// reference lines (never literal values) to shell startup files, with a fixture test, so agents make the edit themselves.
- Owner: skills (global hooks); effort S.
- Evidence: tasks task-node; status node-line@2026-10-23T10:00:00Z; cards none; sessions none; e.g. `Making Node the default needs one line from Lee (hooks block me editing his shell startup file)`.

### Lee runs commands by hand with no recorded reason

- Root cause: lee-command (run); severity 3, confidence 4; carded.
- What Lee had to do: run a command or script by hand; 2 of 2 event(s) named Lee.
- Waits: 1 measured, total 5 min, median 5 min, longest 5 min; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 4.0 (high).
- Proposed fix: Make every Lee-step ask name why the agent cannot run it (sudo, credential, policy or tool), so the cause can be removed; then remove it, starting with the most repeated.
- Owner: main (firstmate); effort S.
- Evidence: tasks none; status none; cards none; sessions alpha:s-mate; e.g. `op run`.

### Agents lack an ssh key for a fleet host

- Root cause: credential (ssh-key); severity 3, confidence 4; carded.
- What Lee had to do: run an ssh step by hand because the agent's key was refused; 1 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 4.0 (high).
- Proposed fix: Install the agent's key in the target host's authorized_keys, or give it an ssh alias that reaches the host, and record it in the machine's bootstrap so the refusal cannot come back.
- Owner: alpha home; effort S.
- Evidence: tasks none; status none; cards none; sessions alpha:s-mate; e.g. `ssh -t beta bash lic.sh`.

### A tool agents need is missing: openjdk

- Root cause: missing-tool (tool), openjdk; severity 3, confidence 4; carded.
- What Lee had to do: install a tool by hand; 1 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 4.0 (high).
- Proposed fix: Add openjdk to alpha's bootstrap and its doctor check, so it is present before the next session.
- Owner: alpha home; effort S.
- Evidence: tasks none; status none; cards none; sessions alpha:s-mate; e.g. `brew install`.

### decision / decision (no rule names a fix)

- Root cause: decision (decision); severity 3, confidence 5; not carded.
- What Lee had to do: not stated; 1 of 1 event(s) named Lee.
- Waits: 1 measured, total 2 min, median 2 min, longest 2 min; 0 still open; 0 re-ask(s).
- State: open.
- Linear: decision not filed; found 1, score 2.0 (medium).
- Proposed fix: none yet; the model seam is off (model: none).
- Owner: not stated; effort not stated.
- Evidence: tasks task-pick; status wording@2026-10-23T10:00:00Z; cards none; sessions none; e.g. `Lee, pick (a) the short wording or (b) the long one`.

### Worker sessions resume in the wrong directory after a restart

- Root cause: environment (wrong-cwd); severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 1.0 (low).
- Proposed fix: Resume each worker in the worktree its task record names (cd to its meta worktree= first) and refuse a resume whose directory differs.
- Owner: main (firstmate); effort M.
- Evidence: tasks task-wt; status none; cards none; sessions alpha:s-worker; e.g. `worker started outside its task worktree`.

### Hook refusals slow agents down

- Root cause: guard-hook (refused), pre-bash-secret-exposure.py; severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 1.0 (low).
- Proposed fix: Where the refusal is right, make its message name the allowed command so the agent's next try succeeds; where it is a false positive, report it to the hook's owner with a fixture.
- Owner: skills (global hooks); effort S.
- Evidence: tasks task-wt; status none; cards none; sessions alpha:s-worker; e.g. `pre-bash-secret-exposure.py: secret exposure`.

### A tool agents need is missing: slopwatch

- Root cause: missing-tool (tool), slopwatch; severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 1.0 (low).
- Proposed fix: Add slopwatch to alpha's bootstrap and its doctor check, so it is present before the next session.
- Owner: alpha home; effort S.
- Evidence: tasks task-wt; status none; cards none; sessions alpha:s-worker; e.g. `slopwatch: command not found`.

### Service rate limits stall agents until the limit resets

- Root cause: service-limit (rate-limit), 1Password; severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- State: open.
- Linear: real not filed; found 1, score 1.0 (low).
- Proposed fix: Serve repeat reads from a cache (op-agent's for 1Password) and count calls per host, so one busy worker cannot exhaust the shared limit; warn at 80% instead of failing at 100%.
- Owner: skills (op-agent); effort M.
- Evidence: tasks task-wt; status none; cards none; sessions alpha:s-worker; e.g. `1Password: Too many requests`.
