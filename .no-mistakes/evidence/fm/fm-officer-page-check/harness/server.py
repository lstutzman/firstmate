import http.server, ssl, sys, os, json
root, port, cert, key = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
log = open(os.path.join(root, "requests.log"), "a")
class H(http.server.BaseHTTPRequestHandler):
    def _go(self):
        log.write("%s %s\n" % (self.command, self.path)); log.flush()
        if self.command != "GET":
            self.send_response(405); self.send_header("Content-Length", "0"); self.end_headers(); return
        name = self.path.replace("/", "_").replace("?", "_").replace("=", "_")
        p = os.path.join(root, "pages", name)
        if not os.path.exists(p):
            self.send_response(404); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b'{}'); return
        body = open(p, "rb").read()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _go
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
