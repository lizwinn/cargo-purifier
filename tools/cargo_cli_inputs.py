# SPDX-License-Identifier: MIT
"""Coordinate source pins, native capture, and temporary Cargo bindings."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import project_inputs
import tomlkit

from cargo_capture import registry_bindings
from cargo_graph import VersionSelector
from cargo_inputs import borrowed_manifests, candidates_of, input_packages
from cargo_repository import bind_supplied


def resolve(options, root, previous):
    previous_inputs = previous.get('projectInputs', [])
    references = getattr(options, 'input', None)
    if getattr(options, 'no_inputs', False):
        references = []
    elif references is None:
        references = [entry['reference'] for entry in previous_inputs]
    inputs = project_inputs.pin(references, previous_inputs, getattr(options, 'refresh_inputs', False))
    roots = Path(root) / 'target/cargo-purifier/inputs'
    views = project_inputs.native_views(inputs, 'cargo', roots)
    packages = input_packages(views)
    entries = [entry for entry, _ in packages.values()]
    paths = {}
    for view in views:
        repository = Path(view['repository'])
        catalog = json.loads(Path(view['catalog']).read_text())
        for entry in catalog['packages']:
            paths[(entry['name'], entry['version'])] = repository / '.sources' / (entry['name'] + '-' + entry['version'])
    return {'inputs': inputs, 'views': views, 'entries': entries, 'paths': paths, 'roots': roots}


def prune_roots(state):
    root = state['roots']
    if not state['inputs']:
        for name in ('vendor', 'prefetch'):
            path = root.parent / name
            if path.is_symlink():
                path.unlink()
        for name in ('stamp', 'config.toml'):
            (root.parent / name).unlink(missing_ok=True)
    if not root.exists():
        return
    for path in root.iterdir():
        number = path.name.split('-')[0]
        if path.is_symlink() and number.isdigit() and int(number) >= len(state['inputs']):
            path.unlink()


@contextmanager
def native_capture(root, state, configuration, cargo, original_home, mutation=False):
    if not state['entries']:
        yield None
        return
    with tempfile.TemporaryDirectory(prefix='cargo-input-capture-') as temporary:
        temporary = Path(temporary)
        home = temporary / 'home'
        home.mkdir()
        for filename in ('config.toml', 'config'):
            source = Path(original_home) / filename
            if source.is_file():
                shutil.copyfile(source, home / filename)
                break
        registries = {'crates-io': {
            'index': os.environ.get('CARGO_REGISTRIES_CRATES_IO_INDEX',
                                    configuration.indexes.get('crates-io', 'sparse+https://index.crates.io/')),
            'token': configuration.tokens.get('crates-io')}}
        for name, index in configuration.indexes.items():
            if name != 'crates-io':
                registries[name] = {'index': index, 'token': configuration.tokens.get(name)}
        with registry_bindings(registries, state['entries'], state['paths'], cargo, temporary / 'registry') as config:
            values = {'CARGO_HOME': str(home), 'CARGO_PURIFIER': '0',
                      'CARGO_PURIFIER_CAPTURE_CONFIG': str(config)}
            old = {key: os.environ.get(key) for key in values}
            os.environ.update(values)
            try:
                with borrowed_manifests(root, state['entries'], cargo, mutation=mutation):
                    yield home
            finally:
                for key, value in old.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value


def fetch(command, root, home, state, cargo):
    """Git sources carry their dependency metadata in the checkout itself."""
    if home is None:
        subprocess.run(command, cwd=root, check=True)
        return
    environment = dict(os.environ, CARGO_PURIFIER='0')
    if os.environ.get('CARGO_PURIFIER_CAPTURE_CONFIG'):
        command = [command[0], '--config', os.environ['CARGO_PURIFIER_CAPTURE_CONFIG'], *command[1:]]
    selector_environment = dict(environment, CARGO_HOME=str(Path(home).parent / 'git-selector-home'))
    selector = VersionSelector(cargo, selector_environment, Path(home).parent / 'git-selectors')
    candidates = candidates_of(state['entries'])
    for attempt in range(20):
        result = subprocess.run(command, cwd=root, env=environment, text=True, capture_output=True)
        if result.returncode == 0:
            if result.stderr:
                import sys
                sys.stderr.write(result.stderr)
            return
        changed = False
        for manifest in (Path(home) / 'git/checkouts').glob('**/Cargo.toml'):
            original = manifest.read_bytes()
            document = tomlkit.parse(original.decode())
            bind_supplied(document, candidates, selector)
            replacement = tomlkit.dumps(document).encode()
            if replacement != original:
                manifest.write_bytes(replacement)
                changed = True
        if not changed:
            raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)
    raise ValueError('Cargo Git source capture did not converge after metadata binding')
