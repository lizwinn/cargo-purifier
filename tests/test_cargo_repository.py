# SPDX-License-Identifier: MIT
"""Native Cargo producer, exact archive reuse and ordinary downstream proof."""
import hashlib
import importlib.util
import io
import tarfile
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest

tools = Path(os.environ.get('CARGO_PURIFIER_TEST_TOOLS', Path(__file__).resolve().parents[1] / 'tools'))
sys.path.insert(0, str(tools))

spec = importlib.util.spec_from_file_location('cargo_repository', tools / 'cargo_repository.py')
repository = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repository)
import cargo_inputs
from cargo_capture import registry_bindings


class NativeRepository(unittest.TestCase):
    def test_native_package_graph_and_provided_reuse(self):
        cargo = os.environ['CARGO_REPOSITORY_TEST_CARGO']
        with tempfile.TemporaryDirectory(prefix='cargo-repository-test-') as temporary:
            root = Path(temporary)
            source = root / 'producer'
            def write(path, data):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(data)
            write(source / 'Cargo.toml', '[workspace]\nmembers=["lib","dep"]\nresolver="2"\n')
            write(source / 'dep/Cargo.toml', '[package]\nname="nix-dep"\nversion="2.0.0"\nedition="2021"\n[features]\nnative=[]\n')
            write(source / 'dep/src/lib.rs', '#[cfg(feature="native")] pub fn answer()->u32{41}\n#[cfg(not(feature="native"))] pub fn answer()->u32{0}\n')
            write(source / 'lib/Cargo.toml', '[package]\nname="nix-lib"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nbump_dep={package="nix-dep",version="2",path="../dep",default-features=false,features=["native"]}\n')
            write(source / 'lib/src/lib.rs', 'pub fn answer()->u32{bump_dep::answer()+1}\n')
            original = (source / 'lib/Cargo.toml').read_bytes()
            output = root / 'repository'
            repository.project({'identity': hashlib.sha256(b'Nix-source-graph').hexdigest(), 'src': str(source)}, output, root / 'catalog.json', cargo)
            repeat = root / 'repeat'
            repository.project({'identity': hashlib.sha256(b'Nix-source-graph').hexdigest(), 'src': str(source)}, repeat, root / 'repeat-catalog.json', cargo)
            catalog = json.loads((output / '.catalog').read_text())
            for entry in catalog['packages']:
                self.assertEqual((output / entry['archive']).read_bytes(), (repeat / entry['archive']).read_bytes(), 'native crate export is not reproducible')
            packages = {entry['name']: entry for entry in catalog['packages']}
            self.assertEqual((source / 'lib/Cargo.toml').read_bytes(), original)
            manifest = repository.crate_manifest((output / packages['nix-lib']['archive']).read_bytes())
            dependency = manifest['dependencies']['bump_dep']
            self.assertNotIn('path', dependency)
            self.assertEqual(dependency['version'], '=' + packages['nix-dep']['version'])
            self.assertEqual(dependency['features'], ['native'])
            bridge = root / 'bridge'
            write(bridge / 'Cargo.toml', '[package]\nname="bridge"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nnix-lib="99"\n')
            write(bridge / 'src/lib.rs', 'pub fn answer()->u32{nix_lib::answer()+1}\n')
            composed = root / 'composed'
            repository.project({'identity': hashlib.sha256(b'another-Nix-producer').hexdigest(), 'src': str(bridge),
                                'dependencies': [{'repository': str(output), 'catalog': str(root / 'catalog.json')}]},
                               composed, root / 'composed-catalog.json', cargo)
            for entry in packages.values():
                self.assertEqual((output / entry['archive']).read_bytes(), (composed / entry['archive']).read_bytes())
            combined = json.loads((composed / '.catalog').read_text())
            bridge_version = next(entry['version'] for entry in combined['packages'] if entry['name'] == 'bridge')
            consumer = root / 'consumer'
            write(consumer / 'Cargo.toml', '[package]\nname="consumer"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nbridge="='+bridge_version+'"\n')
            write(consumer / 'src/main.rs', 'fn main(){println!("{}",bridge::answer())}\n')
            write(consumer / '.cargo/config.toml', '[source.crates-io]\nreplace-with="nix"\n[source.nix]\nlocal-registry='+json.dumps(str(composed))+'\n')
            environment = dict(os.environ, CARGO_PURIFIER='0', CARGO_HOME=str(root / 'home'), CARGO_TARGET_DIR=str(root / 'target'))
            result = subprocess.check_output([cargo, 'run', '--offline', '--quiet'], cwd=consumer, env=environment, text=True)
            self.assertEqual(result, '43\n')
            self.assertEqual((bridge / 'Cargo.toml').read_text().count('99'), 1)
            # The incoming adapter presents a hydrated lock only to Cargo.
            app = root / 'incoming'
            original = '[package]\nname="incoming"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nnix-lib="99"\n'
            write(app / 'Cargo.toml', original)
            write(app / 'src/main.rs', 'fn main(){println!("{}",nix_lib::answer())}\n')
            write(app / 'Cargo.lock', 'version = 4\n')
            base = root / 'empty-vendor'
            write(base / 'Cargo.lock', 'version = 4\n')
            write(base / '.cargo/config.toml', '[source.crates-io]\nreplace-with="vendored"\n[source.vendored]\ndirectory="@vendor@"\n')
            prepared = root / 'prepared-vendor'
            cargo_inputs.prepare_vendor(base, [{'repository': str(output), 'catalog': str(root / 'catalog.json')}], prepared, cargo)
            config = root / 'prepared-config.toml'
            config.write_text((prepared / '.cargo/config.toml').read_text().replace('@vendor@', str(prepared)))
            cargo_inputs.materialize(app, prepared, cargo, check=False)
            subprocess.run([cargo, '--config', str(config), 'generate-lockfile', '--offline', '--quiet'],
                           cwd=app, env=environment, check=True)
            entries = json.loads((prepared / '.provided.json').read_text())
            bare = cargo_inputs.portable_lock((app / 'Cargo.lock').read_bytes(), entries)
            self.assertNotIn('checksum', bare.decode())
            parsed_lock = repository.tomllib.loads(bare.decode())
            self.assertEqual([package['name'] for package in parsed_lock['package']], ['incoming'])
            (app / 'Cargo.lock').write_bytes(bare)
            (app / 'Cargo.toml').write_text(original)
            cargo_inputs.materialize(app, prepared, cargo)
            result = subprocess.check_output([cargo, '--config', str(config), 'run', '--offline', '--locked', '--quiet'],
                                             cwd=app, env=environment, text=True)
            self.assertEqual(result, '42\n')
            self.assertEqual(cargo_inputs.portable_lock((app / 'Cargo.lock').read_bytes(), entries), bare)
            # Another Nix platform may give the supplied graph another identity.
            # Reconstruct its native records without changing the saved lock.
            alternate = root / 'alternate-repository'
            alternate_catalog = root / 'alternate-catalog.json'
            repository.project({'identity': hashlib.sha256(b'another-Nix-platform').hexdigest(),
                                'src': str(source)}, alternate, alternate_catalog, cargo)
            alternate_vendor = root / 'alternate-vendor'
            cargo_inputs.prepare_vendor(base, [{'repository': str(alternate),
                                               'catalog': str(alternate_catalog)}], alternate_vendor, cargo)
            alternate_entries = json.loads((alternate_vendor / '.provided.json').read_text())
            self.assertNotEqual(entries[0]['version'], alternate_entries[0]['version'])
            (app / 'Cargo.toml').write_text(original)
            (app / 'Cargo.lock').write_bytes(bare)
            cargo_inputs.materialize(app, alternate_vendor, cargo)
            config.write_text((alternate_vendor / '.cargo/config.toml').read_text()
                              .replace('@vendor@', str(alternate_vendor)))
            self.assertEqual(subprocess.check_output(
                [cargo, '--config', str(config), 'run', '--offline', '--locked', '--quiet'],
                cwd=app, env=environment, text=True), '42\n')
            self.assertEqual(cargo_inputs.portable_lock((app / 'Cargo.lock').read_bytes(), alternate_entries), bare)
            # An ordinary registry parent requests unavailable version99.
            # Cargo receives its original bytes, while its index binds the
            # transitive dependency to the immutable Nix package.
            parent = root / 'registry-parent'
            write(parent / 'Cargo.toml', '[package]\nname="registry-parent"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nnix-lib="99"\n')
            write(parent / 'src/lib.rs', 'pub fn answer()->u32{nix_lib::answer()+1}\n')
            subprocess.run([cargo, 'package', '--offline', '--exclude-lockfile', '--no-verify',
                            '--quiet', '--allow-dirty'], cwd=parent, env=environment, check=True)
            parent_crate = Path(environment['CARGO_TARGET_DIR']) / 'package/registry-parent-1.0.0.crate'
            parent_bytes = parent_crate.read_bytes()
            index = root / 'registry-index'
            record = repository.index_record(repository.crate_manifest(parent_bytes),
                                             hashlib.sha256(parent_bytes).hexdigest(), set())
            write(index / 're/gi/registry-parent', json.dumps(record)+'\n')
            write(index / 'config.json', json.dumps({'dl': 'file://' + str(parent_crate.parent) + '/{crate}-{version}.crate'}))
            for command in (['git', 'init', '--quiet'], ['git', 'add', '.'],
                            ['git', '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-m', 'registry']):
                subprocess.run(command, cwd=index, check=True, capture_output=True)
            captured = root / 'capture'
            write(captured / 'Cargo.toml', '[package]\nname="captured"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nregistry-parent="1"\n')
            write(captured / 'src/main.rs', 'fn main(){println!("{}",registry_parent::answer())}\n')
            input_paths = {(entry['name'],entry['version']): output / '.sources' / (entry['name']+'-'+entry['version']) for entry in entries}
            fresh = dict(environment, CARGO_HOME=str(root / 'fresh-capture-home'), CARGO_TARGET_DIR=str(root / 'capture-target'))
            with registry_bindings({'crates-io': {'index': 'file://' + str(index)}},
                                   entries, input_paths, cargo, root / 'capture-adapter') as capture_config:
                subprocess.run([cargo, '--config', str(capture_config), 'fetch'], cwd=captured, env=fresh, check=True)
                captured_lock = repository.tomllib.loads((captured / 'Cargo.lock').read_text())
                for item in captured_lock['package']:
                    if item['name'] in packages:
                        self.assertNotIn('checksum', item)
                        self.assertNotIn('source', item)
                result = subprocess.check_output([cargo, '--config', str(capture_config), 'run', '--offline', '--locked', '--quiet'],
                                                 cwd=captured, env=fresh, text=True)
                self.assertEqual(result, '43\n')



    def test_two_versions_aliases_and_independent_shared_identity(self):
        cargo = os.environ['CARGO_REPOSITORY_TEST_CARGO']
        with tempfile.TemporaryDirectory(prefix='cargo-multiple-versions-') as temporary:
            root = Path(temporary)
            def write(path, data):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(data)
            vendor = root / 'vendor'
            write(vendor / '.cargo/config.toml', '[source.crates-io]\nreplace-with="vendored"\n[source.vendored]\ndirectory="@vendor@"\n')
            for major in (1, 2):
                package = root / ('original-' + str(major))
                write(package / 'Cargo.toml', '[package]\nname="shared"\nversion="'+str(major)+'.0.0"\nedition="2021"\n')
                write(package / 'src/lib.rs', 'pub fn answer()->u32{env!("CARGO_PKG_VERSION_MAJOR").parse().unwrap()}\n')
                env = dict(os.environ, CARGO_PURIFIER='0', CARGO_HOME=str(root / 'capture-home'),
                           CARGO_TARGET_DIR=str(root / 'capture-target'))
                subprocess.run([cargo, 'package', '--offline', '--exclude-lockfile', '--no-verify',
                                '--allow-dirty', '--quiet'], cwd=package, env=env, check=True)
                archive = root / 'capture-target/package' / ('shared-'+str(major)+'.0.0.crate')
                data = archive.read_bytes()
                extracted = repository.extract_crate(data, vendor, 'shared', str(major)+'.0.0')
                (extracted / '.cargo-checksum.json').write_text(json.dumps({
                    'files': {}, 'package': hashlib.sha256(data).hexdigest()}))
            source = root / 'producer'
            write(source / 'Cargo.toml', '[workspace]\nmembers=["left","right"]\nresolver="2"\n')
            for name, major in [('left', 1), ('right', 2)]:
                write(source / name / 'Cargo.toml', '[package]\nname="'+name+'"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nalias={package="shared",version="'+str(major)+'"}\n')
                write(source / name / 'src/lib.rs', 'pub fn answer()->u32{alias::answer()}\n')
            toolchain = hashlib.sha256(b'shared-toolchain').hexdigest()
            request = {'identity': hashlib.sha256(b'producer-A').hexdigest(),
                       'sourceIdentity': hashlib.sha256(b'source-A').hexdigest(),
                       'projectorIdentity': toolchain, 'src': str(source), 'vendor': str(vendor)}
            output = root / 'repository'
            repository.project(request, output, root / 'catalog.json', cargo)
            catalog = json.loads((output / '.catalog').read_text())
            shared = [entry for entry in catalog['packages'] if entry['name'] == 'shared']
            self.assertEqual({entry['sourceVersion'] for entry in shared}, {'1.0.0', '2.0.0'})
            self.assertEqual(len({entry['version'] for entry in shared}), 2)
            other = root / 'independent'
            request = dict(request, identity=hashlib.sha256(b'producer-B').hexdigest(),
                           sourceIdentity=hashlib.sha256(b'source-B').hexdigest())
            repository.project(request, other, root / 'independent-catalog.json', cargo)
            other_catalog = json.loads((other / '.catalog').read_text())
            for entry in shared:
                twin = next(item for item in other_catalog['packages']
                            if item['name'] == 'shared' and item['sourceVersion'] == entry['sourceVersion'])
                self.assertEqual(entry['version'], twin['version'])
                self.assertEqual((output / entry['archive']).read_bytes(), (other / twin['archive']).read_bytes())
            bridge = root / 'bridge'
            write(bridge / 'Cargo.toml', '[package]\nname="bridge"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nleft="99"\nright="99"\nshared="1"\n')
            write(bridge / 'src/lib.rs', 'pub fn answer()->u32{left::answer()*10+right::answer()+shared::answer()}\n')
            composed = root / 'composed'
            repository.project({'identity': hashlib.sha256(b'bridge').hexdigest(), 'src': str(bridge),
                                'dependencies': [{'repository': str(output), 'catalog': str(root / 'catalog.json')}]},
                               composed, root / 'composed-catalog.json', cargo)
            combined = json.loads((composed / '.catalog').read_text())
            version = next(entry['version'] for entry in combined['packages'] if entry['name'] == 'bridge')
            consumer = root / 'consumer'
            write(consumer / 'Cargo.toml', '[package]\nname="consumer"\nversion="1.0.0"\nedition="2021"\n[dependencies]\nbridge="='+version+'"\n')
            write(consumer / 'src/main.rs', 'fn main(){println!("{}",bridge::answer())}\n')
            write(consumer / '.cargo/config.toml', '[source.crates-io]\nreplace-with="nix"\n[source.nix]\nlocal-registry='+json.dumps(str(composed))+'\n')
            env = dict(os.environ, CARGO_PURIFIER='0', CARGO_HOME=str(root / 'consumer-home'),
                       CARGO_TARGET_DIR=str(root / 'consumer-target'))
            result = subprocess.check_output([cargo, 'run', '--offline', '--quiet'], cwd=consumer, env=env, text=True)
            self.assertEqual(result, '13\n')


if __name__ == '__main__':
    unittest.main()
