set -u
eval "$(awk '$0 ~ "^github_checks_not_green\\(\\) \\{" {p=1} p {print} p && /^}$/ {exit}' bin/fm-pr-merge.sh)"
json=$(gh pr view 136 -R lstutzman/firstmate --json statusCheckRollup)
echo "--- real PR 136 rollup as reported (all green): not-green set:"; github_checks_not_green "$json"; echo "(end rc=$?)"
j=$(printf '%s' "$json" | jq -c '.statusCheckRollup |= map(
  if .name=="Behavior portable serial 11" then .conclusion="FAILURE"
  elif .name=="Behavior portable serial 12" then .conclusion="CANCELLED"
  elif .name=="Behavior portable serial 13" then .status="IN_PROGRESS" | .conclusion=null
  else . end)')
echo "--- same rollup with serial 11 FAILURE, 12 CANCELLED, 13 IN_PROGRESS: not-green set:"; github_checks_not_green "$j"; echo "(end rc=$?)"
