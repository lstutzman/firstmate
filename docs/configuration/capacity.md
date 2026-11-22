# Capacity

Part of the [configuration reference](../configuration.md).

## Lane capacity (config/lane-capacity)

The optional local, gitignored `config/lane-capacity` file says how many ship and scout lanes this home should run at once, and when it should stop taking more.
`bin/fm-capacity.sh` reads it to report how many lanes are open for queued work, alongside running lanes, 1-minute load against logical cores, free memory, and free disk.
With the file absent nothing changes: the report prints counts and host figures only, never invents a target, never advises holding dispatch, and nothing is published; a malformed value is reported as invalid rather than guessed.
Persistent secondmates hold no lane.
The file is a per-machine choice and is not inherited by secondmate homes, so each home owns its own numbers.

The first non-comment line is the cap, one non-negative integer, so a file holding only that integer keeps its earlier meaning, or the word `auto` for a measured budget instead of a fixed cap (below).
Optional lines follow, one key and its value per line, with `#` starting a comment:

```text
12                     # the cap: lanes this home runs at once
min-avail-gb 5         # keep this much memory available; a 1 GB lane must fit above it
min-disk-gb 60         # every disk row must stay above this many GB
pressure-file ~/.cache/lookout-beat/beat.json      # repeatable; a lookout.beat 1.x document
reserve-flag /var/run/fm-reserved.flag host reserved by the captain   # repeatable; admit nothing while the file exists
captain-idle 300       # opt-in, macOS: the captain counts as present when input was idle under 300 s
quota-provider claude  # opt-in: publish that provider's quota runway
max-load1 20           # keep a raw 1-minute load rule while beats replace it
admit-spawns           # opt-in: bin/fm-spawn.sh defers a fresh ship or scout this verdict does not admit
```

`pressure-file` and `reserve-flag` may repeat and take an absolute or `~/` path; a `reserve-flag` path may be followed by the label it is reported by.
Every other key may appear at most once.
An unknown key, a repeated single key, or a malformed value makes the whole file invalid: the report exits 1 naming the line, and the published facts carry the cap as invalid, because the captain's limits are never guessed.

A pressure file is any producer of the `lookout.beat` 1.x shape, read by its own file age on this machine; a missing, stale, or unreadable one is skipped with its reason and the host's own probes stand in, so a broken beat never blocks anything.
`captain-idle` reads input idle time locally and publishes only `present`, `idle`, or `away` (an away record), never the idle time itself.
`quota-provider` is the only key that makes the script reach the network, through `quota-axi`, bounded to five seconds.

### Auto budget

With `auto` on the first line there is no hand-set cap: on every call the script measures this machine's free memory, run queue, and disk, divides each by what one lane is learned to cost, and admits the smallest result, so one file works unchanged on a 16 GB laptop, a 48 GB workstation, a Windows PC under WSL2, and a Git Bash home on Windows itself.

```text
auto                   # measured budget; no fixed cap
max-lanes 16           # the one optional ceiling for this machine's lanes
min-gpu-free-gb 4      # only for work that uses the GPU; agent workers do not
```

`max-lanes` and `min-gpu-free-gb` are valid only with `auto`; `min-avail-gb`, `min-disk-gb`, and `max-load1` keep their meaning as the captain's safety floor.
There are no per-lane pins: the script samples each lane's process tree while the watcher publishes, learns the per-lane memory, CPU, and disk cost from this machine's last 30 measured lanes once five are recorded, and keeps that ledger in `state/lane-footprint.json`.
A lane whose process tree was never attributed is left out of that learning, so a backend that runs its agent outside the recorded worktree cannot teach a near-zero footprint.
Pressure stall, swap-in rate, macOS memory pressure, thermal limits, battery, and under WSL2 the Windows host's own memory close admission at once and reopen only after three clean readings, and growth after a reopen is damped, so admission does not flap.
A reading that cannot be taken never counts as clean: a gate that was closed stays closed with its clean count held until a real reading clears it, and a gate that was open stays unknown and is not judged.
The damped budget is what a spawn is admitted against: lanes started since the last publish count against it, so a burst of spawns between two publishes cannot exceed it.
A `pressure-file` beat can only lower the memory the budget sees, never raise it above the live reading.
Memory is the one reading the budget cannot do without: when it is unmeasurable the budget never admits on cpu alone, it falls back to the static `max-lanes` ceiling (or nothing without one), and the verdict's reasons say so.
Inside WSL2 the Linux view decides how many lanes fit in the VM and the Windows host view, read through `powershell.exe`, can only close admission.
On Windows itself (Git Bash or MSYS, where `uname -s` is `MINGW*` or `MSYS*`) the same `powershell.exe` view supplies the memory, cores, load, and power readings the MSYS `/proc` lacks.
The published facts add the budget, the per-lane footprint, the vitals, the gate states, and a ranked reclaim list of idle lanes (finished, no agent, PR handed off, parked, quiet) with their evidence; the list only recommends, and every cleanup or exit still goes through the normal landed-work checks.
Auto mode needs `jq`, and it never reaches the network.

While the file exists, the watcher runs `bin/fm-capacity.sh --publish` detached at most every 30 seconds, writing this home's lane facts to `state/lane-capacity.json`: its lanes, its cap and limits, its machine's pressure and boots, its watcher's freshness, and its own admission verdict.
Publishing is best-effort and never changes what the watcher does.
`bin/fm-capacity.sh --admit` checks the same verdict: it exits 0 when the verdict admits or the file is absent, and reports the reasons on stderr with exit 75 when it does not.
Only with `admit-spawns` does `bin/fm-spawn.sh` ask it, as `--spawn-gate`, before a fresh ship or scout: a refusal defers the spawn with exit 75 and leaves the task queued, and a malformed file that names `admit-spawns`, or a file that exists but cannot be read, refuses spawns rather than guessing; without that key no spawn reads the verdict, and nothing in the environment skips it.
The script's header owns the report line, the published document's fields, the verdict, the auto budget's rules and thresholds, the beat freshness rules, the host-constraint thresholds, and the probe fallbacks; `bin/fm-lane-vitals-lib.sh` owns how each vital is measured.

## Project capacity (config/project-capacity)

The optional local, gitignored `config/project-capacity` tells Firstmate how many workers a project can run at once on this machine, for a project whose machine-local resource - a heavy test suite, a local editor stack, a device - only serves a few workers at a time.
Without it, dispatch stays uncapped as `AGENTS.md` section 7 describes, and a surplus worker is launched only to spend full-context turns waiting for the resource.
The file lives in the machine's root Firstmate home, so every local secondmate home reads the same limit, and it holds one line per project:

```text
# heavy suite serves two workers
my-project 2
```

The name is the project's registered name, which is its clone directory name and may contain spaces, and the number, the last field on the line, is a positive integer.
A line that is only `#`, or that begins with `#` followed by whitespace, is a comment, as is a `#` line whose last field is not an integer.
A project name may begin with `#` when that `#` is written immediately against the rest of the name and the line ends with the project's capacity.
A name that is `#`, or that begins with `#` and a space, cannot be declared, because that line is a comment.
A place is held by every ship or scout on that project in the root home or any local secondmate home registered under it, including one working in a separate clone of the same origin, until its ready PR is recorded or it is cleaned up; a local-only ship or a scout holds its place until cleanup.
The declaration is matched by the spawning clone's directory name, so clones of the same origin share the cap only when they use that same directory name.
A clone of that origin under a different directory name finds no declaration and is not capped, though its workers are still counted as holders for a same-origin clone that is capped.
When every place is held, `bin/fm-spawn.sh` launches nothing, creates no record, leaves the backlog item queued, prints one `deferred:` line naming the holders, and exits 75, so Firstmate dispatches the item again once a place frees.
A malformed or unreadable file refuses every fresh ship or scout spawn until it is fixed, rather than guessing the intended limit, and so does a local home's state directory or task record that cannot be read while counting a capped project's holders.
Firstmate cannot see which part of a worker's life uses the resource, so the number bounds whole workers from launch to handoff, and the tightest resource every worker needs should decide it.
[`bin/fm-project-capacity-lib.sh`](../../bin/fm-project-capacity-lib.sh) owns the file format, what holds a place, and why concurrent spawns cannot both take the last one.
