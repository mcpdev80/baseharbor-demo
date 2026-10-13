#!/usr/bin/env python3
"""Compare private native consumer material; emit only verified booleans."""
import argparse, hashlib, json, os, pathlib, subprocess

p = argparse.ArgumentParser()
p.add_argument('phase', choices=['capture', 'verify'])
p.add_argument('--private-state', required=True)
a = p.parse_args()
engine = os.environ['CONTAINER_CLI']
if engine not in {'docker', 'podman'}:
    raise SystemExit('native runtime required')
env = dict(os.environ)
if engine == 'podman':
    env.pop('XDG_CONFIG_HOME', None)
    env.pop('XDG_DATA_HOME', None)
ids = subprocess.check_output([engine, 'ps', '-q'], env=env, text=True).split()
if not ids:
    raise SystemExit('no running native application')
items = json.loads(subprocess.check_output([engine, 'inspect', *ids], env=env, text=True))
prefix = 'bh-' + os.environ['BASEHARBOR_TARGET'].replace('.', '-') + '-'
selected = [i for i in items if (i.get('Config', {}).get('Labels') or {}).get('com.docker.compose.service') == 'demo-app' and (i.get('Config', {}).get('Labels') or {}).get('com.docker.compose.project', '').startswith(prefix)]
if len(selected) != 1:
    raise SystemExit('actual selected application is absent or ambiguous')
values = dict(x.split('=', 1) for x in selected[0]['Config'].get('Env', []) if '=' in x)
secret = values.get('APP_SECRET', '')
if not secret or secret == 'standalone-demo-secret':
    raise SystemExit('actual managed application secret was not delivered')
status = json.loads(subprocess.check_output([os.environ['BAHA'], 'status', '--json'], text=True))
identity = {k: status.get(k) for k in ('application_id', 'deployment_id')}
if not all(isinstance(v, str) and v for v in identity.values()):
    raise SystemExit('canonical application/deployment identity is unavailable')
# Digests stay in the private fixture directory, outside public artifacts.
state = {'identity': identity, 'secret': hashlib.sha256(secret.encode()).hexdigest()}
file = pathlib.Path(a.private_state)
fixture = pathlib.Path(os.environ['BASEHARBOR_DEMO_FIXTURE']).resolve()
if fixture not in file.resolve().parents:
    raise SystemExit('continuity state must remain inside the private isolated fixture')
if a.phase == 'capture':
    with file.open('x') as f:
        os.chmod(file, 0o600)
        json.dump(state, f)
else:
    if file.is_symlink() or file.stat().st_mode & 0o077:
        raise SystemExit('continuity owner is unprotected')
    if json.loads(file.read_text()) != state:
        raise SystemExit('restore replaced original application identity or delivered secret')
    file.unlink()
    print('Original canonical identity and actual managed secret delivery verified after recovery')
