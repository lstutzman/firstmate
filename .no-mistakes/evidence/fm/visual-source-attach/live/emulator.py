# Local Linear GraphQL emulator for linear-attach. Mode from $MODE_FILE: ok | ratelimit | forbidden.
import json, os, sys, http.server
LOG, MODE = sys.argv[2], sys.argv[3]
assets = {}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0)); data = self.rfile.read(n)
        open(LOG,"a").write("PUT %s %d bytes type=%s magic=%s\n" % (self.path, len(data), self.headers.get("Content-Type"), data[:8].hex()))
        self.send_response(200); self.send_header("Content-Length","0"); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n)); q, v = req["query"], req["variables"]
        mode = open(MODE).read().strip() if os.path.exists(MODE) else "ok"
        op = q.split("{")[1].split("(")[0].strip()
        open(LOG,"a").write("POST %s auth=%s vars=%s\n" % (op, self.headers.get("Authorization"), json.dumps(v, sort_keys=True)))
        if mode == "ratelimit": return self.send(400, {"errors":[{"message":"rate limited","extensions":{"code":"RATELIMITED"}}]})
        port = self.server.server_port
        if op == "issue":
            ident = v["id"]
            if "attachments" in q:
                return self.send(200, {"data":{"issue":{"identifier":ident,"attachments":{"nodes":[{"url":u} for u in assets.get(ident,[])]},"comments":{"nodes":[]}}}})
            return self.send(200, {"data":{"issue":{"id":"uuid-"+ident,"identifier":ident,"title":"t"}}})
        if op == "fileUpload":
            if mode == "forbidden": return self.send(200, {"errors":[{"message":"Forbidden: missing scope"}]})
            return self.send(200, {"data":{"fileUpload":{"success":True,"uploadFile":{"uploadUrl":"http://127.0.0.1:%d/upload/%s"%(port,v["filename"]),"assetUrl":"https://uploads.linear.example/%s"%v["filename"],"headers":[]}}}})
        if op == "attachmentCreate":
            ident = v["input"]["issueId"].replace("uuid-",""); assets.setdefault(ident,[]).append(v["input"]["url"])
            return self.send(200, {"data":{"attachmentCreate":{"success":True,"attachment":{"id":"a1","url":v["input"]["url"]}}}})
        self.send(200, {"errors":[{"message":"unknown op "+op}]})
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
