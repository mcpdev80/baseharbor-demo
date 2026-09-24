#!/usr/bin/env python3
import os
import pty
import re
import select
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(os.environ["DEMO_ROOT"])
BAHA = os.environ["BAHA"]
ARTIFACT_DIR = Path(os.environ["ARTIFACT_DIR"])
ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)

class Rule:
    def __init__(self, pattern, response=None, callback=None, repeat=False, optional=False):
        self.pattern = re.compile(pattern, re.S)
        self.response = response
        self.callback = callback
        self.repeat = repeat
        self.optional = optional
        self.used = 0

    def match(self, text):
        return self.pattern.search(text)

    def value(self, match, text):
        if self.callback:
            return self.callback(match, text)
        return self.response

ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

def root_compose_response(match, text):
    clean = ANSI_ESCAPE.sub("", text)
    candidates = re.findall(r"(?m)^\s*(\d+)[.)]\s+([^\r\n]*?compose\.ya?ml)\s*$", clean)
    for number, path in candidates:
        if path.strip() == "compose.yaml":
            return number + "\n"
    raise RuntimeError("root compose.yaml was not offered by guided init")

def all_capabilities_response(match, text):
    clean = ANSI_ESCAPE.sub("", text)
    choices = re.findall(
        r"(?m)^\s*>?\s*\[([ x])\]\s+(\d+)\.\s+"
        r"(SQL Database \(PostgreSQL-compatible evidence\)|"
        r"Cache \(Redis/Valkey-compatible evidence\)|"
        r"Object Storage \(S3-compatible\)|Managed Secrets|"
        r"Metrics \(/metrics\)|OTLP telemetry|Application logs)\s*$",
        clean,
    )
    latest = choices[-7:]
    if len(latest) != 7 or [int(number) for _, number, _ in latest] != list(range(1, 8)):
        raise RuntimeError("capability checkbox state could not be parsed")

    keys = []
    for index, (mark, _, _) in enumerate(latest):
        if mark != "x":
            keys.append(" ")
        if index < len(latest) - 1:
            keys.append("\x1b[B")
    keys.append("\r")
    return "".join(keys)

def capability_selection_response(match, text):
    clean = ANSI_ESCAPE.sub("", text)
    if "Use ↑/↓ to move, Space to toggle, Enter to confirm." not in clean:
        return "1,2,3,4,5,6,7\n"

    choices = {}
    for mark, number in re.findall(r"\[([ x])\]\s+(\d+)\.\s+[^\r\n]+", clean):
        choices[int(number)] = mark == "x"
    if len(choices) < 7:
        raise RuntimeError("capability picker did not render all seven choices")

    keys = []
    for number in range(1, 8):
        if not choices[number]:
            keys.append(" ")
        if number < 7:
            keys.append("\x1b[B")
    keys.append("\n")
    return keys

def run_tty(name, argv, rules, env=None, timeout=900):
    log_path = ARTIFACT_DIR / f"{name}.txt"
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    master, slave = pty.openpty()
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=merged_env,
        close_fds=True,
    )
    os.close(slave)

    started = time.monotonic()
    buffer = ""
    cursor = 0
    with log_path.open("wb") as log:
        while True:
            if time.monotonic() - started > timeout:
                proc.kill()
                raise RuntimeError(f"{name} timed out")

            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    chunk = b""
                if chunk:
                    log.write(chunk)
                    log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    buffer += chunk.decode("utf-8", errors="replace").replace("\r", "")
                    if len(buffer) > 65536:
                        buffer = buffer[-65536:]
                        cursor = min(cursor, len(buffer))

                    search_text = buffer[cursor:]
                    responded = True
                    while responded:
                        responded = False
                        for rule in rules:
                            if rule.used and not rule.repeat:
                                continue
                            match = rule.match(search_text)
                            if not match:
                                continue
                            value = rule.value(match, buffer)
                            if value is not None:
                                if isinstance(value, (list, tuple)):
                                    for key in value:
                                        os.write(master, key.encode())
                                        time.sleep(0.05)
                                else:
                                    os.write(master, value.encode())
                            rule.used += 1
                            cursor += match.end()
                            search_text = buffer[cursor:]
                            responded = True
                            break

            rc = proc.poll()
            if rc is not None:
                try:
                    while True:
                        chunk = os.read(master, 4096)
                        if not chunk:
                            break
                        log.write(chunk)
                        sys.stdout.buffer.write(chunk)
                except OSError:
                    pass
                os.close(master)
                if rc != 0:
                    raise RuntimeError(f"{name} failed with exit code {rc}")
                missing = [r.pattern.pattern for r in rules if not r.optional and not r.used]
                if missing:
                    raise RuntimeError(f"{name} completed without expected prompts: {missing}")
                return

init_rules = [
    Rule(r"Application name \[[^\]]+\]:\s*$", "baseharbor-demo\n"),
    Rule(r"Environment \[[^\]]+\]:\s*$", "\n"),
    Rule(r"Multiple Compose files were detected\..*?>\s*$", callback=root_compose_response),
    Rule(r"Select application capabilities.*?7\. Application logs", callback=capability_selection_response),
    Rule(r"PostgreSQL instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n"),
    Rule(r"Valkey / Redis instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n"),
    Rule(r"S3 buckets instances \(comma-separated\) \[[^\]]+\]:\s*$", "uploads\n"),
    Rule(r"Manage this application secret with BaseHarbor\? \[Y/n\]\s*$", "\n"),
    Rule(r"BaseHarbor secret name \[APP_SECRET\]:\s*$", "\n"),
    Rule(r"Required for application startup\? \[Y/n\]\s*$", "\n"),
    Rule(r"Selection \[1\]:\s*$", "\n"),
    Rule(r"Additional application secret names .*?:\s*$", "\n"),
    Rule(r"Metrics workload service \[[^\]]+\]:\s*$", "demo-app\n", optional=True),
    Rule(r"Metrics container port.*?:\s*$", "8080\n", optional=True),
    Rule(r"OTLP signals .*?\[[^\]]+\]:\s*$", "\n"),
    Rule(r"Workload services allowed to use detected Runtime API operations .*?:\s*$", "demo-app\n", optional=True),
    Rule(r"Write baseharbor\.yaml\? \[Y/n\]\s*$", "\n"),
]

recovery_file = ARTIFACT_DIR / "openbao-recovery.json"
try:
    recovery_file.unlink()
except FileNotFoundError:
    pass

up_rules = [
    Rule(r"Public FQDN \(example: mailflow\.example\.com\) \[[^\]]+\]:\s*$", "\n"),
    Rule(r"TLS:.*?3\. Local development certificate.*?>\s*$", "3\n", optional=True),
    Rule(r"PostgreSQL host port \[\d+\]:\s*$", "\n", optional=True),
    Rule(r"OpenBao host port \[\d+\]:\s*$", "\n", optional=True),
    Rule(r"Accept\? \[Y/n\]:\s*$", "\n", optional=True),
    Rule(r"Use \d+ instead\? \[Y/n\]:\s*$", "\n", repeat=True, optional=True),
    Rule(r"OpenBao-recovery-key:[^\n]*\$\s*$", str(recovery_file) + "\n"),
    Rule(r"Configure now\? \[Y/n\]\s*$", "\n"),
    Rule(r"APP_SECRET value:\s*$", "acceptance-secret-value\n"),
    Rule(r"Install the BaseHarbor CA into the host trust store\? \[y/N\]:\s*$", "n\n", optional=True),
]

run_tty("guided-init", [BAHA, "app", "init"], init_rules)
run_tty(
    "guided-up",
    [BAHA, "up"],
    up_rules,
    env={"BASEHARBOR_TRACES_ENABLED": "true"},
    timeout=1200,
)
