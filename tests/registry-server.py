# SPDX-License-Identifier: MIT
"""A cargo registry's HTTP side, for the local-registry check: it serves
the files under a directory, and stores the body and Authorization header
of a publish request beside it.

Usage: registry-server.py <port file> <directory>
"""

import http.server
import json
import sys
from pathlib import Path

port_file, root = Path(sys.argv[1]), Path(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)

    def do_PUT(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        (root.parent / "upload.bin").write_bytes(body)
        (root.parent / "upload-auth").write_text(self.headers.get("Authorization", ""))
        answer = json.dumps({"warnings": {"invalid_categories": [], "invalid_badges": [], "other": []}})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(answer.encode())


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
