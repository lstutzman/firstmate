# Worker launch

Part of the [configuration reference](../configuration.md).

## Worker dependency setup (`config/spawn-setup/<project>/`)

To install dependencies before a new worker starts, add shell scripts to the effective home's `config/spawn-setup/<project>/` directory, where `<project>` is the project directory's basename.
`FM_CONFIG_OVERRIDE` selects a different config root when set.
This configuration is private and opt-in; without it, spawn behavior is unchanged.

| File | Effect |
| --- | --- |
| `<step>.sh` | Run this step with Bash, in filename order, starting in the isolated task copy. |
| `<step>.off` | Skip this step when this file exists. |
| `off` | Skip every step for this project when this file exists. |

Use trusted dependency-install commands only, keep their project writes inside the task copy, and never use `sudo`.
Setup uses the spawning process's environment and does not require executable script permissions.
Keep credentials out of the scripts and their output, because output is saved to the task's logs.
Fresh ship and scout launches run setup after the isolated copy is validated, its base is prepared, and the task record is published, before the worker starts, on every supported worker tool and runtime backend.
Setup runs after the home-wide task-set lock and the shared Treehouse project lock are released, so other spawns and slot returns are not held up by a long install; the task's own record lock stays held until launch.
Relaunches and persistent secondmates do not run setup.
Each enabled step runs independently with its own fixed 600-second deadline; a failed step does not skip later steps or prevent the worker from launching.
Output and the result go to `state/<task-id>.setup/<step>.log`.
A failure or timeout adds the step name and log path to the worker's private launch instructions, telling it to rerun the install inside its copy before testing.
[`bin/fm-spawn-setup.sh`](../../bin/fm-spawn-setup.sh) owns execution and reporting; [`tests/fm-spawn-setup.test.sh`](../../tests/fm-spawn-setup.test.sh) exercises the spawn integration.

For PropertyCompass2, create `config/spawn-setup/PropertyCompass2/10-npm.sh` locally with:

```bash
set -e
cd src/PropertyCompass.Web/client
npm ci
```

Create `config/spawn-setup/PropertyCompass2/20-dotnet.sh` locally with:

```bash
set -e
source scripts/dev-env.sh
export DOTNET_ROOT
dotnet restore PropertyCompass.sln
```

Use `20-dotnet.off` to disable only restore, or `off` to disable all PropertyCompass2 setup.
These examples describe local configuration; no private project setup is included in the repository.
