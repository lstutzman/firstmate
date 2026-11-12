# Supervision

Part of the [configuration reference](../configuration.md).

## Wake auto-acknowledge (config/wake-auto-ack)

Create the empty, home-local `config/wake-auto-ack` file to let a supervisor's `bin/fm-wake-drain.sh --summary` acknowledge a batch of wakes that need no action.
The summary mode prints one line per wake with its kind, subject, the current state that decides it, and a verdict of `no-action` or `ACTION`, then the usual `WAKE_ACK_REQUIRED` command.
It is the supervision protocols' drain command, so the supervisor needs no second read to see whether a wake needs it.
With the file present, a main-actor `--summary` drain whose every row is `no-action` and whose presentation printed nothing else acknowledges the batch through the ordinary acknowledgement path and prints one `WAKE AUTO-ACKED` line.
A batch with one `ACTION` row, or any unread status, record divergence, due default, branch outcome or supervision alarm, acknowledges nothing.
An OPEN DECISIONS section does not block it only when its folded text is byte-identical to the one last presented to a model, which `state/.wake-open-decisions-presented` records as a hash; a new, changed or removed decision line wakes the model, and the unchanged section still prints on the next real drain.
A recovery episode with no queued rows, the case behind a `check: rearm-resurface` wake, is retired the same way when nothing else printed.
On a Claude primary that does not run the supervision host, the Stop hook applies the same decision before it wakes the model: `bin/fm-wake-drain.sh --quiet-ack` classifies the queued wakes and, when every one is `no-action`, acknowledges them in code and the hook re-arms the watcher without a model turn; any wake that needs judgement wakes the model as it does without the file, with nothing consumed.
The next `--summary` drain reports how many wakes were acknowledged that way and their kinds from `state/.wake-auto-acked`, once.
Every classified wake is also counted in `state/.wake-classified.jsonl` (`ts`, `seq`, `kind`, `verdict`, `auto_acked`), so the real no-action share can be measured.
The feature is off when the file is absent, is local to each home and is not inherited by secondmate homes, and the plain drain never acknowledges.
The classifier is `bin/fm-wake-summary.sh`, whose header owns the exact no-action cases; its verdict is the whole handling of such a wake.
Creating the file is a captain-class change to what a supervisor skips, so main routes it to the captain.

## Watcher backstop timer

`bin/fm-watch-backstop.sh` rings a home's own session when its supervision stays down with nothing inside the session to re-arm it, such as an idle resumed Claude session ([watcher continuity](../watcher-continuity.md#out-of-session-backstop)).
Install one user timer per home; no command needs sudo.
The session records its endpoint at session start and on resume, so the timer needs no endpoint configuration.
Run this once from the home's stable code directory, with `FM_HOME` set to the home:

```sh
FM_HOME="$PWD" bin/fm-watch-backstop.sh install
```

On Linux it writes a systemd user service and timer into `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user` and runs `systemctl --user enable --now` on the timer.
On macOS it writes a launchd agent into `$HOME/Library/LaunchAgents` and bootstraps it unless it is already loaded.
The generated files capture the installation shell's `PATH` and the home, and the unit names carry a per-home `<slug>`.
The command is idempotent: running it again keeps the existing files unchanged and enables the same timer, so nothing is overwritten or duplicated.
Session start's bootstrap runs `bin/fm-watch-backstop.sh verify`, which prints one `WATCH_BACKSTOP:` line naming this install command when the home has a recorded endpoint and the scheduler reports its timer as not installed or not enabled.
It never installs anything itself.
`bin/fm-watch-backstop.sh timer-files <linux|darwin> <dir>` writes the same files into another directory without touching a scheduler.
To turn it off and remove its files, run `FM_HOME="$PWD" bin/fm-watch-backstop.sh uninstall`, which touches only this home's own units.
Retiring a second mate runs the same removal for the retired home (`bin/fm-teardown.sh`); an ordinary task cleanup never removes a timer.
