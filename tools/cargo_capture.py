# SPDX-License-Identifier: MIT
"""Let Cargo resolve normally while binding registry metadata to Nix inputs."""
from contextlib import contextmanager
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request

import tomlkit

from cargo_graph import VersionSelector
from cargo_inputs import candidates_of
from cargo_repository import prefix

CRATES_IO = 'https://github.com/rust-lang/crates.io-index'


def read_url(url, token=None):
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code not in (401, 403) or not token:
            raise
        request = urllib.request.Request(url, headers={'Authorization': token})
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()


class Registry:
    def __init__(self, index, token, directory):
        self.index, self.token, self.directory = index, token, Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.checkout = None
        self.config = None
        self.records = {}

    def read(self, relative):
        if self.index.startswith('sparse+'):
            return read_url(self.index.removeprefix('sparse+').rstrip('/') + '/' + relative, self.token)
        with self.lock:
            if self.checkout is None:
                self.checkout = self.directory / 'index'
                subprocess.run(['git', 'clone', '--quiet', '--depth', '1', self.index, str(self.checkout)],
                               check=True)
            path = self.checkout / relative
            if not path.is_file():
                raise FileNotFoundError(relative)
            return path.read_bytes()

    def configuration(self):
        with self.lock:
            if self.config is None:
                self.config = json.loads(self.read('config.json'))
            return self.config

    def download(self, name, version):
        checksum = self.records[(name, version)]['cksum']
        template = self.configuration()['dl']
        if not any(marker in template for marker in ('{crate}', '{version}', '{prefix}', '{lowerprefix}', '{sha256-checksum}')):
            template += '/{crate}/{version}/download'
        for key, value in {'{crate}': name, '{version}': version, '{prefix}': prefix(name),
                           '{lowerprefix}': prefix(name), '{sha256-checksum}': checksum}.items():
            template = template.replace(key, value)
        return read_url(template, self.token)


@contextmanager
def registry_bindings(registries, entries, paths, cargo, directory):
    """Ephemeral sparse source replacements preserve the original source IDs."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    candidates = candidates_of(entries)
    registry_map = {name: Registry(value['index'], value.get('token'), directory / name)
                    for name, value in registries.items()}
    selector_environment = dict(os.environ, CARGO_PURIFIER='0', CARGO_HOME=str(directory / 'selector-home'))
    selector = VersionSelector(cargo, selector_environment, directory / 'selectors')
    selector_lock = threading.Lock()
    route_secret = secrets.token_urlsafe(24)
    errors = []

    def chosen(name, requirement):
        choices = candidates[name]
        if len(choices) == 1:
            return choices[0]['version']
        exact = requirement.removeprefix('=')
        matching = [entry for entry in choices if entry['version'] == exact]
        if len(matching) == 1:
            return exact
        with selector_lock:
            version = selector.select(requirement, [entry['sourceVersion'] for entry in choices])
        matching = [entry for entry in choices if entry['sourceVersion'] == version]
        if len(matching) != 1:
            raise ValueError(f'ambiguous Nix input {name} {requirement}')
        return matching[0]['version']

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            parts = urllib.parse.urlsplit(self.path).path.strip('/').split('/')
            if len(parts) < 3 or parts[0] != route_secret or parts[1] not in registry_map:
                self.send_error(404)
                return
            registry = registry_map[parts[1]]
            relative = '/'.join(parts[2:])
            try:
                if relative == 'config.json':
                    original = registry.configuration()
                    data = json.dumps({'dl': base_url + '/' + parts[1] + '/download/{crate}/{version}',
                                       'api': original.get('api'), 'auth-required': False}).encode()
                elif len(parts) == 5 and parts[2] == 'download':
                    data = registry.download(parts[3], parts[4])
                else:
                    name = relative.rsplit('/', 1)[-1]
                    if name in candidates:
                        from cargo_repository import index_record
                        coordinates = set(paths)
                        rows = [index_record(tomlkit.parse((Path(paths[(entry['name'], entry['version'])])
                                                           / 'Cargo.toml').read_text()),
                                             entry['checksum'], coordinates)
                                for entry in candidates[name]]
                    else:
                        rows = [json.loads(line) for line in registry.read(relative).splitlines() if line]
                    for row in rows:
                        registry.records[(row['name'], row['vers'])] = dict(row)
                        for dependency in row['deps']:
                            name = dependency.get('package') or dependency['name']
                            if name in candidates:
                                dependency['req'] = '=' + chosen(name, dependency['req'])
                                dependency['registry'] = CRATES_IO
                    data = b''.join(json.dumps(row).encode() + b'\n' for row in rows)
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(data)
            except (FileNotFoundError, urllib.error.HTTPError) as error:
                if isinstance(error, FileNotFoundError) or error.code == 404:
                    self.send_error(404)
                else:
                    errors.append(str(error))
                    self.send_error(502)
            except Exception as error:
                errors.append(str(error))
                self.send_error(502)

        def log_message(self, *arguments):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    base_url = 'http://127.0.0.1:' + str(server.server_port) + '/' + route_secret
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = tomlkit.document()
    sources = config.setdefault('source', tomlkit.table())
    for name, registry in registry_map.items():
        mirror = 'purifier-' + hashlib.sha256(name.encode()).hexdigest()[:16]
        if name == 'crates-io':
            source = sources.setdefault('crates-io', tomlkit.table())
        else:
            source = sources.setdefault(name, tomlkit.table())
            source['registry'] = registry.index
        source['replace-with'] = mirror
        sources[mirror] = {'registry': 'sparse+' + base_url + '/' + name + '/'}
    patches = config.setdefault('patch', tomlkit.table()).setdefault('crates-io', tomlkit.table())
    for entry in entries:
        coordinate = entry['name'], entry['version']
        alias = 'purifier-' + hashlib.sha256('@'.join(coordinate).encode()).hexdigest()[:16]
        patches[alias] = {'package': entry['name'], 'path': str(paths[coordinate])}
    config_path = directory / 'capture.toml'
    config_path.write_text(tomlkit.dumps(config))
    try:
        yield config_path
        if errors:
            raise ValueError('Cargo input registry adapter failed: ' + '; '.join(errors))
    finally:
        server.shutdown()
        server.server_close()
