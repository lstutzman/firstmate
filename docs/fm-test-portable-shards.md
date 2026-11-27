# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.
`tests/fm-test-ci-timings.tsv` holds the committed per-script CI duration hints the packer reads.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-24.04`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

`tests/fm-test-ci-timings.tsv` is the committed table the packer reads; the 2026-11-25 upstream sync moved the hints there from heredocs in `bin/fm-test-run.sh`.
It keeps this fork's own measured value for every script the fork measured, and upstream's value only for scripts the fork never measured (mostly real-Herdr members the portable lanes do not run).
The fork's measured durations are higher than upstream's for most shared scripts (for example `tests/fm-test-run.test.sh` 536229 ms against 328204 ms), so upstream's 15-minute packing target was not adopted and the budget stays 1400000 ms.
Failed or cancelled scripts are ignored, so a timeout does not become a packing weight.
Upstream split `tests/fm-captain-hold-lifecycle.test.sh` into itself and `tests/fm-captain-hold-teardown.test.sh`, and `tests/fm-watch-triage.test.sh` into itself and `tests/fm-watch-triage-busy.test.sh`.
The four split-member rows are the fork's measured parent duration divided in upstream's split proportions, pending a refresh from green CI.

The portable serial hint table was refreshed on 2026-11-11 from eight green Ubuntu CI runs on `lstutzman/firstmate` (43033498585, 43035551247, 43040775586, 43048626902, 43054650715, 43060395564, 43065245021, 43071495585), covering all 349 serial members.
It holds the slowest successful `duration_ms` per script from those runs' `fm-test-timing-portable-serial-*` artifacts, with no local or provisional exception.
Six members joined the lane during that window and have fewer samples: two for `tests/fm-claude-tool-exclude-live.test.sh`, `tests/fm-lavish-url.test.sh`, `tests/fm-remote-herdr-identity.test.sh`, `tests/fm-stow-guard.test.sh`, and `tests/fm-supervision-host-herdr-live-e2e.test.sh`, and seven for `tests/fm-secret-scan.test.sh`.
The previous hints modeled the largest of fifteen shards at 20.6 minutes, while the slowest real serial job in those runs took 23.4 to 24.4 minutes, so the serial shards were the critical path of the whole run.
The same eight runs sum to about 297 minutes of median serial script time, and each job adds about 27 seconds of setup.
The lane moved from fifteen to nineteen shards: re-packing those hints and replaying each held-out run's real durations against it (hints from six runs, scored on the other two, all four ways) put the slowest shard at a median 17.9 and worst 19.1 minutes of job time, against 22.3 and 22.6 for fifteen shards.
Nineteen is the smallest count whose slowest shard falls below the longest indivisible member, `tests/fm-watch-triage.test.sh` (951 to 1122 s), plus setup; twenty modeled 17.3 and more shards only add setup time and runners, because that one script then sets the floor.
The earlier 2026-11-06 refresh used five runs (42259522502, 42252576912, 42249761061, 42243881424, 42238131810) and the 2026-11-02 refresh eight (41056282922, 41207534722, 41207547671, 41210211924, 41211333584, 41214986542, 41218007432, 41220570713).
The packing budget moved from 1200000 to 1400000 ms because `tests/fm-watch-triage.test.sh` alone once ran 1174-1351 s.

The parallel hint table was refreshed on 2026-11-07 from three green Ubuntu CI runs on `lstutzman/firstmate` (42307116729, 42306871627, 42300071367), using the slowest successful `duration_ms` per script from their `fm-test-timing-portable-parallel-*` artifacts, covering all 26 parallel members.
The 2026-09-30 hints had drifted: lane 2 ran about 25 minutes against lane 1's 19 while the hint sums matched within 0.1 percent, so lane 2 was the slowest job of the whole CI run.
The serial table before the 2026-11-02 refresh was refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers, with two version/platform exceptions: the Windows hint below and the then pre-optimization session-start maximum.
All artifact records were cross-checked against the corresponding job's markers.
This covered all 24 parallel and 201 serial members at that refresh; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
Observed maxima provide conservative packing weights, not an upper bound on future durations.
A passing coverage guard does not establish a healthy job duration; refresh the table from uploaded timing artifacts when a member grows or the lane gains scripts.

The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains a separate measurement and is skipped by the portable CI shards.
Measure that script through the focused Git Bash runner rather than a portable skip.

The supervision-host suite is four serial members so no one file occupies a whole CI shard: `tests/fm-supervision-host-drain.test.sh` (report, dispatch, BRANCH OUTCOMES), `tests/fm-supervision-host-hook.test.sh` (Claude Stop-hook re-arm and hand-back), `tests/fm-supervision-host.test.sh` (host loop wakes, closes, mirror, return), and `tests/fm-supervision-host-park.test.sh` (latch, park boundary, compaction, lock ownership).
The single file had run 1192918 ms alone in a serial shard in run [39642852135](https://github.com/kunchenguid/firstmate/actions/runs/39642852135) and was cancelled at the 30-minute job cap in run 39765114423.
The remote secondmate lifecycle suite is two serial members so neither fills a CI shard: `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` (provisioning, spawn, inheritance, reply, liveness on the herdr route) and `tests/fm-remote-secondmate-lifecycle-rex-e2e.test.sh` (rex backend and retirement), sharing `tests/remote-secondmate-lifecycle-fixture.sh`.
The single file ran 1679557 ms in the cancelled 2026-11-07 CI shard (run [42419007195](https://github.com/lstutzman/firstmate/actions/runs/42419007195)).
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` capability-skips on the portable Ubuntu shards, so its hint is that skip's duration; its native-Windows cost is measured through the focused Git Bash runner instead.
`test_portable_serial_packing_budget_boundary` pins every other fixture script to 1 ms, so packing exactly at the budget is accepted and one millisecond above it is refused even when real serial members have no hint.
`tests/fm-park.test.sh` and `tests/fm-arm-pretool-check.test.sh` are portable parallel members; their lane follows the packing.
The coverage-guard test owns modeled real-hint headroom under that budget.
Do not discount a local speedup from CI packing weights; refresh from CI artifacts instead.
`tests/fm-backend-t3code.test.sh` and `tests/fm-t3-mcp.test.sh` run in the portable parallel lanes, so their hints sit in `tests/fm-test-ci-timings.tsv` and follow the 2026-11-07 parallel refresh above: every case id the backend suite spawns carries a per-run suffix and its cleanup removes only the `/tmp/fm-<id>` directories that run created, and both suites passed running concurrently with each other and beside another parallel suite (see [`fm-test-isolation-proof.md`](fm-test-isolation-proof.md)).

The 2026-11-13 `tests/fm-pi-bash-timeout.test.sh` serial hint is a provisional local measurement of 1486 ms, the slowest of five successful `bin/fm-test-run.sh tests/fm-pi-bash-timeout.test.sh` samples (1288-1486 ms) on a macOS arm64 host, collected separately from coverage and lint checks.
Replace it with an Ubuntu timing-artifact maximum at the next CI refresh; this is not whole-shard CI timing evidence.

## Parallel lanes

The three parallel lanes use longest-processing-time assignment over those hints.
Two lanes modeled at 26 minutes of script time and ran 22 to 28 minutes of job time on CI, the slowest job of the whole run; three model at 17.4 minutes each with the same members.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies, so neither parallel lane installs the Pi package.
`tests/fm-test-ci-timings.tsv` holds the duration values, and [`bin/fm-test-run.sh`](../bin/fm-test-run.sh) assigns membership by longest-processing-time packing (`portable_parallel_assignments`, `PORTABLE_PARALLEL_SHARDS=3`), so lane membership follows the hints.
The lane that holds `tests/fm-pi-primary-types.test.sh` is the one whose CI job passes `--fail-on-gate-skip` for the Pi extension typecheck prerequisite; `tests/fm-ci-workflow.test.sh` requires the flag on exactly that lane, so a packing change that moves the test moves the flag with it.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

CI runs each parallel lane with `--jobs 2`, which the runner admits only because every member is individually proven isolated.
Measured on 150 green or failed CI runs from 2026-11-08 to 2026-11-17, the parallel jobs ran serially and were the slowest job of the run in 99 runs (lane 1 in 55, lane 2 in 44): median wall 25.2 minutes against a median slowest-job runtime of 23.4, so runner queueing was not the cost.
With two workers a lane's wall time is bounded by its longest script (`tests/fm-pr-merge.test.sh`, `tests/fm-captain-hold-lifecycle.test.sh` and `tests/fm-test-run.test.sh`, 7 to 11 minutes at the median) instead of the 15 to 18 minutes of summed script time.
Portable serial shards stay at one worker (the runner refuses `--jobs` there), so after this change the longest serial shard sets the run's wall time.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the largest and smallest lane sums to differ by no more than five percent of the largest.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `tests/fm-test-ci-timings.tsv` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

The remote-secondmate lifecycle hint is 1005249 ms, its completed, passing `FM_TEST_END` sample from Ubuntu run [41289019354](https://github.com/kunchenguid/firstmate/actions/runs/41289019354). Rex lifecycle coverage outgrew the previous 345655 ms hint; serial shard 9 then reached the 30-minute job cap while running later tests. Eleven serial shards then accommodated the refreshed weight within the unchanged modeled budget and timeout policy. This is a completed-script measurement from a partial run, not a successful whole-shard timing or a guarantee of future headroom.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

`portable-serial-<k>of<n>` splits the remainder across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` (currently 19) and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over the committed duration hints.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
The packing target is 1400000 ms (`serial_budget_ms=1400000`).
`--check-coverage` refuses a modeled multi-script shard above that target; an indivisible suite may occupy a shard alone when its own hint is already above it.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget, a singleton overflow, and refusal of a multi-script overflow through the executable runner.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
The timing-aggregate job then runs `bin/fm-ci-budget-warn.sh`, which emits a GitHub warning annotation (never a failure) when any lane or lint partition's measured command time is at or above 20 minutes.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns the canonical CI partitions (`<k>of<n>`; CI runs seven), each attempting full source-aware ShellCheck analysis and running workflow validation and backend-purity checks.
Pull requests pass `--changed` so only the canonical-set files changed since the merge-base are analyzed, still with `--external-sources` and full dataflow, split across the same seven partitions.
A change to lint definition files (`bin/fm-lint.sh`, `bin/fm-lint-workflows.sh`, the pinned installers, or `bin/fm-timeout-lib.sh`), including a delete or rename of any of those paths, upgrades that PR to the full canonical set.
A change to a file that another canonical script sources, found from `# shellcheck source=` directives rather than a hand list, also upgrades to the full set so an unchanged consumer cannot hide a new ShellCheck finding from the PR and then fail the full gate on main.
A delete or rename of that helper counts, including the old path of a rename.
Main pushes keep the full canonical gate.
CI caches the pinned ShellCheck and actionlint binaries and skips the download when the pin is already present.
`FM_LINT_JOBS=1` stays in force because a second concurrent ShellCheck process does not fit the hosted runner's memory envelope.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, cache hits, and host contention.
No fast mode or paid runner provisioning is part of this layout; changed-only analysis applies to pull requests alone, and the result cache below applies to both.
A root's cost tracks the sourced library closure, not its own size, so partitions are packed on the byte total of each root plus every file ShellCheck can follow from it: that proxy correlates 0.65 with measured per-root time against 0.43 for the root's own bytes, and it is a scheduling weight only, never a skip rule.
Measured on three green main-branch PR runs of 2026-11-11 (678 roots, one ShellCheck process per runner because each analysis peaks near 8 GiB), per-root time summed to 4170 to 4740 seconds.
Byte-packed into four partitions that left runners at 700 to 1430 seconds of lint; the same measurements packed on closure weight model at 667 to 783 seconds for the worst of seven partitions (six models 780 to 878), so no partition passes the 14-minute target or nears the limit without touching the timeout tier.

Each partition restores `actions/cache` data keyed `fm-lint-cache-v1-<k>of<n>-<sha>` with the same prefix as the restore key, which starts it from the newest earlier run of that partition.
What that data holds and when a root may be skipped belongs to the `bin/fm-lint.sh` header: a root is skipped only when a marker for the exact key (lint definition, ShellCheck version, analysis mode, ratchet listing, and path plus content hash of the root and every sourced file) exists, and a marker is written only for a root that passed with reason `ok`.
Roots that pass only after the memory fallback are never stored, so they run on every invocation; they were 8 of 680 roots and about 15 percent of measured lint time on 2026-11-11, and shrinking their memory demand is what would let the cache cover them.
`tests/fm-lint.test.sh` proves the closure against the real ShellCheck, including a change two sources deep that must break a root and a changed definition that must miss.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the watch-triage members (now four files after upstream's busy-pane split) still sum to about 37 minutes of median CI test time (2026-11-11 refresh), and the largest single member sets the floor of any serial split.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses thirty long-lived Linux jobs (nineteen serial, three parallel, Herdr, seven lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession and keeps only the newest of close main pushes' runs, without changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate, Full suite verdict | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
