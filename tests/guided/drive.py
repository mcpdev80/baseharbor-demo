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

def root_workload_source_response(match, text):
    clean = ANSI_ESCAPE.sub("", text)
    candidates = re.findall(
        r"(?m)^\s*(\d+)[.)]\s+(compose|quadlet|kubernetes)\s+([^\r\n]+?)\s*$",
        clean,
    )
    for number, kind, path in candidates:
        if kind == "compose" and path.strip() == "compose.yaml":
            return number + "\n"
    raise RuntimeError("root Compose workload source was not offered by guided init")

def selected_capabilities():
    raw = os.environ.get("BASEHARBOR_GUIDED_CAPABILITIES")
    if raw is None:
        return set(range(1, 14))
    raw = raw.strip()
    if not raw:
        return set()
    selected = {int(value.strip()) for value in raw.split(",") if value.strip()}
    invalid = sorted(selected - set(range(1, 14)))
    if invalid:
        raise RuntimeError(f"invalid BASEHARBOR_GUIDED_CAPABILITIES values: {invalid}")
    return selected

def management_ui_enabled(name):
    raw = os.environ.get("BASEHARBOR_GUIDED_MANAGEMENT_UI", "all").strip().lower()
    if raw in ("", "none", "false", "0"):
        return False
    if raw in ("all", "true", "1"):
        return True
    return name in {value.strip() for value in raw.split(",") if value.strip()}

def capability_selection_response(match, text):
    clean = ANSI_ESCAPE.sub("", text)
    desired = selected_capabilities()
    if "Use ↑/↓ to move, Space to toggle, Enter to confirm." not in clean:
        return ",".join(str(number) for number in sorted(desired)) + "\n"

    choices = {}
    for mark, number in re.findall(r"\[([ x])\]\s+(\d+)\.\s+[^\r\n]+", clean):
        choices[int(number)] = mark == "x"
    if len(choices) < 13:
        raise RuntimeError("capability picker did not render all thirteen choices")

    keys = []
    for number in range(1, 14):
        if choices[number] != (number in desired):
            keys.append(" ")
        if number < 13:
            keys.append("\x1b[B")
    keys.append("\n")
    return keys

def run_tty(name, argv, rules, env=None, timeout=900, no_output_timeout=None):
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
    last_output = started
    last_heartbeat = started
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
                    last_output = time.monotonic()
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

            now = time.monotonic()
            if no_output_timeout is not None and now - last_output > no_output_timeout:
                proc.kill()
                elapsed = int(now - started)
                silent = int(now - last_output)
                raise RuntimeError(
                    f"{name} exceeded no-output timeout: elapsed={elapsed}s no-output={silent}s "
                    f"limit={no_output_timeout}s"
                )
            if now - last_heartbeat >= 15:
                elapsed = int(now - started)
                silent = int(now - last_output)
                print(f"\n[progress] {name}: still running · elapsed={elapsed}s · no-output={silent}s", flush=True)
                last_heartbeat = now

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
    Rule(r"Set them up now\? \[Y/n\]\s*$", "\n"),
    Rule(r"Is this installation running on a machine where you write code\?.*?Choice \[1\]:\s*$", "1\n"),
    Rule(r"TLS:.*?3\. Local development certificate.*?>\s*$", "3\n", optional=True),
    Rule(r"PostgreSQL host port \[\d+\]:\s*$", "\n", optional=True),
    Rule(r"OpenBao host port \[\d+\]:\s*$", "\n", optional=True),
    Rule(r"Accept\? \[Y/n\]:\s*$", "\n", optional=True),
    Rule(r"Use \d+ instead\? \[Y/n\]:\s*$", "\n", repeat=True, optional=True),
    Rule(r"OpenBao recovery file \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Install the BaseHarbor CA into the host trust store\? \[y/N\]:\s*$", "n\n", optional=True),
    Rule(r"Application name \[[^\]]+\]:\s*$", "demo\n"),
    Rule(r"Environment \[[^\]]+\]:\s*$", "\n"),
    Rule(r"Multiple workload sources detected:.*?Workload source.*?:\s*$", callback=root_workload_source_response, optional=True),
    Rule(r"Select application capabilities.*?13\. Application logs", callback=capability_selection_response),
    Rule(r"PostgreSQL management UI\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("sql") else "n\r", optional=True),
    Rule(r"Cache management UI\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("cache") else "n\r", optional=True),
    Rule(r"Durable key-value management UI\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("key-value") else "n\r", optional=True),
    Rule(r"Document database management UI\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("document-database") else "n\r", optional=True),
    Rule(r"Messaging management UI\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("messaging") else "n\r", optional=True),
    Rule(r"Object storage management UI\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("object-storage") else "n\r", optional=True),
    Rule(r"Secrets management UI\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("secrets") else "n\r", optional=True),
    Rule(r"Identity management UI\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("identity") else "n\r", optional=True),
    Rule(r"Observability management UI \(Prometheus\)\? \[y/N\]\s*$", callback=lambda m, t: "y\r" if management_ui_enabled("observability") else "n\r", optional=True),
    Rule(r"PostgreSQL instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Valkey / Redis cache instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Durable Valkey / Redis instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"MongoDB-compatible document database instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Messaging queue instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Messaging pub/sub instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Messaging stream instances \(comma-separated\) \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"S3 buckets instances \(comma-separated\) \[[^\]]+\]:\s*$", "uploads\n", optional=True),
    Rule(r"Manage this application secret with BaseHarbor\? \[Y/n\]\s*$", "\n", optional=True),
    Rule(r"BaseHarbor secret name \[APP_SECRET\]:\s*$", "\n", optional=True),
    Rule(r"Required for application startup\? \[Y/n\]\s*$", "\n", optional=True),
    Rule(r"Selection \[1\]:\s*$", "\n", optional=True),
    Rule(r"Additional application secret names .*?:\s*$", "\n", optional=True),
    Rule(r"Metrics workload service \[[^\]]+\]:\s*$", "demo-app\n", optional=True),
    Rule(r"Metrics container port.*?:\s*$", "8080\n", optional=True),
    Rule(r"OTLP signals .*?\[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Workload services allowed to use detected Runtime API operations .*?:\s*$", "demo-app\n", optional=True),
    Rule(r"Development domain \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Username \[developer\]:\s*$", "\n", optional=True),
    Rule(r"Use a securely generated password\? \[Y/n\]\s*$", "\n", optional=True),
    Rule(r"Write baseharbor\.yaml\? \[Y/n\]\s*$", "\n"),
]

up_rules = [
    Rule(r"TLS:.*?3\. Local development certificate.*?>\s*$", "3\n", optional=True),
    Rule(r"PostgreSQL host port \[\d+\]:\s*$", "\n", optional=True),
    Rule(r"OpenBao host port \[\d+\]:\s*$", "\n", optional=True),
    Rule(r"Accept\? \[Y/n\]:\s*$", "\n", optional=True),
    Rule(r"Use \d+ instead\? \[Y/n\]:\s*$", "\n", repeat=True, optional=True),
    Rule(r"OpenBao recovery file \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Configure now\? \[Y/n\]\s*$", "\n", optional=True),
    Rule(r"APP_SECRET value:\s*$", "acceptance-secret-value\n", optional=True),
    Rule(r"APP_SECRET value again:\s*$", "acceptance-secret-value\n", optional=True),
    Rule(r"Install the BaseHarbor CA into the host trust store\? \[y/N\]:\s*$", "n\n", optional=True),
]

print("[phase] guided init: interactive capability selection", flush=True)
run_tty("guided-init", [BAHA, "app", "init"], init_rules)
print("[phase] guided up: provision providers, bindings and workload", flush=True)
run_tty(
    "guided-up",
    [BAHA, "--verbose", "up"],
    up_rules,
    timeout=600,
    no_output_timeout=120,
)

print("[phase] guided up: READY reached; returning to acceptance gate", flush=True)
