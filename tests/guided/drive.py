#!/usr/bin/env python3
import os
import fcntl
import pty
import re
import select
import subprocess
import sys
import struct
import termios
import tempfile
import time
from pathlib import Path

ROOT = Path(os.environ.get("DEMO_ROOT", Path(__file__).resolve().parents[2]))
BAHA = os.environ.get("BAHA", "baha")
ARTIFACT_DIR = Path(os.environ.get("ARTIFACT_DIR", ROOT / "artifacts"))

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

def binary_supports_confirm_candidate(argv):
    """Feature detection: does the Core 'up' binary expose --confirm-candidate?

    Backward-compat guard: pinned Core that predates the candidate-consent
    surface has no such flag and fails with 'unknown option --confirm-candidate';
    a re-run with the flag would crash there, so we must never supply it for
    such a binary. We probe behaviorally rather than by --help, because the
    flag is parsed manually and is intentionally absent from the usage listing.

    Fail-closed by design (review-128a finding 2): support is only *affirmed*
    on a positive, unambiguous signal — the literal `unknown option
    --confirm-candidate` rejection string being ABSENT, i.e. the binary parsed
    the flag and proceeded past it. Every other probe outcome (missing/broken
    binary, timeout, an early/unknown error message, a non-zero exit) is treated
    as an inconclusive probe: report failure and never re-run `up` with the flag.
    A timeout is NOT evidence of support — a missing or hanging binary times out
    equally. We therefore classify by exit code 0 plus an empty, unambiguous
    output rather than by string presence with an unconditional timeout fallback.
    """
    probe_dir = None
    try:
        probe_dir = tempfile.mkdtemp(prefix="confirm-candidate-probe-")
        proc = subprocess.run(
            [*argv, "--no-input", "--confirm-candidate", "0" * 64],
            cwd=probe_dir,
            capture_output=True,
            text=True,
            timeout=20,
        )
        output = (proc.stdout + proc.stderr).replace("\r", "")
    except (OSError, subprocess.TimeoutExpired):
        # Missing/broken binary, permission error, or a hang. None of these is a
        # positive support signal: fail closed, do not re-run with the flag.
        return False
    # Positive, unambiguous signal: clean exit and a prompt that parsed the flag
    # and produced no rejection or any other early error message.
    if proc.returncode != 0:
        return False
    if "unknown option --confirm-candidate" in output:
        # Exact, documented unsupported response.
        return False
    if output.strip() == "":
        return True
    # Any other early/unrecognized message is an inconclusive probe.
    return False


def capture_confirm_hash(text):
    """Extract the candidate confirm-hash (64-hex) from the up transcript.

    Core prints 'Re-run with --confirm-candidate <digest> to acknowledge this
    exact submission.' The digest is the canonical content-hash of the exact
    submission being bound; supplying it on a re-run binds that submission.
    """
    match = re.search(
        r"Re-run with --confirm-candidate\s+([0-9a-f]{64})",
        text.replace("\r", ""),
    )
    return match.group(1) if match else None


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

def run_tty(name, argv, rules, env=None, timeout=900, no_output_timeout=None,
            cwd=None, expected_returncodes=(0,), capture=False):
    """Run a single PTY-driven process.

    By default a non-zero exit raises (the happy path asserts clean completion).
    capture=True returns the full transcript instead of raising on non-zero so
    the caller can drive a follow-up run (feature-detected candidate consent).
    """
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    log_path = ARTIFACT_DIR / f"{name}.txt"
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    master, slave = pty.openpty()
    # Bubble Tea requires an actual terminal size; an uninitialized PTY can
    # otherwise render no needs rows at all.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 140, 0, 0))
    proc = subprocess.Popen(
        argv,
        cwd=cwd or ROOT,
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
    try:
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
                            removed = len(buffer) - 65536
                            buffer = buffer[removed:]
                            cursor = max(0, cursor - removed)

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
                    if capture:
                        return rc, buffer
                    if not capture:
                        if rc not in expected_returncodes:
                            raise RuntimeError(f"{name} failed with exit code {rc}")
                        missing = [r.pattern.pattern for r in rules if not r.optional and not r.used]
                        if missing:
                            raise RuntimeError(f"{name} completed without expected prompts: {missing}")
                        return rc
                    # Capture path: still evaluate the exit code and non-optional
                    # rule coverage before the caller can treat this as success.
                    # The only permitted between-state is the documented
                    # candidate-consent abort: every non-optional interaction was
                    # driven (no missing required prompt) yet no clean returncode
                    # was produced because the candidate digest still has to be
                    # acknowledged on a follow-up run.
                    missing_capture = [
                        r.pattern.pattern for r in rules if not r.optional and not r.used
                    ]
                    if missing_capture:
                        # A required prompt never fired, or any other non-zero exit
                        # without a documented candidate-abort: never a PASS.
                        raise RuntimeError(
                            f"{name} completed with exit code {rc} but without "
                            f"expected prompts (missing: {missing_capture}); "
                            "candidate-consent abort is the only permitted non-zero "
                            "between-state"
                        )
                    if rc != 0:
                        raise RuntimeError(
                            f"{name} completed with non-zero exit code {rc} "
                            "(no clean completion, no documented candidate abort)"
                        )
                    return rc, buffer
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait(timeout=5)
        os.close(master)

init_rules = [
    Rule(r"Set them up now\? \[Y/n\]\s*$", "y\n", optional=True),
    Rule(r"Is this installation running on a machine where you write code\?.*?Choice \[1\]:\s*$", "1\n", optional=True),
    Rule(r"OpenBao recovery file \[[^\]]+\]:\s*$", "\n", optional=True),
    Rule(r"Accept\? \[Y/n\]:\s*$", "\n", optional=True),
    Rule(r"Use \d+ instead\? \[Y/n\]:\s*$", "\n", repeat=True, optional=True),
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
    Rule(r"Is this installation running on a machine where you write code\?.*?Choice \[1\]:\s*$", "1\n", optional=True),
    Rule(r"Set them up now\? \[Y/n\]\s*$", "y\n", optional=True),
    Rule(r"(?:Confirm the displayed provider changes|Achtung: confirm the displayed outcome without a working alternative) \(1/[12], plan [0-9a-f]{64}\)\? \[y/N\]:\s*$", "yes\n", repeat=True, optional=True),
    Rule(r"Achtung: confirm the displayed outcome without a working alternative \(2/2, plan [0-9a-f]{64}\)\? \[y/N\]:\s*$", "yes\n", repeat=True, optional=True),
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

if __name__ == "__main__":
    print("[phase] guided init: interactive capability selection", flush=True)
    run_tty("guided-init", [BAHA, "init"], init_rules, no_output_timeout=120)

    # First guided up: provision providers, bindings and workload. With the
    # candidate-consent Core this run fails closed after printing the confirm
    # hash (the staged provider-plan confirmations still complete first). We
    # capture the transcript rather than asserting clean completion, because the
    # candidate digest has to be acknowledged on a follow-up run.
    print("[phase] guided up: provision providers, bindings and workload", flush=True)
    first_rc, first_buffer = run_tty(
        "guided-up",
        [BAHA, "--verbose", "up"],
        up_rules,
        timeout=600,
        no_output_timeout=120,
        capture=True,
    )
    confirm_hash = capture_confirm_hash(first_buffer)
    if first_rc not in (0,):
        # First guided up failed closed (or any other non-zero exit). The only
        # permitted non-zero between-state here is the documented candidate
        # consent abort: a confirm-hash was printed and still has to be
        # acknowledged on a follow-up run. Without a hash this is an unexpected
        # failure, never a success.
        if confirm_hash is None:
            raise RuntimeError(
                f"guided up failed with exit code {first_rc} and no candidate "
                "confirm-hash was printed; refusing to treat a non-zero exit as "
                "success (candidate-consent abort requires the confirm-hash)"
            )
    if confirm_hash is not None:
        if not binary_supports_confirm_candidate([BAHA, "up"]):
            raise RuntimeError(
                "Core printed a candidate confirm-hash but the binary does not "
                "support --confirm-candidate (feature detection failed); refusing "
                "to fabricate consent"
            )
        print(
            f"[phase] guided up: candidate confirm-hash captured "
            f"{confirm_hash[:12]}…; re-running with --confirm-candidate",
            flush=True,
        )
        # The digest is computed from the unchanged repository source, so it stays
        # stable across runs. The second up re-answers the staged provider-plan
        # confirmations (handled by up_rules) and then binds the candidate
        # submission; a supported binary reaches READY here.
        run_tty(
            "guided-up-consented",
            [BAHA, "--verbose", "up", "--confirm-candidate", confirm_hash],
            up_rules,
            timeout=600,
            no_output_timeout=120,
        )
    print("[phase] guided up: READY reached; returning to acceptance gate", flush=True)
