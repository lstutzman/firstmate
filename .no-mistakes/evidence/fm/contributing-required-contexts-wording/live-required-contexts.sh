set -u
src=bin/fm-pr-merge.sh
for f in github_urlencode_path_segment github_branch_rules_unavailable_on_plan github_read_required_contexts github_required_checks_missing; do
  eval "$(awk -v f="$f" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}$/ {exit}' "$src")"
done
PR_OWNER=lstutzman PR_REPO=firstmate
github_read_required_contexts main; echo "read rc=$? required=$FM_PR_GITHUB_REQUIRED error=${FM_PR_GITHUB_REQUIRED_ERROR:-none}"
json=$(gh pr view 136 -R lstutzman/firstmate --json statusCheckRollup)
echo "--- serial shard names reported at PR 136 head:"
printf '%s' "$json" | jq -r '.statusCheckRollup[] | (.name // .context)' | sort -u | grep -E 'serial'
echo "--- missing vs live required set (what the gate enforces today):"
github_required_checks_missing "$json" "$FM_PR_GITHUB_REQUIRED" '[]'; echo "(end; rc=$?)"
listed='["Full suite","Lint 1","Lint 2","Lint 3","Lint 4","Test coverage guard","Repo invariants","Stock macOS Bash snapshot compatibility","Behavior portable parallel 1","Behavior portable parallel 2","Behavior tests (Herdr)","Behavior timing aggregate","PR must be raised via no-mistakes"'
for i in $(seq 1 15); do listed="$listed,\"Behavior portable serial $i\""; done; listed="$listed]"
req=$(jq -c 'map({context:., app_id:null})' <<<"$listed")
echo "--- missing vs the CONTRIBUTING.md list, at PR 136 head:"
github_required_checks_missing "$json" "$req" '[]'; echo "(end; rc=$?)"
echo "--- adversarial: rollup with serial 15 dropped, live required set:"
j2=$(printf '%s' "$json" | jq -c '.statusCheckRollup |= map(select((.name // .context) != "Behavior portable serial 15"))')
github_required_checks_missing "$j2" "$FM_PR_GITHUB_REQUIRED" '[]'; echo "(end; rc=$? -> nothing refused)"
echo "--- adversarial: same rollup, if the listed contexts were required:"
github_required_checks_missing "$j2" "$req" '[]'; echo "(end; rc=$?)"
