# SPDX-License-Identifier: MIT
"""A native sparse Cargo registry that records uploads and serves them back."""
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import threading
from urllib.parse import urlsplit


@contextmanager
def registry():
    archives, records, uploads = {}, {}, []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            if path == '/index/config.json':
                data = json.dumps({'dl': address + '/download/{crate}/{version}', 'api': address}).encode()
            elif path.startswith('/download/'):
                _, _, name, version = path.split('/')
                data = archives.get((name, version))
            elif path.startswith('/index/'):
                name = path.rsplit('/', 1)[-1]
                rows = [row for (package, _), row in records.items() if package == name]
                data = b''.join(json.dumps(row).encode() + b'\n' for row in rows) if rows else None
            else:
                data = None
            if data is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_PUT(self):
            assert self.path == '/api/v1/crates/new'
            assert self.headers['Authorization'] == 'fixture-token'
            body = self.rfile.read(int(self.headers['Content-Length']))
            size, = struct.unpack('<I', body[:4])
            metadata = json.loads(body[4:4 + size])
            archive_size, = struct.unpack('<I', body[4 + size:8 + size])
            data = body[8 + size:]
            assert len(data) == archive_size
            coordinate = metadata['name'], metadata['vers']
            assert coordinate not in archives, 'existing coordinates must be reused'
            archives[coordinate] = data
            uploads.append(coordinate)
            dependencies = []
            for dependency in metadata['deps']:
                alias = dependency['explicit_name_in_toml'] or dependency['name']
                dependencies.append({'name': alias,
                    'package': dependency['name'] if alias != dependency['name'] else None,
                    'req': dependency['version_req'], 'kind': dependency['kind'],
                    'target': dependency['target'], 'features': dependency['features'],
                    'optional': dependency['optional'], 'default_features': dependency['default_features'],
                    'registry': dependency['registry']})
            records[coordinate] = {'name': coordinate[0], 'vers': coordinate[1], 'deps': dependencies,
                'cksum': hashlib.sha256(data).hexdigest(), 'features': {},
                'features2': metadata['features'], 'v': 2, 'yanked': False, 'links': metadata['links']}
            data = b'{}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    address = 'http://127.0.0.1:' + str(server.server_port)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield address, archives, records, uploads
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
