"""Retain native failure facts without credentials or HTTP request headers."""
import json
import re
import sys

SENSITIVE = re.compile(r'password|secret|token|authorization|cookie|access.?key|private.?key|headers', re.I)
ASSIGNMENT = re.compile(r'(?i)((?:password|secret|token|authorization|cookie|access[_-]?key|client[_-]?secret)[\w-]*[\s"\x27]*[=:][\s"\x27]*)([^\s,}\]"\x27]+)')
QUOTED = re.compile(r'(?i)((?:password|secret|token|authorization|cookie|access[_-]?key|client[_-]?secret)[\w-]*[\s"\x27]*[=:]\s*)(["\x27])[^"\x27]*\2')
CREDENTIAL_URL = re.compile(r'([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s@]+@')
BEARER = re.compile(r'(?i)\bBearer\s+[^\s,"\x27]+')


def protected(value):
    if isinstance(value, dict):
        return {key: '<redacted>' if SENSITIVE.search(key) else protected(item)
                for key, item in value.items()}
    if isinstance(value, list):
        return [protected(item) for item in value]
    if isinstance(value, str):
        return scrub(value)
    return value


def scrub(value):
    value = CREDENTIAL_URL.sub(r'\1<redacted>@', value)
    value = BEARER.sub('Bearer <redacted>', value)
    value = QUOTED.sub(r'\1<redacted>', value)
    return ASSIGNMENT.sub(r'\1<redacted>', value)


private_block = False
for line in sys.stdin:
    if '-----BEGIN ' in line and 'PRIVATE KEY-----' in line:
        private_block = True
    if private_block:
        if '-----END ' in line and 'PRIVATE KEY-----' in line:
            private_block = False
            print('<private key redacted>')
        continue
    try:
        # Native logs may prefix JSON with a timestamp. Never fall back to
        # plain text for a valid structured request/header record.
        structured = line[line.index('{'):] if '{' in line else line
        print(json.dumps(protected(json.loads(structured))))
    except (ValueError, TypeError):
        print(scrub(line.rstrip('\n')))
