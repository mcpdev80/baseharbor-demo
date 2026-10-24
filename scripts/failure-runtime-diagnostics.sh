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
# Rootless Podman inventory can exceed 20s after recovery; keep both the
# complete operation and each call bounded while allowing its native latency.
deadline = time.monotonic() + (90 if engine == 'podman' else 60)
call_limit = 60 if engine == 'podman' else 20

def run(args, *, native=False, limit=None, inputdata=None):
    if limit is None:
        limit = call_limit
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

def _rsplit_reason(reason):
    # Extract the trailing KEY of an accounted reason of the form
    # `… accounted with reason: KEY`. Returns KEY or None when the reason
    # does not carry an explicit accounted key.
    marker = 'accounted with reason: '
    if marker in reason:
        return reason.rsplit(marker, 1)[-1]
    return None

def owned_resources():
    # Capture the authoritative owner inventory ONCE, before any teardown can
    # mutate the runtime. The Core non-mutating preview is the snapshot; the
    # native verification below re-reads the same set against this snapshot so
    # the Quadlet daemon cannot tear it down between preview and verify.
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
    # Returns (selected, accounted_missing): containers Core owns but the daemon
    # already collected are reported as accounted rather than missing.
    fields = ['.ID', '.Names'] + ['.Label "' + key + '"' for key in (
        'com.docker.compose.project', 'io.podman.compose.project',
        'com.docker.compose.service', 'io.podman.compose.service')]
    template = '\t'.join('{{' + field + '}}' for field in fields)
    selected = {}
    accounted_missing = []
    for project in sorted({project for project, _ in resources}):
        matches = None
        # The owned-but-auto-collected race: the Quadlet daemon may remove an
        # owned container between Core's preview and the native verify. Retry the
        # inventory with backoff so a transient removal is caught on a later read.
        for attempt in range(1, 4):
            matches = []
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
                    matches.append((identity, row))
            if matches:
                break
            if attempt < 3:
                time.sleep(0.25)
        for identity, row in matches:
            # Commit every qualifying owned row of the project, not just the
            # last match: a project may own more than one container. The
            # ambiguity guard above still raises if one id is seen twice.
            selected[identity] = row
    # Owned resources absent from the native inventory are accounted only when
    # the daemon reports them exited/dead (legitimately collected by the Quadlet
    # monitor); a foreign or genuinely-lost gap is still a real failure, not an
    # auto-collection. Confirm state per missing project before accounting.
    missing = resources - {(project, name) for name, project, _ in selected.values()}
    if missing:
        verified_projects = {project for _name, project, _ in selected.values()}
        state_cache = {}
        for _project, _name in sorted(missing):
            if _project not in verified_projects:
                if _project not in state_cache:
                    found = None
                    label_filter = 'label=' + 'io.podman.compose.project' + '=' + _project
                    for attempt in range(1, 4):
                        ps_result = run([engine, 'ps', '-a', '--format', '{{.State}}',
                                         '--filter', label_filter], native=True)
                        if ps_result.returncode == 0:
                            found = ps_result
                            break
                        if attempt < 3:
                            time.sleep(0.25)
                    state_cache[_project] = found
                ps_result = state_cache[_project]
                if ps_result is not None and ps_result.returncode == 0:
                    states = {line.strip() for line in ps_result.stdout.decode().splitlines()}
                    if states & {'exited', 'dead'}:
                        accounted_missing.append((_project, _name))
    return selected, accounted_missing

errors = []
accounted = []
selected = None
resources = None
phase = 'owner-preview'
try:
    resources = owned_resources()
    phase = 'native-ownership'
    selected, accounted_missing = owned_containers(resources)
    for _project, _name in accounted_missing:
        accounted.append('owned container auto-collected by podman daemon — accounted with reason: ' + _project + '/' + _name)
    (output / 'containers.tsv').write_text(''.join(
        '\t'.join((identity, *row)) + '\n' for identity, row in sorted(selected.items())))
    phase = 'application-diagnostics'
    if mode == 'diagnostics':
        for command in ('plan', 'status'):
            result = run([os.environ['BAHA'], 'app', command, '--json'])
            retain('application-' + command + '.json', result.stdout + result.stderr)
    phase = 'owned-container-state'
    for identity in sorted(selected):
        # Podman race condition: Quadlet daemon may auto-collect containers
        # before we inspect them. Retry with backoff to tolerate the
        # difference between "owned but already removed" vs "truly missing".
        inspect_result = None
        inspect_ok = False
        for attempt in range(1, 4):
            inspect_result = run([engine, 'inspect', '--format', '{{json .State}}', identity], native=True)
            if inspect_result.returncode == 0:
                inspect_ok = True
                break
            if attempt < 3:
                time.sleep(0.25)
        if not inspect_ok:
            # Check if container was auto-collected by Quadlet (exited/dead state).
            # This is a legitimate state — the container was owned but already removed.
            # Accounted-with-reason is NOT an error: it does not affect outcome or exit.
            ps_result = run([engine, 'ps', '-a', '--format', '{{.State}}', identity], native=True)
            if ps_result.returncode == 0:
                state_str = ps_result.stdout.decode().strip()
                if state_str in ('exited', 'dead'):
                    accounted.append('owned container auto-collected by podman daemon — accounted with reason: ' + identity)
                    continue
            errors.append('owned container state unavailable after retries: ' + identity)
            continue
        try:
            state = json.loads(inspect_result.stdout)
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
            retain(identity + '.state.json', inspect_result.stdout)
            logs = run([engine, 'logs', '--tail', '300', identity], native=True)
            retain(identity + '.log', logs.stdout + logs.stderr)
            if logs.returncode:
                errors.append('owned container logs unavailable: ' + identity)
except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
    # Exceptions retain their safe class; raw preview/native messages are never
    # printed and no global inspection, unpause or removal fallback exists.
    errors.append('owned runtime evidence unavailable: ' + type(error).__name__ + ' (phase=' + phase + ')')
# Exact accounting contract (MERGE-118-G): the accounted set and the set of
# verified-native-owned containers must cover the preview exactly, with NO
# overlap. An accounted container that was ALSO natively verified (e.g. an
# exited/dead id that is still in `selected`) is an overlap; any preview
# resource neither verified nor accounted is a real gap. Either violation of
# exact equality is a failure, never a pass. Each accounted reason ends with
# `— accounted with reason: KEY` where KEY is either `PROJECT/NAME` (an
# auto-collected gap) or a native container id; extract KEY and compare. This
# runs only after the main loop completed (selected/accounted/resources all
# defined); an early exception in owned_containers or the inspect loop is
# already recorded above and must not re-enter this guard.
if selected is not None and accounted is not None and resources is not None:
    selected_pairs = {(project, name) for name, project, _ in selected.values()}
    accounted_keys = set()
    for _reason in accounted:
        _key = _rsplit_reason(_reason)
        if _key is None:
            continue
        if '/' in _key and not re.fullmatch(r'[0-9a-f]{12,64}', _key):
            _project, _name = _key.split('/', 1)
            accounted_keys.add((_project, _name))
        else:
            accounted_keys.add((_key, None))
    accounted_ids = {_key for _key in accounted_keys if _key[1] is None}
    accounted_gaps = {_key for _key in accounted_keys if _key[1] is not None}
    if selected_pairs & accounted_gaps:
        errors.append('canonical runtime accounting overlaps verified native ownership — exact equality violated')
    elif {identity for identity in selected} & accounted_ids:
        errors.append('canonical runtime accounting overlaps verified native ownership — exact equality violated')
    elif resources != selected_pairs | accounted_gaps:
        errors.append('canonical runtime resources lack verified native ownership — exact equality violated')
(output / 'auto-collected.json').write_text(json.dumps({
    'target': target, 'runtime': engine, 'mode': mode,
    'accounted': accounted, 'errors': errors}, indent=2) + '\n')
(output / 'scope-result.json').write_text(json.dumps({
    'target': target, 'runtime': engine, 'mode': mode,
    'outcome': 'failure' if errors else 'success', 'accounted': accounted, 'errors': errors}, indent=2) + '\n')
if errors:
    print('fixture-owned runtime diagnostics/cleanup preparation incomplete; inspect scope-result.json', file=sys.stderr)
    raise SystemExit(1)
print('[acceptance] fixture-owned runtime ' + mode + ' complete', file=sys.stderr)
PY
