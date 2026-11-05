# Friction officer digest for 2026-11-04

1 actionable finding(s) (severity and confidence of at least 3); scorer friction-deterministic-v1.
5 friction event(s), 1 naming Lee.

## Coverage

- Hosts present: alpha (expected: alpha).
- Sessions analysed: 1; archive harvester last ran 2026-11-05T01:00:00+00:00.
- Home fixturehost: 0 status log(s), fleet ledger absent.
- Home fixturehost keeps no fleet ledger, so status lines of tasks already cleaned up there are not read.
- No captains-log URL is set, so Lee steps seen only as Captain's Log cards are not counted.
- A worker that resumed in the wrong directory is found only while its task record survives.

## Findings

### Lee gives the same instruction on several days

- Root cause: repeat-ask (instruction), before branch rebase release tagging; severity 3, confidence 3; carded.
- What Lee had to do: repeat an instruction he has already given; 1 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- Proposed fix: Turn the instruction into automatic work: a scheduled officer check, a hook, or a standing rule in captain-shared.md that firstmate applies without being told, and say so to Lee once.
- Owner: main (firstmate); effort S.
- Evidence: tasks none; status none; cards none; sessions none; e.g. `3 days: Make sure you always rebase the release branch before tagging it.`.
- Asked 2026-11-02 (alpha:live-02): "Make sure you always rebase the release branch before tagging it."
- Asked 2026-11-03 (alpha:live-03): "Make sure you always rebase the release branch before tagging it."
- Asked 2026-11-04 (alpha:live-04): "Make sure you always rebase the release branch before tagging it."

### A tool agents need is missing: gh

- Root cause: missing-tool (tool), gh; severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- Proposed fix: Add gh to alpha's bootstrap and its doctor check, so it is present before the next session.
- Owner: alpha home; effort S.
- Evidence: tasks none; status none; cards none; sessions alpha:live-04; e.g. `gh: command not found`.

### A tool agents need is missing: hyperfine

- Root cause: missing-tool (tool), hyperfine; severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- Proposed fix: Add hyperfine to alpha's bootstrap and its doctor check, so it is present before the next session.
- Owner: alpha home; effort S.
- Evidence: tasks none; status none; cards none; sessions alpha:live-04; e.g. `hyperfine: command not found`.

### A tool agents need is missing: rg

- Root cause: missing-tool (tool), rg; severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- Proposed fix: Add rg to alpha's bootstrap and its doctor check, so it is present before the next session.
- Owner: alpha home; effort S.
- Evidence: tasks none; status none; cards none; sessions alpha:live-04; e.g. `rg: command not found`.

### A tool agents need is missing: shellcheck

- Root cause: missing-tool (tool), shellcheck; severity 2, confidence 3; not carded.
- What Lee had to do: nothing directly (agent-side friction); 0 of 1 event(s) named Lee.
- Waits: 0 measured, total not measured, median not measured, longest not measured; 0 still open; 0 re-ask(s).
- Proposed fix: Add shellcheck to alpha's bootstrap and its doctor check, so it is present before the next session.
- Owner: alpha home; effort S.
- Evidence: tasks none; status none; cards none; sessions alpha:live-04; e.g. `shellcheck: command not found`.
