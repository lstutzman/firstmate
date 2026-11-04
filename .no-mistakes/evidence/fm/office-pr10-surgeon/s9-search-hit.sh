#!/usr/bin/env bash
# S9 at HEAD: a fingerprint already in Linear skips the create; a fuzzy search hit without the marker does not.
set -u
WT={run-worktree}
DRV=~/.no-mistakes/evidence/01M6J4G67JWVBZWXY07DBYGRCA/surgeon-live-driver-r5.sh
# reuse the world setup (first 45 lines: repo, pages, TLS app server, fake linear-axi, reg/run helpers)
src=$(mktemp); sed -n '1,/^J=/p' "$DRV" > "$src"
. "$src"
FPA=$(printf "%s\0%s\0%s" nightly nightly-e2e fp-a | sha256sum | cut -d" " -f1); echo "$FPA" > search.hit
# fake linear-axi (external boundary): search for fp-a's marker hits PC-777 whose description holds the marker;
# every other search is a fuzzy hit PC-778 whose description does not.
cat > fb/linear-axi <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $L/linear.calls
case "\$1 \$2" in
 "label list") echo '{"ok":true,"data":{"labels":[{"name":"Bug"},{"name":"bug-sweep"},{"name":"scheduled-review"},{"name":"Runtime"}]}}';;
 "issue search") if [ "\$3" = "surgeon-fp:$FPA" ]; then echo '{"ok":true,"data":{"issues":[{"identifier":"PC-777"}]}}'; else echo '{"ok":true,"data":{"issues":[{"identifier":"PC-778"}]}}'; fi;;
 "issue view") if [ "\$3" = PC-777 ]; then echo '{"ok":true,"data":{"issue":{"identifier":"PC-777","description":"x surgeon-fp:$FPA y"}}}'; else echo '{"ok":true,"data":{"issue":{"identifier":"PC-778","description":"unrelated"}}}'; fi;;
 "issue create") case " \$* " in *" --verify "*) echo '{"ok":true,"data":{"issue":{"identifier":"PC-501"}}}';; *) echo '{"ok":true,"data":{"dryRun":true}}';; esac;;
 *) echo '{"ok":false,"error":{"code":"UNKNOWN","message":"no"}}'; exit 1;;
esac
SH
reg "writes: linear; team: PC; area: Runtime; max-creates: 1; "; : > linear.calls; run >/dev/null; echo "exit=$?"
jq -r '.findings[]|select(.class=="real")|"\(.key) filing=\(.filing|tostring)"' $J
echo "--- linear calls in order:"; cut -c1-110 linear.calls
echo "--- lane log of creates:"; grep -rh "PC-" $home/data/officers/surgeon/runs.log 2>/dev/null | tail -5
