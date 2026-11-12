# Backlog and decisions

Part of the [configuration reference](../configuration.md).

## Captain-hold deadline defaults (config/captain-hold-defaults)

The optional local, gitignored `config/captain-hold-defaults` file holds one word that sets what `bin/fm-captain-hold.sh answer <id> --deadline-default` does for a due deadline default.
`dry-run` (also the behavior when the file is absent, empty or says anything else) only appends what it would have answered, when and for which task to `state/captain-hold-default.log` and answers nothing.
`live` records the owner-generated words through the guarded answer path, labelled as not the captain's.
Going live is this one-line change; the wake drain lists due calls in both modes.
An optional `config/admission/captain-hold-defaults.rules` file, in the `bin/fm-reserved-classify.sh` rules format, classifies the paths a call declares with `hold --touches`; a flagged path or a missing file with `--touches` refuses the default.
[`captain-hold-lifecycle.md`](../captain-hold-lifecycle.md#deadline-defaults) owns the mechanism and the `bin/fm-captain-hold.sh` header owns the fields and refusals.
The file is home-local and is not inherited by secondmate homes.
