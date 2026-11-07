# Office provisioning

These are the ordered steps the main firstmate runs, in its own home on slartibartfast, to create the Navigator and Quartermaster offices.
[Offices](configuration.md#offices-dataofficesmd) owns the registry schema, each script's header owns its checks, and the `office-roles` skill owns each role's mandate.
The order matters: `bin/fm-officer.sh register` refuses a `consumer:` office whose lane check is not registered yet, so the officer edits come after the offices are seeded.
Run every step from the main home's firstmate checkout.

```sh
MAIN=$FM_HOME
NAV_HOME=$HOME/fm-homes/navigator
QM_HOME=$HOME/fm-homes/quartermaster
```

## 0. Check the projects

Each project an office dispatches must be registered and cloned in the main home; register a missing one through the `project-management` skill first.

```sh
for p in PropertyCompass2 firstmate skills fleet-app; do
  printf '%s: ' "$p"; FM_HOME=$MAIN bin/fm-project-mode.sh "$p" && test -d "$MAIN/projects/$p" || echo "MISSING $p"
done
```

## 1. Declare the PropertyCompass2 worker cap

```sh
grep -q '^PropertyCompass2 ' "$MAIN/config/project-capacity" 2>/dev/null \
  || printf 'PropertyCompass2 4\n' >> "$MAIN/config/project-capacity"
```

## 2. Write the two office lines

The Navigator starts on its tick alone: its `lane:progress` and `lane:surgeon:high` sources wait for the Ship's Surgeon officer and the progress officer's `start-home:` routing (step 9).

```sh
[ -f "$MAIN/data/offices.md" ] || printf '# Offices\n\n' > "$MAIN/data/offices.md"
cat >> "$MAIN/data/offices.md" <<'EOF'
- navigator - Drive PropertyCompass forward progress from Top of Mind, feature ideation and requested items (role: navigator; runs-on: slartibartfast; dispatch: PropertyCompass2; merge: none; merge-via: PropertyCompass2=slarti; auto-merge-classes: none; wip: 2; tick: every 2h; sources: tick; added 2026-11-04)
- quartermaster - Drive fleet, officer and agent self-improvement from friction, velocity, cost and page findings (role: quartermaster; runs-on: slartibartfast; dispatch: firstmate,skills,fleet-app; merge: firstmate,skills; merge-via: fleet-app=slarti; auto-merge-classes: none; wip: 2; tick: every 4h; sources: tick,lane:friction,lane:page-check; added 2026-11-04)
EOF
```

## 3. Write the master admission configs

The Quartermaster merges only what its classifier clears, and the seed copies these master files into its home.
Write each home path in a master as the literal token `@OFFICE_HOME@`: the seed replaces it with the office home it copies into, so the same master serves the Quartermaster and any other office that merges the project, such as the Librarian.

```sh
mkdir -p "$MAIN/config/admission"
for p in firstmate skills; do
  printf 'command=@OFFICE_HOME@/bin/fm-reserved-classify.sh --rules @OFFICE_HOME@/config/admission/%s.rules\nclasses=authority\nclear=none\n' \
    "$p" > "$MAIN/config/admission/$p"
done
cat > "$MAIN/config/admission/firstmate.rules" <<'EOF'
# authority: an office never merges a change to its own authority
AGENTS.md authority
bin/fm-pr-merge.sh authority
bin/fm-spawn.sh authority
bin/fm-brief.sh authority
bin/fm-home-seed.sh authority
bin/fm-office*.{sh,py} authority
bin/fm-officer*.{sh,py} authority
bin/fm-registry-line-lib.sh authority
bin/fm-project-mode.sh authority
bin/fm-pr-lib.sh authority
bin/fm-admission-lib.sh authority
bin/fm-reserved-classify.sh authority
bin/fm-merge-*.sh authority
bin/fm-captain-hold.sh authority
bin/fm-role*.sh authority
bin/fm-config-inherit-lib.sh authority
bin/fm-check-*.sh authority
.agents/skills/{office-roles,officer-roles,ask-user-authority,captain-hold-lifecycle,secondmate-provisioning}/** authority
.github/workflows/** authority
EOF
cat > "$MAIN/config/admission/skills.rules" <<'EOF'
global/fleet-rules.md authority
global/home/AGENTS.md authority
global/**/hooks/** authority
agent-config/**/settings*.json authority
EOF
```

## 4. Scaffold the role charters

```sh
FM_HOME=$MAIN bin/fm-brief.sh navigator --secondmate --office navigator PropertyCompass2
FM_HOME=$MAIN bin/fm-brief.sh quartermaster --secondmate --office quartermaster firstmate skills fleet-app
```

## 5. Seed the office homes

Each seed also registers the office's source checks in its home, and `arm-status` registers the silent check that writes the office's Status page file.

```sh
FM_HOME=$MAIN bin/fm-home-seed.sh navigator "$NAV_HOME" PropertyCompass2 --office navigator
FM_HOME=$MAIN bin/fm-home-seed.sh quartermaster "$QM_HOME" firstmate skills fleet-app --office quartermaster
FM_HOME=$NAV_HOME bin/fm-office.sh arm-status
FM_HOME=$QM_HOME bin/fm-office.sh arm-status
```

## 6. Publish each authority record and launch each office

```sh
FM_HOME=$MAIN bin/fm-office.sh publish navigator
FM_HOME=$MAIN bin/fm-office.sh publish quartermaster
FM_HOME=$MAIN bin/fm-spawn.sh navigator --secondmate
FM_HOME=$MAIN bin/fm-spawn.sh quartermaster --secondmate
```

## 7. Route the officers' digests

The friction digest moves to the Quartermaster, and the page-check digest goes to both main and the Quartermaster.
The progress digest stays with main until step 9, and main routes its in-scope starts to the offices as ordinary routed work.

```sh
sed -i.bak -e '/^- friction - /s/; added /; consumer: quartermaster; added /' \
  -e '/^- page-check - /s/; added /; consumer: main,quartermaster; added /' "$MAIN/data/officers.md"
FM_HOME=$MAIN bin/fm-officer.sh register friction
FM_HOME=$MAIN bin/fm-officer.sh register page-check
```

## 8. Confirm nothing is out of place

Each command prints nothing.

```sh
FM_HOME=$MAIN bin/fm-office.sh ensure
FM_HOME=$MAIN bin/fm-officer.sh ensure
FM_HOME=$NAV_HOME bin/fm-office.sh ensure
FM_HOME=$QM_HOME bin/fm-office.sh ensure
```

Then take the one measured check: hand the Navigator one queued item, wait for its next tick slot, and confirm it dispatched the item and its Status page shows it working.

```sh
FM_HOME=$MAIN bin/fm-tasks-axi.sh add <item-id> "<title>" --kind ship --repo PropertyCompass2 --queue
FM_HOME=$MAIN bin/fm-backlog-handoff.sh navigator <item-id>
until grep -q '"state": "working"' "$NAV_HOME/data/office-status.json" 2>/dev/null; do sleep 60; done
FM_HOME=$NAV_HOME bin/fm-tasks-axi.sh list
```

## 9. After the Ship's Surgeon and `start-home:` land

Add the Surgeon's `data/officers.md` line as its own documentation gives it, then register the Surgeon and retire triage, widen the Navigator's and the Quartermaster's sources (the progress officer's `start-home:` names both offices, so both must list `lane:progress`), and give the progress digest to the Navigator, in this order.

```sh
FM_HOME=$MAIN bin/fm-officer.sh register surgeon
FM_HOME=$MAIN bin/fm-officer.sh retire triage
sed -i.bak '/^- navigator - /s/sources: tick;/sources: tick,lane:progress,lane:surgeon:high;/' "$MAIN/data/offices.md"
FM_HOME=$NAV_HOME bin/fm-office.sh register-sources
sed -i.bak '/^- quartermaster - /s/sources: tick,lane:friction,lane:page-check;/sources: tick,lane:friction,lane:page-check,lane:progress;/' "$MAIN/data/offices.md"
FM_HOME=$QM_HOME bin/fm-office.sh register-sources
sed -i.bak -e '/^- progress - /s/; added /; consumer: navigator; start-home: navigator,quartermaster; added /' \
  -e '/^- surgeon - /s/; added /; consumer: main,navigator; added /' "$MAIN/data/officers.md"
FM_HOME=$MAIN bin/fm-officer.sh register progress
FM_HOME=$MAIN bin/fm-officer.sh register surgeon
FM_HOME=$MAIN bin/fm-office.sh ensure
```

### An office PR flagged `authority`

An office never merges a change to the files that define its own authority, and `bin/fm-pr-merge.sh` refuses an office PR its admission classifier flags `authority`.
`bin/fm-backlog-handoff.sh` moves only Queued items from main to a second mate, so it cannot hand an in-flight office task to main.
Today such a PR waits, held for the captain, until the captain defines its route to a merge; no tooling provides one yet.

## 10. Arm the lint ratchet's daily clock

Add `ratchet` to the Quartermaster's sources so its home wakes once per UTC day with the next file on `bin/fm-lint-ratchet.exceptions` ([Offices](configuration.md#offices-dataofficesmd) owns what the source prints); the Quartermaster then dispatches one ship worker for that file unless a ratchet PR for it is still open.

```sh
sed -i.bak '/^- quartermaster - /{/sources:\([^;]*[ ,]\)\{0,1\}ratchet[,;]/!s/sources: \([^;]*\);/sources: \1,ratchet;/;}' "$MAIN/data/offices.md"
FM_HOME=$QM_HOME bin/fm-office.sh register-sources
FM_HOME=$MAIN bin/fm-office.sh ensure
```

## 11. Feed the weekly tooling research to the Quartermaster

Add `research` to the Quartermaster's sources so each complete weekly tooling-research run reaches its home with the run's knowledge lines placed and its proposals digested ([Offices](configuration.md#offices-dataofficesmd) owns what the source does); the Quartermaster then judges each proposal under its standing authority and files a keyed `needs-decision` for any call only Lee can make.
If the runs are not under the Slarti home's `data/tooling-research/runs` on this machine, first write their directory to the Quartermaster home's `config/tooling-research-runs`.

```sh
sed -i.bak '/^- quartermaster - /{/sources:\([^;]*[ ,]\)\{0,1\}research[,;]/!s/sources: \([^;]*\);/sources: \1,research;/;}' "$MAIN/data/offices.md"
FM_HOME=$QM_HOME bin/fm-office.sh register-sources
FM_HOME=$MAIN bin/fm-office.sh ensure
```
