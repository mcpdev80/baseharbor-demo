import json
import pathlib
import subprocess
import unittest


class DiagnosticPrivacyTests(unittest.TestCase):
    def scrub(self, source):
        script = pathlib.Path(__file__).with_name('redact-runtime-diagnostics.py')
        return subprocess.check_output(['python3', str(script)], input=source, text=True)

    def test_gateway_error_survives_without_request_headers(self):
        source = {'error': 'x509: certificate signed by unknown authority',
                  'request': {'headers': {'Authorization': ['Bearer private-auth'],
                                          'Cookie': ['session=private-cookie']}},
                  'token': 'private-token', 'upstream': 'https://user:private-pass@host:8443'}
        out = self.scrub('2026-10-14T22:00:00Z ' + json.dumps(source) + '\n')
        self.assertIn('x509: certificate signed by unknown authority', out)
        for secret in ['private-auth', 'private-cookie', 'private-token', 'private-pass']:
            self.assertNotIn(secret, out)
        self.assertEqual(json.loads(out)['request']['headers'], '<redacted>')

    def test_plain_credentials_and_private_key_are_not_emitted(self):
        out = self.scrub('password="multi word password" token=private-token '
                         'postgres://user:private-password@db/facts\n'
                         '-----BEGIN PRIVATE KEY-----\nprivate-key-content\n'
                         '-----END PRIVATE KEY-----\nconnection refused\n')
        for secret in ['multi word password', 'private-token', 'private-password', 'private-key-content']:
            self.assertNotIn(secret, out)
        self.assertIn('connection refused', out)


if __name__ == '__main__':
    unittest.main()
