# Friction officer digest for 2026-10-26

1 actionable finding(s) (severity and confidence of at least 3); scorer friction-deterministic-v1.
9 friction event(s), 3 naming Lee.

## Coverage

- Hosts present: none (expected: alpha).
- Sessions analysed: 0; archive harvester last ran 2026-10-27T01:00:00+00:00.
- Home fixturehost: 9 status log(s), fleet ledger absent.
- Home fixturehost keeps no fleet ledger, so status lines of tasks already cleaned up there are not read.
- No archived sessions from expected host alpha.
- No captains-log URL is set, so Lee steps seen only as Captain's Log cards are not counted.
- A worker that resumed in the wrong directory is found only while its task record survives.

## Findings

### An agent token lacks a scope, so Lee widens it

- Root cause: credential (scope); severity 4, confidence 3; carded.
- What Lee had to do: widen or roll a the service token for the agents; 3 of 7 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 7 still open; 0 re-ask(s).
- Proposed fix: Keep the agent token's required scopes in one checked list and probe them at session start, so a widening is asked for once, with the full list, before work starts.
- Owner: Lee (token owner); main keeps the scope list; effort S.
- Evidence: tasks captain-hold-pc-sdk-10-0-403, dealscoring-scale-scope, gh-env, pc-2769-runs-scope, pc-3417-merge-word, skills-pr71-merge, staging-bypass-token-leak; status GH_TOKEN-scope@2026-10-26T16:54:17Z, hold@2026-10-26T16:54:17Z, leak@2026-10-26T16:54:17Z, merge@2026-10-26T16:54:17Z, mw@2026-10-26T16:54:17Z, runs@2026-10-26T16:54:17Z, scale@2026-10-26T16:54:17Z; cards none; sessions none; e.g. `<token>: pick (a) or (b)`.

### An agent token lacks a scope, so Lee widens it: Cloudflare

- Root cause: credential (scope), Cloudflare; severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 1 still open; 0 re-ask(s).
- Proposed fix: Keep the agent token's required scopes in one checked list and probe them at session start, so a widening is asked for once, with the full list, before work starts.
- Owner: Lee (token owner); main keeps the scope list; effort S.
- Evidence: tasks gilligan-pc3182-access-token; status acc@2026-10-26T16:54:17Z; cards none; sessions none; e.g. `Cloudflare access token for gilligan-pc3182: stored in 1Password, Cloudflare Access returns forbidden`.

### Blocked steps carry no recorded cause

- Root cause: other (other); severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 1 still open; 0 re-ask(s).
- Proposed fix: Workers now tag blocked and needs-decision lines with [cause=policy|credential|sudo|tool|decision|external]; find the tasks and homes this group's evidence names that still write untagged lines, update their briefs, then remove the most repeated cause.
- Owner: main (firstmate); effort S.
- Evidence: tasks pc-3279-cf-token-still-refused; status cf@2026-10-26T16:54:17Z; cards none; sessions none; e.g. `Cloudflare still refuses the agents' CLOUDFLARE_API_TOKEN for KV; the token is stored in 1Password`.
