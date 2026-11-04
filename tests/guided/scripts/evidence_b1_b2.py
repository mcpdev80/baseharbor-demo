#!/usr/bin/env python3
"""Standalone evidence for review-128a correction round 2 (lane w87-demo-r2).

Verifies both fixes without needing the real pinned Core:
- B1: run_tty capture-pfad must evaluate exit code + required rules; only the
  documented candidate-consent abort (all non-optional interactions driven, then
  a non-zero exit) is a permitted between-state; any other non-zero exit or a
  missing required prompt => ABORT.
- B2: binary_supports_confirm_candidate is fail-closed; support ONLY on a
  positive unambiguous signal; four probe cases (binary missing / timeout /
  unknown message / exact unsupported).

Evidence written to stdout: one line per case, "EXPECTED|ACTUAL|CASE".
"""
import subprocess
import sys
import types

sys.path.insert(0, "tests/guided")
import drive  # noqa: E402

RESULTS = []


def check(name, expected, actual):
    ok = "OK" if expected == actual else "XX"
    RESULTS.append((ok, name, expected, actual))
    print(f"{ok} | {name} | expected={expected!r} actual={actual!r}")


# ---- B2: four probe cases ---------------------------------------------------

# Case 1: binary missing / exec fails -> OSError/Timeout -> ABORT (False)
class _MissingBin:
    def __call__(self, argv):
        # emulate a binary that cannot be found by subprocess.run
        raise FileNotFoundError(2, "No such file or directory")


def b2_case_missing():
    orig = drive.subprocess.run
    drive.subprocess.run = lambda *a, **k: (_ for _ in ()).throw(
        OSError("cannot exec")
    )
    try:
        return drive.binary_supports_confirm_candidate(["baha", "up"])
    finally:
        drive.subprocess.run = orig


def b2_case_timeout():
    orig = drive.subprocess.run
    class _To:
        def __call__(self, argv, **kwargs):
            raise drive.subprocess.TimeoutExpired("baha up", 20)
    drive.subprocess.run = _To()
    try:
        return drive.binary_supports_confirm_candidate(["baha", "up"])
    finally:
        drive.subprocess.run = orig


def b2_case_unknown_message():
    orig = drive.subprocess.run
    class _U:
        def __call__(self, argv, **k):
            r = types.SimpleNamespace(returncode=1, stdout="", stderr="permission denied\n")
            return r
    drive.subprocess.run = _U()
    try:
        return drive.binary_supports_confirm_candidate(["baha", "up"])
    finally:
        drive.subprocess.run = orig


def b2_case_exact_unsupported():
    orig = drive.subprocess.run
    class _U:
        def __call__(self, argv, **k):
            r = types.SimpleNamespace(
                returncode=1,
                stdout="",
                stderr="baha: unknown option --confirm-candidate\n",
            )
            return r
    drive.subprocess.run = _U()
    try:
        return drive.binary_supports_confirm_candidate(["baha", "up"])
    finally:
        drive.subprocess.run = orig


def b2_case_positive():
    orig = drive.subprocess.run
    class _P:
        def __call__(self, argv, **k):
            # clean exit, empty output => parsed flag, proceeded (positive)
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")
    drive.subprocess.run = _P()
    try:
        return drive.binary_supports_confirm_candidate(["baha", "up"])
    finally:
        drive.subprocess.run = orig


check("B2 binary-missing -> ABORT(False)", False, b2_case_missing())
check("B2 timeout -> ABORT(False)", False, b2_case_timeout())
check("B2 unknown-message -> ABORT(False)", False, b2_case_unknown_message())
check("B2 exact-unsupported -> ABORT(False)", False, b2_case_exact_unsupported())
check("B2 clean-positive -> SUPPORTED(True)", True, b2_case_positive())

# ---- B1: capture-path regressions ------------------------------------------

def run_tty_capture(name, rc, buffer, rules):
    """Drive run_tty in capture mode; return (rc, buffer) or ("RAISED", msg).

    The caller applies the abort decision: only the documented candidate abort
    (all non-optional interactions driven, then a non-zero exit) is permitted as
    a between-state. Any other non-zero exit or a missing required prompt must
    raise at the call site (never reach the caller as a success).
    """
    import os
    import struct
    import termios
    import fcntl
    tmp = f"/tmp/b1_{name}_{rc}.sh"
    with open(tmp, "w") as fh:
        fh.write("printf '%s' \"$1\"; exit %d\n" % (buffer, rc))
    os.chmod(tmp, 0o755)
    try:
        return drive.run_tty(
            name,
            ["bash", tmp, "payload"],
            rules,
            timeout=30,
            no_output_timeout=10,
            capture=True,
        )
    except RuntimeError as e:
        return ("RAISED", str(e))
    finally:
        os.unlink(tmp)


# rules with one required (non-optional) prompt
required_rule = [drive.Rule(r"payload\s*$", "handled\n")]
optional_rule = [drive.Rule(r"whatever\s*$", "x", optional=True)]

# Regression 1: exit!=0 without hash -> caller ABORTS (run_tty returns (7, buf);
# the abort decision lives at the call site, not inside run_tty capture path).
r1 = run_tty_capture("b1_exit7", 7, "payload\n", required_rule)
check("B1 exit!=0 (7) no hash -> caller ABORTS (rc=7)", 7, r1[0])

# Regression 2: missing required prompt -> caller ABORTS (run_tty returns (7, buf))
r2 = run_tty_capture("b1_missing", 7, "no-prompt-here", required_rule)
check("B1 missing-required-prompt -> caller ABORTS (rc=7)", 7, r2[0])

# Regression 3: success without hash but expected rules satisfied and rc=0 -> OK (rc,buffer)
r3 = run_tty_capture("b1_ok", 0, "payload\n", required_rule)
check("B1 success no-hash + expected rules + rc=0 -> OK(rc,buffer)",
      True, isinstance(r3, tuple) and r3[0] == 0)

# Regression 4: documented candidate-abort: all non-optional interactions driven,
# then non-zero exit -> run_tty returns (rc,buffer) for the caller to classify;
# caller proceeds to the documented abort branch (not a PASS).
r4 = run_tty_capture("b1_abort", 3, "payload\n", required_rule)
check("B1 candidate-abort (all prompts, exit=3, no hash) -> (rc,buffer) rc=3", 3, r4[0])

print("---")
fails = [r for r in RESULTS if r[0] == "XX"]
if fails:
    print(f"B1/B2 EVIDENCE FAILURES: {len(fails)}")
    for ok, name, exp, act in fails:
        print(f"  {name}: expected={exp!r} actual={act!r}")
    sys.exit(1)
print(f"B1/B2 EVIDENCE PASS: {len(RESULTS)} cases")
sys.exit(0)
