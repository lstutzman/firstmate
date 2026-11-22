# Process events

Part of the [configuration reference](../configuration.md).

## Trusted external process-event adapters (config/extensions.d)

A home can explicitly enable a trusted external `process-event-adapter/1` package without adding package code to Firstmate.
This is one narrow extension type, not a general plugin or hook system.

[`extension-bindings.md`](../extension-bindings.md) owns the manifest, binding, trust, handshake, invocation-envelope, capability, version-compatibility, and authority-boundary contracts.
`bin/fm-extension.sh --help` and `bin/fm-procevent.sh --help` own exact command mechanics.

**Discovery and disabled behavior**

Discovery reads only mode-`0600` bindings under this home's mode-`0700` `config/extensions.d/` directory.
The current directory, projects, task copies, worker text, environment payloads, and Pi packages are never searched for extensions.

When the directory is absent, ordinary process-event commands perform only a bounded absence check, create no package or extension state, and preserve every built-in adapter path.

**Bind a trusted package**

Binding separates the package's own manifest from this home's explicit enablement.
`bind` performs these steps:

1. Validate the source package and compute every digest.
2. Copy the complete tree into the read-only content-addressed `data/extensions/packages/` store.
3. Perform the live handshake.
4. Atomically publish the enabled adapter-name subset.

The operator supplies trust and required consent facts, not hashes.

**Working state and cleanup**

`state/extensions/<extension-id>/` is created when binding performs its initial handshake and is that package's home-local working namespace for later verification and invocation.
`state/extension-invocations/` contains private host-owned invocation cleanup records, including residue retained after interruption; [extension cleanup safety](../extension-bindings.md#executable-protocol) owns their recovery rules.

This integrity boundary does not sandbox trusted same-user code, so bind only a package trusted to run with the operator's operating-system access.

The shipped `file-signal` package is a complete neutral example.
Copy it to a persistent directory outside every Git project or task copy, then bind and verify it:

```sh
mkdir -p "$HOME/.local/share/firstmate-packages"
cp -R docs/examples/process-event-extension \
  "$HOME/.local/share/firstmate-packages/file-signal"
bin/fm-extension.sh bind \
  "$HOME/.local/share/firstmate-packages/file-signal" \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
bin/fm-extension.sh list
bin/fm-extension.sh inspect org.firstmate.example.file-signal
bin/fm-extension.sh verify org.firstmate.example.file-signal
```

Use an absent destination for the copy so the source identity remains inspectable and reproducible.
For a non-default home, set `FM_HOME=<that-home>` on every command; local and remote secondmate homes bind the package independently, and bindings are not inherited.

**Bind on a remote secondmate**

For a configured remote secondmate, keep the package at the controller and transfer it through the authenticated `fm-on` route:

```sh
bin/fm-extension.sh remote-bind <secondmate-id> \
  /absolute/controller/path/to/file-signal \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
```

The command serializes only the validated extension package, stages it below the addressed remote home's fixed extension staging root, binds it there, and prints transfer and binding digests.
Registration uses `bin/fm-on.sh <secondmate-id> fm-procevent.sh ...`.

**Retire a binding**

After retiring every registration with its printed owner token and handling every captured result, retire the enabled remote binding and its exact staged transfer together with `bin/fm-on.sh <secondmate-id> fm-extension.sh retire-transfer <extension-id> --if-transfer-digest <transfer-digest> --if-binding-digest <binding-digest>`.
For a direct local binding, use `bin/fm-extension.sh retire-binding <extension-id> --if-binding-digest <binding-digest>` after the same process-event retirement and handling steps.

Both commands retain the retired identity reversibly and leave unrelated bindings and content-addressed installed packages unchanged.

**Register a completion source**

Register one file completion source with a path-safe source id and an explicit non-secret source configuration reference.
Credential values never belong in that reference, command argv, or a process-event result:

```sh
bin/fm-procevent.sh register-extension file-signal build-complete \
  --config-ref "file:/absolute/path/to/build-result.txt"
bin/fm-procevent.sh reconcile
```

`register-extension` prints the new registration's owner token and exact owner-matched retirement command.

**Classify and acknowledge results**

The source waits outside the conversational turn, and its completed result arrives through the existing process-event `check` path.
Classify the captured result through its immutable package identity with `bin/fm-procevent.sh classify <result-file>`, acknowledge it with the existing `handled` command only after it is handled, and use the printed `retire --if-owner` command when explicit retirement is needed.
The [host-error capture and retry contract](../extension-bindings.md#compatibility-and-failure-semantics) defines how repeated external host failures retain inspectable evidence while polling continues.

**Keep blocking sources out of the turn**

Never run the registered blocking source command directly in a conversational turn.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; built-in adapters retain their tracked `bin/fm-procevent-<adapter>.sh` commands, while an explicitly bound external adapter routes through the trusted host contract above.

`bin/fm-procevent-lavish.sh` is the first built-in adapter and wraps the published `lavish-axi poll` interface plus `lavish-axi reply` when the installed version supports synchronous reply acceptance.

**Open the Lavish artifact first**

Before arming any Lavish source, open its artifact with `lavish-axi` so the saved session identifies the board's server; reply and poll attempts derive their host and port from that session and refuse missing or invalid session evidence before posting or consuming a staged worker reply.

**Retry interrupted Lavish polls**

That adapter, and only that adapter, retries the one exact transient response a cut-short listener returns while its marks remain available (`error: Lavish Editor poll response was interrupted` with `code: SERVER_ERROR`), up to 12 times with poll starts at least 5 seconds apart, so an internal retry never reaches the runner as a captured result.
This start-to-start governor is a no-op after a normally blocking poll but caps an immediately returning poll under the shipped defaults independently of the owner lease and registration launch pacing.

Real feedback, ended and missing sessions, any other `SERVER_ERROR`, and that same interruption still standing once the bound is spent are all captured and announced normally; `FM_LAVISH_POLL_RETRY_DELAY` is a bounded 1 to 60 second test override for the interval only, and the runner itself stays adapter-agnostic.
An already-armed Lavish source keeps its registered listener command until it is retired and armed again, so retire the source, then arm it again to adopt this retry policy.
