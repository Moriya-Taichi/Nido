#!/usr/bin/env python3
"""Validate a mixed stack with real providers, then compile bindings from each schema.
Only init/validate/schema are used. No credentials, plan/apply, or cloud API calls.
"""
import json
import os
import pathlib
import platform
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
engine = os.environ.get('NIDO_TEST_ENGINE', 'terraform')
env = dict(os.environ, CHECKPOINT_DISABLE='1', TF_IN_AUTOMATION='1', NIDO_SWIFT_JOBS='1')
subprocess.run(['swift', 'build', '--jobs', '1'], cwd=root, env=env, check=True)
binary = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, env=env, text=True).strip())
versions = {'aws': '6.0.0', 'azurerm': '4.0.0', 'google': '6.0.0'}
with tempfile.TemporaryDirectory(prefix='nido-multicloud-') as tmp:
    directory = pathlib.Path(tmp)
    subprocess.run([binary / 'nido-multicloud-example', '--nido-output', directory], env=env, check=True)
    config_file = directory / 'main.tf.json'
    config = json.loads(config_file.read_text())
    assert set(config['terraform']['required_providers']) == set(versions)
    for name, version in versions.items():
        config['terraform']['required_providers'][name]['version'] = '= ' + version
    config_file.write_text(json.dumps(config))
    subprocess.run([engine, 'init', '-backend=false', '-input=false', '-no-color'], cwd=directory, env=env, check=True)
    subprocess.run([engine, 'validate', '-no-color'], cwd=directory, env=env, check=True)
    schema = subprocess.check_output([engine, 'providers', 'schema', '-json'], cwd=directory, env=env)
    schema_file = directory / 'schema.json'
    schema_file.write_bytes(schema)
    schemas = json.loads(schema)['provider_schemas']
    for name, version in versions.items():
        # OpenTofu uses its own registry hostname in the schema keys.
        source = next(key for key in schemas if key.endswith('/hashicorp/' + name))
        generated = directory / ('Generated' + name.title() + '.swift')
        types = sorted({key for kind in ['resource', 'data'] for key in config.get(kind, {}) if key.startswith(name + '_')})
        command = [str(binary / 'nido'), 'provider', 'generate', '--schema', str(schema_file),
                   '--provider', source, '--provider-version', '= ' + version,
                   '--prefix', 'Generated' + name.title(), '--output', str(generated)]
        for resource_type in types:
            command += ['--type', resource_type]
        subprocess.run(command, env=env, check=True)
        compiler = ['swiftc', '-typecheck', '-I', str(binary / 'Modules'), str(generated)]
        if sys.platform == 'darwin':
            compiler += ['-target', f'{platform.machine()}-apple-macosx13.0']
        subprocess.run(compiler, env=env, check=True)
        print(f'PASS {engine}: real {name} {version}, generated {len(types)} resource/data bindings')
