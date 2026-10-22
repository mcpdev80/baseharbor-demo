#!/usr/bin/env bash
set -euo pipefail

: "${DEMO_ROOT:?DEMO_ROOT is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${BASEHARBOR_TARGET:?fixture target is required}"
gate="${1:?failed gate is required}"
mode="${2:-diagnostics}"
[[ "$gate" =~ ^[a-z0-9-]+$ ]] || exit 2
case "$mode" in diagnostics|--unpause-owned) ;; *) exit 2 ;; esac

# The public, non-mutating Core preview owns the exact Target/project/resource
# inventory. Native name prefixes or an isolated daemon never grant ownership.
python3 - "$gate" "$mode" <<'PY'
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

gate, mode = sys.argv[1:]
root = Path(os.environ['DEMO_ROOT']).resolve(strict=True)
fixture = Path(os.environ['BASEHARBOR_DEMO_FIXTURE']).resolve(strict=True)
target = os.environ['BASEHARBOR_TARGET']
engine = os.environ['BASEHARBOR_TEST_RUNTIME']
if engine not in {'docker', 'podman'} or not re.fullmatch(r'[a-zA-Z0-9_.-]+', target):
    raise SystemExit('invalid fixture runtime or Target')
for key in ('XDG_DATA_HOME', 'XDG_CONFIG_HOME'):
    if fixture not in Path(os.environ[key]).resolve().parents:
        raise SystemExit('runtime owner outside isolated fixture')
output = Path(os.environ['ARTIFACT_DIR']) / 'failure-runtime' / gate
output.mkdir(parents=True, exist_ok=True)
redactor = root / 'scripts/redact-runtime-diagnostics.py'
native_env = dict(os.environ)
if engine == 'podman':
    native_env.pop('XDG_CONFIG_HOME', None)
    native_env.pop('XDG_DATA_HOME', None)
deadline = time.monotonic() + 60

def run(args, *, native=False, limit=20, inputdata=None):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('owned runtime diagnostic budget exhausted')
    process = subprocess.Popen(args, cwd=root, env=native_env if native else os.environ,
                               stdin=subprocess.PIPE if inputdata is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(inputdata, timeout=min(limit, remaining))
    except subprocess.TimeoutExpired:
        # A timed-out preview may have native descendants holding the pipes.
        # Kill its fresh process group, rather than waiting on those descendants.
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        raise
    result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    if len(result.stdout) > 1048576 or len(result.stderr) > 1048576:
        raise ValueError('owned runtime diagnostic output exceeds limit')
    return result

def retain(name, data):
    result = run([sys.executable, str(redactor)], inputdata=data, limit=5)
    if result.returncode:
        raise ValueError('diagnostic redaction failed')
    (output / name).write_bytes(result.stdout)

def token(value):
    return isinstance(value, str) and re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*', value)

def owned_resources():
    preview = run([os.environ['BAHA'], 'destroy', '--all', '--json'])
    if preview.returncode:
        retain('owner-preview-error.txt', preview.stderr)
        raise ValueError('canonical read-only runtime owner preview failed')
    report = json.loads(preview.stdout)
    if (not isinstance(report, dict) or report.get('preview') is not True or report.get('all') is not True or
            report.get('destroyed') is not False or not isinstance(report.get('resources'), list)):
        raise ValueError('invalid canonical read-only runtime owner preview')
    resources = set()
    if len(report['resources']) > 4096:
        raise ValueError('unbounded runtime owner inventory')
    for row in report['resources']:
        if not isinstance(row, dict):
            raise ValueError('invalid runtime owner resource')
        if row.get('target') != target or row.get('kind') != 'container':
            continue
        project, name = row.get('project'), row.get('name')
        if not token(project) or not token(name):
            raise ValueError('invalid selected runtime owner identity')
        resources.add((project, name))
    return resources

def owned_containers(resources):
    # Label-filtered metadata is deliberately insufficient by itself: recheck
    # both native label families and Core's exact observed native resource name.
    fields = ['.ID', '.Names'] + ['.Label "' + key + '"' for key in (
        'com.docker.compose.project', 'io.podman.compose.project',
        'com.docker.compose.service', 'io.podman.compose.service')]
    template = '\t'.join('{{' + field + '}}' for field in fields)
    selected = {}
    for project in sorted({project for project, _ in resources}):
        for label in ('com.docker.compose.project', 'io.podman.compose.project'):
            listed = run([engine, 'ps', '-a', '--no-trunc', '--filter', 'label=' + label + '=' + project,
                          '--format', template], native=True)
            if listed.returncode:
                raise ValueError('selected runtime label inventory failed')
            for line in listed.stdout.decode().splitlines():
                parts = line.split('\t')
                if len(parts) != 6:
                    raise ValueError('malformed selected runtime label inventory')
                identity, name, dp, pp, ds, ps = parts
                labels = ['' if value in ('<no value>', '<nil>') else value for value in (dp, pp, ds, ps)]
                dp, pp, ds, ps = labels
                projects, services = {v for v in (dp, pp) if v}, {v for v in (ds, ps) if v}
                if projects != {project} or len(services) > 1:
                    continue
                service = next(iter(services)) if services else ''
                # Core's public inventory already names the exact native
                # resource, including first-party Quadlet's non-ordinal name.
                if (project, name) not in resources or (service and not token(service)):
                    continue
                if not re.fullmatch(r'[0-9a-f]{12,64}', identity):
                    raise ValueError('invalid owned native container ID')
                row = (name, project, service)
                if identity in selected and selected[identity] != row:
                    raise ValueError('ambiguous owned native container identity')
                selected[identity] = row
    if resources != {(project, name) for name, project, _ in selected.values()}:
        raise ValueError('canonical runtime resources lack verified native ownership')
    return selected

errors = []
try:
    resources = owned_resources()
    selected = owned_containers(resources)
    (output / 'containers.tsv').write_text(''.join(
        '\t'.join((identity, *row)) + '\n' for identity, row in sorted(selected.items())))
    if mode == 'diagnostics':
        for command in ('plan', 'status'):
            result = run([os.environ['BAHA'], 'app', command, '--json'])
            retain('application-' + command + '.json', result.stdout + result.stderr)
    for identity in sorted(selected):
        result = run([engine, 'inspect', '--format', '{{json .State}}', identity], native=True)
        if result.returncode:
            errors.append('owned container state unavailable: ' + identity)
            continue
        try:
            state = json.loads(result.stdout)
            if not isinstance(state, dict) or type(state.get('Paused')) is not bool:
                raise ValueError('untyped pause state')
        except (ValueError, TypeError):
            errors.append('invalid owned container state: ' + identity)
            continue
        if mode == '--unpause-owned':
            if state['Paused']:
                resumed = run([engine, 'unpause', identity], native=True)
                if resumed.returncode:
                    errors.append('owned paused container could not resume: ' + identity)
        else:
            retain(identity + '.state.json', result.stdout)
            logs = run([engine, 'logs', '--tail', '300', identity], native=True)
            retain(identity + '.log', logs.stdout + logs.stderr)
            if logs.returncode:
                errors.append('owned container logs unavailable: ' + identity)
except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
    # Exceptions retain their safe class; raw preview/native messages are never
    # printed and no global inspection, unpause or removal fallback exists.
    errors.append('owned runtime evidence unavailable: ' + type(error).__name__)
(output / 'scope-result.json').write_text(json.dumps({
    'target': target, 'runtime': engine, 'mode': mode,
    'outcome': 'failure' if errors else 'success', 'errors': errors}, indent=2) + '\n')
if errors:
    print('fixture-owned runtime diagnostics/cleanup preparation incomplete; inspect scope-result.json', file=sys.stderr)
    raise SystemExit(1)
print('[acceptance] fixture-owned runtime ' + mode + ' complete', file=sys.stderr)
PY
