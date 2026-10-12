import http.server, json, sys
log = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        req = json.loads(body)
        rec = {"path": self.path, "authorization": self.headers.get("Authorization"), "model": req.get("model"), "options": sorted(req["questions"]["rule"]["criteria"].keys())}
        open(log, "a").write(json.dumps(rec) + "\n")
        opts = rec["options"]
        probs = {o: 0.0 for o in opts}; probs["rule_1"] = 0.95; probs["default"] = 0.05
        out = {"answers": {"rule": {"choice": "rule_1", "confidence": 0.95, "probabilities": probs}}, "usage": {"input_tokens": 10, "output_tokens": 1}}
        b = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
s.serve_forever()
