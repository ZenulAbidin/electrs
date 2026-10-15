# HTTP/1.1 JSON-RPC proxy in front of regtest bitcoind. While the file
# FLAG (argv[3]) exists it drops the connection (no response) on any
# request that calls getrawmempool, like a bitcoind that goes away mid-update.
import http.server, os, sys, urllib.request
LISTEN, UPSTREAM, FLAG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if os.path.exists(FLAG) and b"getrawmempool" in body:
            print("proxy: dropping getrawmempool", flush=True)
            self.close_connection = True
            return
        req = urllib.request.Request(UPSTREAM, body, {"Authorization": self.headers["Authorization"], "Content-Type": "application/json"})
        try:
            resp = urllib.request.urlopen(req, timeout=30); code = 200; data = resp.read()
        except urllib.error.HTTPError as e:
            code = e.code; data = e.read()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
http.server.ThreadingHTTPServer(("127.0.0.1", LISTEN), H).serve_forever()
