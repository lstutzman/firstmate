import http.server, os, socketserver, sys
LAB = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n)
        with open(os.path.join(LAB, 'jev', 'requests.log'), 'ab') as f:
            f.write(self.path.encode() + b' ' + body + b'\n')
        if self.path != '/v1/systemone':
            self.send_response(404); self.end_headers(); return
        with open(os.path.join(LAB, 'jev', 'response.json'), 'rb') as f:
            data = f.read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(os.path.join(LAB, 'jev', 'port'), 'w').write(str(srv.server_address[1]))
open(os.path.join(LAB, 'jev', 'pid'), 'w').write(str(os.getpid()))
srv.serve_forever()
