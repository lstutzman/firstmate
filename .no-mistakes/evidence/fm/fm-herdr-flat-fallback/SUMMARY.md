# Live Herdr lab validation — fm/fm-herdr-flat-fallback @ f796359

Host: herdr 0.9.5, real treehouse, real bin/fm-spawn.sh / fm-teardown.sh, named fm-lab-* sessions via bin/fm-herdr-lab.sh.

Lab isolation: the host's user plugin `herdr-automatic-rename` (server plugin + a ~/.zshrc pane hook)
renames every workspace to "[N] label", which breaks label matching at any commit. The suites were
run with a PATH-local herdr wrapper setting XDG_CONFIG_HOME=/tmp/fx.* (no plugins) and SHELL=/bin/bash
(no zsh hook), plus a throwaway "default" session inside that root for the lab tripwire. The live
default session was never touched (listed running before and after). Everything was trashed afterwards.

launcher-workspace-e2e.log: 15/15 ok, rc=0 — includes the new 2c (flat fallback -> 'firstmate workers',
launcher tabs/active tab/focus unchanged, reused by a 2nd spawn), 2d (two workers workspaces -> first adopted),
2e (relaunch rebind of a destroyed endpoint -> 'firstmate workers', not the launcher's workspace).

presentation-e2e.log: every case ok through the change-relevant ones (lock-contention flat fallback ->
'firstmate workers', post-create abort retires its journals, same-id retry is projected again,
cross-home flat fallback -> '2ndmate-alpha workers'). The final case fails: Herdr 0.9.5 accepts
`pane report-agent --agent test-agent` but leaves agent=null, so the untouched
fm_backend_herdr_projection_recovery_allows_flat duplicate-live-agent fixture cannot register its agent.
Unrelated to this change (diff does not touch that function).
