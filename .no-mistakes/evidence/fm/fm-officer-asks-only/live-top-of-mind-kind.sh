#!/usr/bin/env bash
# Live drive: real bin/fm-officer.sh run progress, real urllib HTTPS fetch of Top of Mind
# from a local TLS server (self-signed cert trusted via SSL_CERT_FILE). Linear/GitHub CLIs
# are the test suite's fixture boundaries. Usage: live-top-of-mind-kind.sh <defs.sh>
set -u
. "$1"
make_world live
rm -f "$FAKEBIN/python3"   # real python3: no urlopen stub
CERT="$WORLD/tls"; mkdir -p "$CERT"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -keyout "$CERT/key.pem" -out "$CERT/cert.pem" 2>/dev/null
mkdir -p "$WORLD/www/api"
python3 -I - "$WORLD/www" "$CERT" > "$WORLD/port" 2>"$WORLD/server.log" <<'PY' &
import http.server, ssl, sys, os, functools
root, cert = sys.argv[1:]
H = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert+"/cert.pem", cert+"/key.pem")
s.socket = ctx.wrap_socket(s.socket, server_side=True)
print(s.server_address[1], flush=True); s.serve_forever()
PY
SRV=$!; trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 50); do [ -s "$WORLD/port" ] && break; sleep 0.1; done
PORT=$(cat "$WORLD/port")
LOG="https://localhost:$PORT/api/captains-log"
sed -i "s|; model: none;|; captains-log: $LOG; model: none;|" "$WORLD_HOME/data/officers.md"
cat "$WORLD_HOME/data/officers.md"
file="$WORLD_HOME/data/officers/progress/$DATE.json"
run() { SSL_CERT_FILE="$CERT/cert.pem" PROGRESS_WORLD="$WORLD" PATH="$FAKEBIN:$PATH" FM_HOME="$WORLD_HOME" \
  FM_OFFICER_NOW="$NOW" bash "$OFFICER" run progress --date "$DATE" >/dev/null; echo "officer exit=$?"; }
show() { echo "--- served /api/top-of-mind:"; cat "$WORLD/www/api/top-of-mind"; echo "--- start_requests:"
  jq -c '[.start_requests[] | {id, origin: .origin, why: .why}]' "$file" 2>/dev/null || jq -c '.start_requests' "$file"
  echo "--- coverage:"; jq -r '.coverage[]' "$file"; echo "--- top_of_mind digest:"; jq -r '.top_of_mind[]' "$file"
  echo "--- unclassified: $(jq .unclassified "$file")"; }

echo "===== S1: mixed kinds (statement / ask / no kind)"
cat > "$WORLD/www/api/top-of-mind" <<'JSON'
{"rows":[{"id":"pillow","words":"Still waiting for permission from Pillow Partners","status":"not-started","kind":"statement","work":[]},
{"id":"promo","words":"any promotion-blocking test should be deemed as serious as just about anything","status":"not-started","kind":"ask","work":[]},
{"id":"legacy","words":"Fix the legacy export crash","status":"not-started","work":[]}]}
JSON
run; show
echo "===== S2: invalid kind rejects the whole source"
printf '{"rows":[{"id":"bad","words":"Repair report","status":"not-started","kind":"maybe","work":[]},{"id":"ok","words":"Fix the ok thing","status":"not-started","kind":"ask","work":[]}]}\n' > "$WORLD/www/api/top-of-mind"
run; show
echo "===== S3: statement matching existing unauthorised work (backlog row + Linear PC-97)"
printf '## Queued\n\n- [ ] pillow-row - Pillow Partners integration\n' > "$WORLD_HOME/data/backlog.md"
linear_item PC-97 'Integrate Pillow feed'
cat > "$WORLD/www/api/top-of-mind" <<'JSON'
{"rows":[{"id":"pillow","words":"Still waiting for permission from Pillow Partners","status":"not-started","kind":"statement",
 "work":[{"home":"main","title":"Pillow Partners integration","status":"not-started"}],"links":[{"url":"https://linear.app/example/issue/PC-97"}]}]}
JSON
run; show
echo "--- rows carrying Top of Mind evidence (all sections):"; jq -c '[.start_requests[],.asks_for_lee[],.excluded[],.doing[],.done[] | select(any(.evidence[]?; startswith("Top of Mind"))) | {id,evidence}]' "$file"
echo "===== S3b control: same match as an ask lends authority"
sed -i 's/"kind":"statement"/"kind":"ask"/' "$WORLD/www/api/top-of-mind"
run; show
echo "===== S4: statement matching already-authorised work attaches as evidence only"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$WORLD_HOME/data/backlog.md"
linear_item PC-98 'Bug: export crash on large files'
cat > "$WORLD/www/api/top-of-mind" <<'JSON'
{"rows":[{"id":"crashnote","words":"The export crash is hurting Dawn's demos","status":"not-started","kind":"statement",
 "work":[],"links":[{"url":"https://linear.app/example/issue/PC-98"}]}]}
JSON
run; show
echo "--- rows carrying Top of Mind evidence (all sections):"; jq -c '[.start_requests[],.asks_for_lee[],.excluded[],.doing[],.done[] | select(any(.evidence[]?; startswith("Top of Mind"))) | {id,evidence,tags}]' "$file"
echo "--- server requests:"; grep -c 'GET /api/top-of-mind' "$WORLD/server.log"
