#!/usr/bin/env bash
set -u
WT={run-worktree}
. "$WT/tests/officer-helpers.sh"
L=$(mktemp -d /tmp/surg-live/w.XXXX); cd "$L"
DATE=2026-10-23; TIP=0123456789abcdef0123456789abcdef01234567
# staging repo with a real staging branch
git init -q --bare stage.git; git init -q src; (cd src; git -c user.email=a@b -c user.name=a commit -q --allow-empty -m x; git push -q ../stage.git HEAD:refs/heads/staging); TIP=$(git --git-dir=stage.git rev-parse staging)
mkdir pages
jq -n '{jobs:[{id:"nightly-e2e",results:{kind:"e2e"},lastDone:{runId:"R1"}},{id:"nightly-old",results:{kind:"e2e"},lastDone:{runId:"R3"}},{id:"nightly-review",results:{kind:"review"},latest:{runId:"R2"}}]}' > pages/api_runs
jq -n --arg s "$TIP" '{result:{sha:$s},shared:{status:"failed",findings:[{key:"fp-a",title:"checkout pays",cause:"timed out",classification:"regression",rerun:"failed"},{key:"fp-b",title:"flaky",classification:"flaky",rerun:"passed (2 s)"},{key:"fp-d",title:"copy changed",classification:"intended change"}]}}' > pages/api_runs_nightly-e2e_results_R1
jq -n '{result:{sha:"deadbeefdeadbeef"},shared:{status:"failed",findings:[{key:"fp-o",title:"old run fail",cause:"x",classification:"regression"}]}}' > pages/api_runs_nightly-old_results_R3
jq -n '{result:{findings:[{id:"f1",severity:"critical",file:"A.cs",summary:"SQL from input"},{id:"f3",severity:"low",file:"C.cs",summary:"naming"}],filings:{filed:[]}}}' > pages/api_runs_nightly-review_results_R2
jq -n '{latest:{run:{run_id:"sweep-1",intake:{bugs:[{fp:"b1",title:"Crash on save",disposition:"new",severity:"P1"},{fp:"b2",title:"dup",disposition:"duplicate",severity:"P1"},{fp:"b3",title:"Odd",disposition:"unclear",severity:"P2"},{fp:"b5",title:"Wrong total",disposition:"new",severity:"P2"},{fp:"b7",title:"Checkout 500",disposition:"new",severity:"P3",environment:"production",class:"production-error"}],linear:{filed:[]}}}}}' > pages/api_sweeper-results
openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost 2>/dev/null
cat > srv.py <<'PY'
import http.server, ssl, os, sys
root=sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(os.path.join(root,"access.log"),"a").write("%s %s\n"%(self.command,self.path))
        f=os.path.join(root,"pages",self.path.strip("/").replace("/","_"))
        if os.path.isfile(f):
            b=open(f,"rb").read(); self.send_response(200); self.send_header("Content-Length",str(len(b))); self.send_header("Connection","close"); self.end_headers(); self.wfile.write(b); self.wfile.flush(); self.connection.unwrap()
        else: self.send_response(404); self.send_header("Content-Length","0"); self.end_headers(); self.wfile.flush(); self.connection.unwrap()
    def log_message(self,*a): pass
    def do_POST(self): open(os.path.join(root,"access.log"),"a").write("POST %s\n"%self.path); self.send_response(405); self.end_headers()
s=http.server.HTTPServer(("127.0.0.1",0),H)
c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain(os.path.join(root,"c.pem"),os.path.join(root,"k.pem")); s.socket=c.wrap_socket(s.socket,server_side=True)
open(os.path.join(root,"port"),"w").write(str(s.server_address[1])); s.serve_forever()
PY
python3 -I srv.py "$L" & SRV=$!; trap 'kill $SRV' EXIT
while [ ! -s port ]; do :; done; PORT=$(cat port)
export CURL_CA_BUNDLE=$L/c.pem
home=$L/home; officer_home "$home"; echo '{"sessions":[]}' > spec.json; officer_archive "$L/archive" "$DATE" spec.json
mkdir fb; cat > fb/linear-axi <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $L/linear.calls
case "\$1 \$2" in
 "label list") [ -f $L/labels.fail ] && { echo '{"ok":false,"error":{"code":"VALIDATION_ERROR","message":"x"}}'; exit 1; }; echo '{"ok":true,"data":{"labels":[{"name":"Bug"},{"name":"bug-sweep"},{"name":"scheduled-review"},{"name":"Runtime"}]}}';;
 "issue search") echo '{"ok":true,"data":{"issues":[]}}';;
 "issue create") case " \$* " in *" --verify "*) [ -f $L/verify.fail ] && { echo '{"ok":false,"error":{"code":"VERIFY_FAILED","message":"no"}}'; exit 1; }; echo '{"ok":true,"data":{"issue":{"identifier":"PC-501"}}}';; *) echo '{"ok":true,"data":{"dryRun":true}}';; esac;;
 *) echo '{"ok":false,"error":{"code":"UNKNOWN","message":"no"}}'; exit 1;;
esac
SH
chmod +x fb/linear-axi
reg() { printf -- '- surgeon - Triage plus intake (role: surgeon; cadence: daily 06:00; archive: %s; hosts: alpha; app: https://localhost:%s; staging-repo: %s; %smodel: none; added 2026-11-04)\n' "$L/archive" "$PORT" "$L/stage.git" "$1" > "$home/data/officers.md"; }
run() { PATH="$L/fb:$PATH" FM_OFFICER_NOW=1792823400 FM_HOME="$home" "$WT/bin/fm-officer.sh" run surgeon --date "$DATE"; }
J=$home/data/officers/surgeon/$DATE.json
echo "=== S1/S2: writes none ==="; reg ""; run; echo "exit=$?"
jq -r '.findings[]|"\(.source)/\(.job) \(.key) class=\(.class) sev=\(.severity) filing=\(.filing)"' $J
echo "linear calls with writes none: $(cat linear.calls 2>/dev/null | wc -l)"
echo "HTTP methods seen: $(cut -d' ' -f1 access.log | sort | uniq -c | tr '\n' ' ')"
echo "=== severity: high in digest json ==="; jq -c '[.findings[]|select(.severity=="high")|.key]' $J
echo "=== S3: writes linear, max-creates 1 ==="; mv $home/data/officers/surgeon $L/old.$RANDOM; : || /data/officers/surgeon; reg "writes: linear; team: PC; area: Runtime; max-creates: 1; "; run; echo "exit=$?"
jq -r '.findings[]|select(.class=="real")|"\(.key) sev=\(.severity) filing=\(.filing|tostring)"' $J
echo "--- linear calls in order:"; cut -c1-160 linear.calls
echo "=== S4: verify fails, not retried ==="; : > linear.calls; mv $home/data/officers/surgeon $L/old.$RANDOM; : || /data/officers/surgeon; touch verify.fail; run >/dev/null; echo "exit=$?"
jq -r '.findings[]|select(.class=="real")|"\(.key) filing=\(.filing|tostring)"' $J; echo "verify calls: $(grep -c -- --verify linear.calls)"; grep -c -- '--dry-run' linear.calls; mv verify.fail verify.off
echo "=== S5: label lookup fails ==="; : > linear.calls; mv $home/data/officers/surgeon $L/old.$RANDOM; : || /data/officers/surgeon; touch labels.fail; run; echo "exit=$?"
jq -r '.findings[]|select(.class=="real")|"\(.key) filing=\(.filing|tostring)"' $J; echo "create calls: $(grep -c 'issue create' linear.calls)"; mv labels.fail labels.off
echo "=== S6: second run skips already-filed fingerprint (lane ledger) ==="; mv $home/data/officers/surgeon $L/old.$RANDOM; : || /data/officers/surgeon; reg "writes: linear; team: PC; area: Runtime; "; run >/dev/null; : > linear.calls; mv $J $L/oldj.json; run >/dev/null; echo "exit=$?"
jq -r '.findings[]|select(.class=="real")|"\(.key) filing=\(.filing|tostring)"' $J; echo "create calls on rerun: $(grep -c 'issue create' linear.calls)"
echo "=== S7: production error class ==="; jq -r '.findings[]|select(.key=="b7")|"b7 env=production class=production-error P3 -> class=\(.class) sev=\(.severity)"' $J
echo "=== S8: register surgeon, retire triage ==="
h2=$L/home2; officer_home "$h2"; officer_registry "$h2" "$L/archive"
FM_HOME=$h2 "$WT/bin/fm-officer.sh" register triage; FM_OFFICER_NOW=1792823400 FM_HOME=$h2 "$WT/bin/fm-officer.sh" run triage --date $DATE >/dev/null; echo "triage run exit=$?"
printf -- '- surgeon - Triage plus intake (role: surgeon; cadence: daily 06:00; archive: %s; hosts: alpha; app: https://localhost:%s; staging-repo: %s; model: none; added 2026-11-04)\n' "$L/archive" "$PORT" "$L/stage.git" >> $h2/data/officers.md
FM_HOME=$h2 "$WT/bin/fm-officer.sh" register surgeon; FM_HOME=$h2 "$WT/bin/fm-officer.sh" retire triage
echo "registry now:"; cat $h2/data/officers.md | cut -c1-60; ls $h2/data/officers/triage/; ls $h2/state | grep officer
FM_OFFICER_NOW=1792823400 FM_HOME=$h2 "$WT/bin/fm-officer.sh" run surgeon --date $DATE | tail -1; jq -c '{role:.officer_role, archive_findings:(.archive_findings|length)}' $h2/data/officers/surgeon/$DATE.json
FM_OFFICER_NOW=1792823400 FM_HOME=$h2 "$WT/bin/fm-officer.sh" check surgeon
