"""Execute the actual scoped shell helper against a hostile native inventory."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OWN = 'a' * 64
FOREIGN = 'b' * 64
CONFLICT = 'c' * 64
UNLISTED = 'd' * 64

FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
args=sys.argv[1:]
path=pathlib.Path(os.environ['FAKE_STATE'])
s=json.loads(path.read_text())
with open(os.environ['FAKE_CALLS'],'a') as f:
 f.write(json.dumps({'program':pathlib.Path(sys.argv[0]).name,'args':args,
                     'xdg_present':'XDG_DATA_HOME' in os.environ})+'\n')
if pathlib.Path(sys.argv[0]).name=='baha':
 if '--yes' in args:
  print('cleanup original failure',file=sys.stderr) if s.get('destroy_error') else None
  sys.exit(s.get('destroy_error',0))
 if args[:1]==['destroy']:
  if s.get('preview_hang'):
   child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(120)'])
   pathlib.Path(os.environ['FAKE_STATE']+'.child').write_text(str(child.pid))
   time.sleep(120)
  if s.get('preview_error'):
   print('x509 unavailable token=private-token',file=sys.stderr)
   sys.exit(3)
  print(json.dumps(s['preview']))
 else: print(json.dumps({'status':'unavailable','error':'original diagnostic'}))
 sys.exit(0)
if args[:1]==['ps']:
 if s.get('list_error'): sys.exit(4)
 # Deliberately ignore --filter. The caller must authenticate every row.
 for row in s['rows']:
  print('\t'.join(row))
 sys.exit(0)
identity=args[-1]
if identity not in s['containers']: sys.exit(5)
if args[:1]==['inspect']:
 if s.get('inspect_error'): sys.exit(6)
 print(json.dumps(s['containers'][identity]))
elif args[:1]==['logs']:
 print('database readiness failed; token=private-token')
 print('Authorization: Bearer private-auth',file=sys.stderr)
elif args[:1]==['unpause']:
 if s.get('unpause_error'): sys.exit(7)
 s['containers'][identity]['Paused']=False
 path.write_text(json.dumps(s))
else: sys.exit(8)
'''


class OwnedRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.fixture = self.base / 'fixture'
        self.fixture.mkdir()
        (self.fixture / 'config').mkdir()
        (self.fixture / 'data').mkdir()
        self.artifacts = self.base / 'artifacts'
        self.artifacts.mkdir()
        self.calls = self.base / 'calls.jsonl'
        self.state_file = self.base / 'state.json'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for name in ('baha', 'docker', 'podman'):
            path = self.bin / name
            path.write_text(FAKE)
            path.chmod(0o700)
        self.target = 'demo-docker'
        self.project = 'bh-demo-docker-shared'
        self.state = {
            'preview': {'all': True, 'preview': True, 'destroyed': False, 'resources': [
                {'target': self.target, 'project': self.project, 'kind': 'container',
                 'name': self.project + '-postgres-1'},
                {'target': 'foreign-target', 'project': 'foreign-project', 'kind': 'container',
                 'name': 'bh-demo-docker-foreign-1'}]},
            'rows': [
                [OWN, self.project + '-postgres-1', self.project, '', 'postgres', ''],
                [FOREIGN, 'bh-demo-docker-foreign-1', 'foreign-project', '', 'postgres', ''],
                [CONFLICT, self.project + '-postgres-1', self.project, 'foreign-project', 'postgres', ''],
                [UNLISTED, self.project + '-unknown-1', self.project, '', 'unknown', '']],
            'containers': {identity: {'Paused': True, 'Running': True}
                           for identity in (OWN, FOREIGN, CONFLICT, UNLISTED)}}
        self.env = dict(os.environ, DEMO_ROOT=str(ROOT), BASEHARBOR_DEMO_FIXTURE=str(self.fixture),
                        ARTIFACT_DIR=str(self.artifacts), XDG_CONFIG_HOME=str(self.fixture / 'config'),
                        XDG_DATA_HOME=str(self.fixture / 'data'), BASEHARBOR_TARGET=self.target,
                        BASEHARBOR_TEST_RUNTIME='docker', BAHA=str(self.bin / 'baha'),
                        FAKE_STATE=str(self.state_file), FAKE_CALLS=str(self.calls),
                        PATH=str(self.bin) + ':' + os.environ['PATH'])

    def save(self):
        self.state_file.write_text(json.dumps(self.state))

    def invoke(self, mode='diagnostics', timeout=10):
        self.save()
        return subprocess.run(['bash', str(ROOT / 'scripts/failure-runtime-diagnostics.sh'), 'test', mode],
                              env=self.env, capture_output=True, text=True, timeout=timeout)

    def recorded(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def native_actions(self):
        return [row['args'] for row in self.recorded() if row['program'] in ('docker', 'podman')]

    def handoff_foreign(self, check_error=0, remove_error=0):
        (self.fixture / 'new-edit-foreign.json').write_text('private fake owner receipt')
        self.env['FAKE_FOREIGN_CHECK_ERROR'] = str(check_error)
        self.env['FAKE_FOREIGN_REMOVE_ERROR'] = str(remove_error)
        shim = self.bin / 'python3'
        shim.write_text('#!' + sys.executable + '\n' + r'''
import json, os, pathlib, sys
args=sys.argv[1:]
if args[0].endswith('/tests/data-capabilities/new_edit.py'):
 with open(os.environ['FAKE_CALLS'],'a') as f:
  f.write(json.dumps({'program':'foreign-helper','args':args[1:]})+'\n')
 action=args[1]
 print('foreign sentinel '+action)
 code=os.environ['FAKE_FOREIGN_CHECK_ERROR' if action=='--foreign-check' else 'FAKE_FOREIGN_REMOVE_ERROR']
 sys.exit(int(code))
os.execv(sys.executable,[sys.executable,*args])
''')
        shim.chmod(0o700)

    def test_diagnostics_never_inspect_or_log_foreign_conflicting_or_unlisted_ids(self):
        result = self.invoke()
        self.assertEqual(0, result.returncode, result.stderr)
        actions = self.native_actions()
        self.assertTrue(all('--filter' in args for args in actions if args[0] == 'ps'))
        sensitive = [args for args in actions if args[0] in ('inspect', 'logs', 'unpause')]
        self.assertEqual({'inspect', 'logs'}, {args[0] for args in sensitive})
        self.assertTrue(all(args[-1] == OWN for args in sensitive), sensitive)
        retained = '\n'.join(path.read_text() for path in self.artifacts.rglob('*') if path.is_file())
        self.assertIn('database readiness failed', retained)
        self.assertNotIn('private-token', retained)
        self.assertNotIn('private-auth', retained)
        self.assertNotIn(FOREIGN, retained)

    def test_cleanup_unpauses_only_proven_owned_paused_id_once(self):
        result = self.invoke('--unpause-owned')
        self.assertEqual(0, result.returncode, result.stderr)
        actions = self.native_actions()
        self.assertEqual([['unpause', OWN]], [args for args in actions if args[0] == 'unpause'])
        state = json.loads(self.state_file.read_text())
        self.assertFalse(state['containers'][OWN]['Paused'])
        self.assertTrue(all(state['containers'][identity]['Paused'] for identity in (FOREIGN, CONFLICT, UNLISTED)))
        self.assertFalse(any(args[0] in ('rm', 'logs') for args in actions))

    def test_native_quadlet_exact_names_and_host_runtime_context(self):
        self.env['BASEHARBOR_TEST_RUNTIME'] = 'podman'
        native_name = self.project + '-postgres'
        self.state['preview']['resources'][0]['name'] = native_name
        self.state['rows'][0] = [OWN, native_name, self.project, self.project, 'postgres', 'postgres']
        result = self.invoke('--unpause-owned')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(all(not row['xdg_present'] for row in self.recorded() if row['program'] == 'podman'))
        self.assertTrue(all(row['xdg_present'] for row in self.recorded() if row['program'] == 'baha'))
        self.assertEqual([['unpause', OWN]], [args for args in self.native_actions() if args[0] == 'unpause'])

    def test_two_owned_containers_in_one_project_both_unpaused(self):
        second = 'e' * 64
        second_name = self.project + '-app-1'
        self.state['preview']['resources'].append({
            'target': self.target, 'project': self.project,
            'kind': 'container', 'name': second_name})
        self.state['rows'].append([second, second_name, self.project, '', 'app', ''])
        self.state['containers'][second] = {'Paused': True, 'Running': True}
        result = self.invoke('--unpause-owned')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({OWN, second},
                         {args[-1] for args in self.native_actions() if args[0] == 'unpause'})
        state = json.loads(self.state_file.read_text())
        self.assertFalse(state['containers'][OWN]['Paused'])
        self.assertFalse(state['containers'][second]['Paused'])
        self.assertTrue(all(state['containers'][identity]['Paused']
                            for identity in (FOREIGN, CONFLICT, UNLISTED)))
        receipt = json.loads((self.artifacts / 'failure-runtime/test/scope-result.json').read_text())
        self.assertEqual('success', receipt['outcome'])
        self.assertEqual([], receipt['errors'])

    def test_missing_unknown_or_failed_owner_never_uses_global_fallback(self):
        mutations = [lambda: self.state.update(preview_error=True),
                     lambda: self.state.update(preview=[]),
                     lambda: self.state['preview'].update(preview=False),
                     lambda: self.state['preview'].pop('resources'),
                     lambda: self.state['preview']['resources'][0].update(project='unsafe/project')]
        for change in mutations:
            with self.subTest(change=change):
                original = json.loads(json.dumps(self.state))
                change()
                self.calls.unlink(missing_ok=True)
                result = self.invoke('--unpause-owned')
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.native_actions())
                self.state = original

    def test_unresolved_or_conflicting_native_ownership_blocks_before_inspection(self):
        for rows in ([], [self.state['rows'][2]], [self.state['rows'][3]]):
            with self.subTest(rows=rows):
                self.state['rows'] = rows
                self.calls.unlink(missing_ok=True)
                result = self.invoke('--unpause-owned')
                self.assertNotEqual(0, result.returncode)
                self.assertFalse(any(args[0] in ('inspect', 'logs', 'unpause', 'rm')
                                     for args in self.native_actions()))
                receipt = json.loads((self.artifacts / 'failure-runtime/test/scope-result.json').read_text())
                self.assertEqual('failure', receipt['outcome'])

    def test_empty_owner_inventory_never_enumerates_native_daemon(self):
        self.state['preview']['resources'] = []
        result = self.invoke('--unpause-owned')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.native_actions())

    def test_owner_timeout_kills_native_descendants_and_retains_incomplete_result(self):
        self.state['preview_hang'] = True
        result = self.invoke('--unpause-owned', timeout=27)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], self.native_actions())
        child = int(Path(str(self.state_file) + '.child').read_text())
        status = Path('/proc') / str(child) / 'stat'
        self.assertTrue(not status.exists() or status.read_text().split()[2] == 'Z')
        receipt = json.loads((self.artifacts / 'failure-runtime/test/scope-result.json').read_text())
        self.assertEqual('failure', receipt['outcome'])

    def test_owned_query_inspection_and_unpause_errors_remain_incomplete(self):
        for error in ('list_error', 'inspect_error', 'unpause_error'):
            with self.subTest(error=error):
                self.state[error] = True
                self.calls.unlink(missing_ok=True)
                result = self.invoke('--unpause-owned')
                self.assertNotEqual(0, result.returncode)
                actions = self.native_actions()
                self.assertTrue(all(args[-1] == OWN for args in actions if args[0] in ('inspect', 'unpause')))
                receipt = json.loads((self.artifacts / 'failure-runtime/test/scope-result.json').read_text())
                self.assertEqual('failure', receipt['outcome'])
                self.state.pop(error)

    def cleanup(self, initial_status, signal=None):
        self.save()
        source = (ROOT / 'scripts/acceptance.sh').read_text()
        function_and_traps = source.split('cleanup() {\n', 1)[1].split('\ndeclare -A selected=', 1)[0]
        action = 'kill -' + signal + ' $$' if signal else 'exit ' + str(initial_status)
        script = 'cleanup() {\n' + function_and_traps + '\n' + action
        return subprocess.run(['bash', '-c', script], cwd=ROOT, env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_real_cleanup_trap_preserves_original_error_and_foreign_pause(self):
        result = self.cleanup(19)
        self.assertEqual(19, result.returncode, result.stderr)
        self.assertTrue(json.loads(self.state_file.read_text())['containers'][FOREIGN]['Paused'])
        self.assertTrue(any(row['program'] == 'baha' and '--yes' in row['args'] for row in self.recorded()))
        self.assertTrue(all(args[-1] == OWN for args in self.native_actions() if args[0] in ('inspect', 'logs', 'unpause')))

    def test_real_cancellation_traps_cleanup_owned_pause_and_preserve_foreign(self):
        for signal, status in (('INT', 130), ('TERM', 143)):
            with self.subTest(signal=signal):
                self.calls.unlink(missing_ok=True)
                result = self.cleanup(0, signal=signal)
                self.assertEqual(status, result.returncode, result.stderr)
                state = json.loads(self.state_file.read_text())
                self.assertFalse(state['containers'][OWN]['Paused'])
                self.assertTrue(state['containers'][FOREIGN]['Paused'])
                self.assertEqual([['unpause', OWN]], [args for args in self.native_actions() if args[0] == 'unpause'])

    def test_receipt_failure_cannot_replace_original_gate_exit(self):
        (self.artifacts / 'recovery-qualified.json').write_text('malformed receipt')
        result = self.cleanup(19)
        self.assertEqual(19, result.returncode, result.stderr)
        self.assertTrue(json.loads(self.state_file.read_text())['containers'][FOREIGN]['Paused'])

    def test_foreign_handoff_checks_after_core_destroy_before_separate_removal(self):
        self.handoff_foreign()
        result = self.cleanup(0)
        self.assertEqual(0, result.returncode, result.stderr)
        sequence = [(row['program'], row['args']) for row in self.recorded()
                    if row['program'] == 'foreign-helper' or '--yes' in row['args']]
        self.assertEqual('baha', sequence[0][0])
        self.assertEqual([('foreign-helper', ['--foreign-check']),
                          ('foreign-helper', ['--foreign-remove'])], sequence[1:])
        self.assertTrue((self.artifacts / 'foreign-check.txt').is_file())
        self.assertTrue((self.artifacts / 'foreign-remove.txt').is_file())

    def test_foreign_check_or_removal_failure_blocks_success_and_preserves_original_exit(self):
        for check_error, remove_error in ((8, 0), (0, 9)):
            for initial in (0, 19):
                with self.subTest(check_error=check_error, remove_error=remove_error, initial=initial):
                    self.handoff_foreign(check_error, remove_error)
                    self.calls.unlink(missing_ok=True)
                    result = self.cleanup(initial)
                    self.assertEqual(initial or 1, result.returncode, result.stderr)
                    actions = [row['args'] for row in self.recorded() if row['program'] == 'foreign-helper']
                    self.assertEqual([['--foreign-check'], ['--foreign-remove']], actions)
                    self.assertIn('cleanup: incomplete', result.stderr)

    def test_symlink_handoff_is_checked_and_cannot_silently_skip_cleanup_failure(self):
        self.handoff_foreign(check_error=8, remove_error=9)
        receipt = self.fixture / 'new-edit-foreign.json'
        receipt.unlink()
        receipt.symlink_to(self.fixture / 'missing-owner')
        result = self.cleanup(0)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertEqual([['--foreign-check'], ['--foreign-remove']],
                         [row['args'] for row in self.recorded() if row['program'] == 'foreign-helper'])

    def test_core_destroy_failure_still_checks_and_removes_the_gate_owned_sentinel(self):
        self.handoff_foreign()
        self.state['destroy_error'] = 7
        result = self.cleanup(0)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertEqual([['--foreign-check'], ['--foreign-remove']],
                         [row['args'] for row in self.recorded() if row['program'] == 'foreign-helper'])

    def test_successful_native_journey_cannot_skip_missing_foreign_owner_evidence(self):
        (self.artifacts / 'new-edit-sql.json').write_text('{"native_runtime_qualified":true}')
        result = self.cleanup(0)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn('private foreign sentinel owner receipt', (self.artifacts / 'foreign-check.txt').read_text())
        self.assertFalse(any(row['program'] == 'foreign-helper' for row in self.recorded()))

    def test_real_cleanup_trap_never_claims_success_after_incomplete_preparation_or_destroy(self):
        for error in ('preview_error', 'destroy_error'):
            with self.subTest(error=error):
                self.state[error] = 9
                self.calls.unlink(missing_ok=True)
                result = self.cleanup(0)
                self.assertNotEqual(0, result.returncode)
                self.assertIn('incomplete', result.stderr)
                self.assertTrue(json.loads(self.state_file.read_text())['containers'][FOREIGN]['Paused'])
                self.state.pop(error)


if __name__ == '__main__':
    unittest.main()
