#!/usr/bin/env python3
"""Fail-closed guided candidate-consent regressions (demo PR #128, round 4).

Permanent regression for the review-128c finding. Unlike round 3, this suite does
NOT test against a test-local copy of the production rule set: it imports the
PRODUCTION module (`drive`) and exercises the PRODUCTION decision path —
`drive.run_guided_consent_flow` (first_rc / feature-detection / confirm-hash
classification / documented abort -> second `up`) — together with the
production rule set `drive.up_rules` (imported, not copied). The four
counter-probes and both success paths are therefore measured against the real
production path, so a foreign error can never reach a second run in production.

Covers the caller/guided-flow cases review-128c listed:
1. rc=0 without the mandatory READY-abschluss-marker => ABORT (run_tty raises)
2. required prompt missing => ABORT (run_tty raises on non-optional coverage)
3. rc != 0 without a confirm-hash => ABORT (production flow returns abort, no second up)
4. rc != 0 with a confirm-hash but a FOREIGN error text => ABORT, no second up
   (production flow returns abort, no second up)
5. rc != 0 with a confirm-hash but incomplete interactions => ABORT
   (run_tty raises on non-optional coverage before the flow classifies)
6. documented candidate-consent abort (hash + documented prompt) => second up
   runs and reaches READY (positive path, production flow)
7. regular success without a hash => READY (positive path, production flow)
8. hash + documented prompt + FOREIGN panic in the SAME non-zero transcript =>
   ABORT, no second up (the review-128d REZEPT #1 bypass, measured here)
9. documented abort with NO foreign signature => second_up (control that the
   fail-closed fix does not over-tighten)
10. production foreign-signature helper classifies foreign text, never the
    documented abort prompt

One line per case, "OK|CASE|..." / "XX|CASE|...". Failures exit non-zero.
Discovered by `python3 -m unittest discover -s tests/guided -p "test_*.py"`.
"""
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
import drive  # noqa: E402


def write_fake_core(lines, exit_code, delay=0.6, final_delay=None):
    """Create a fake Core whose printed lines are the interactive prompts.

    drive.run_tty matches a rule against ``buffer[cursor:]`` with the pattern
    anchored at the end (regex ``\\s*$``) and types the scripted answer itself,
    so the transcript contains ONLY the Core's prompts. Each entry is therefore
    a bare prompt line, emitted with an idle gap so it is the sole trailing
    content when read. A lone "READY" line marks clean completion.
    """
    fd, path = tempfile.mkstemp(prefix="fake-core-")
    counter = path + ".counter"  # mkstemp path is unique across tests and processes
    lines_repr = ", ".join(repr(line) for line in lines)
    with os.fdopen(fd, "w") as fh:
        fh.write("#!/usr/bin/env python3\nimport sys, time, os\n")
        # The production feature probe runs the core as
        # ``[core, "--no-input", "--confirm-candidate", "0"*64]`` and treats an
        # rc=0 with empty, unambiguous output as a POSITIVE support signal. Simulate
        # a supported Core here: ignore the interactive prompts for the probe
        # invocation (marked by ``--no-input``) and exit 0 with no output. This lets
        # the documented abort reach the real second-run branch in
        # drive.run_guided_consent_flow. (The real second up is ``--verbose`` ... and
        # does NOT carry ``--no-input``; it prints prompts + READY like normal.)
        fh.write('if "--no-input" in sys.argv:\n    sys.exit(0)\n')
        # The production flow runs the SAME core argv twice (first `up`, then
        # `up --confirm-candidate`). A real Core reaches READY on the second run
        # after the digest is supplied, so the fake core is stateful: the first
        # interactive invocation prints ``lines`` and exits ``exit_code`` (the
        # abort), every subsequent invocation prints prompts + READY and exits 0.
        fh.write("try:\n")
        fh.write("    _n = int(open(r'" + counter + "').read().strip())\n")
        fh.write("except Exception:\n    _n = 0\n")
        fh.write("if _n >= 1:\n")
        fh.write("    for _line in [" + lines_repr + "]:\n")
        fh.write("        sys.stdout.write(_line); sys.stdout.flush()\n")
        fh.write(f"        time.sleep({delay!r})\n")
        fh.write('    sys.stdout.write("READY\\n"); sys.stdout.flush()\n')
        fh.write("    sys.exit(0)\n")
        fh.write("open(r'" + counter + "', 'w').write(str(_n + 1))\n")
        for index, line in enumerate(lines):
            fh.write("sys.stdout.write(" + repr(line) + "); sys.stdout.flush()\n")
            current_delay = delay if final_delay is None or index < len(lines) - 1 else final_delay
            fh.write(f"time.sleep({current_delay!r})\n")
        fh.write("sys.exit(" + str(exit_code) + ")\n")
    os.chmod(path, 0o755)
    return path


def cleanup_fake_core(path):
    """Dispose of both the per-fixture executable and its isolated counter."""
    for candidate in (path, path + ".counter"):
        try:
            os.unlink(candidate)
        except FileNotFoundError:
            pass


def run_capture(name, core_path, rules, exit_code, timeout=30):
    """Drive a fake core under a real PTY via drive.run_tty in capture mode.

    Exercises the actual fail-closed abort decision in drive.run_tty: mandatory
    READY marker on clean completion, documented candidate-consent abort marker
    on non-zero exit, and non-optional rule coverage. Returns (rc, buffer);
    raises RuntimeError on a fail-closed abort or timeout.
    """
    os.environ["ARTIFACT_DIR"] = tempfile.mkdtemp(prefix="consent-harness-")
    return drive.run_tty(
        name, [core_path, "payload"], rules,
        timeout=timeout, no_output_timeout=10, capture=True,
    )


def flow_first(core_path, exit_code, timeout=30):
    """Run the PRODUCTION decision path on a single (first-run) fake core.

    Calls ``drive.run_guided_consent_flow`` with the PRODUCTION rule set
    ``drive.up_rules`` (imported, not copied). Returns the result dict. Raises
    RuntimeError if the production flow aborts before classifying (e.g. a
    non-zero exit with incomplete non-optional coverage).
    """
    return drive.run_guided_consent_flow(
        [core_path], drive.up_rules,
    )


def flow_abort_then_second(core_path, exit_code, timeout=30):
    """Run the full PRODUCTION guided flow: first abort, then the second up.

    Calls ``drive.run_guided_consent_flow`` with the production rule set. The
    second up is driven by the SAME production path (the digest from the first
    abort is fed into a second fake core). Returns the flow result dict. Raises
    RuntimeError on a fail-closed abort.
    """
    result = drive.run_guided_consent_flow(
        [core_path], drive.up_rules,
    )
    return result


def flow_ready(core_path, exit_code, timeout=30):
    """Run the PRODUCTION guided flow on a single clean (rc=0) fake core.

    Calls ``drive.run_guided_consent_flow`` with the production rule set. The
    clean path reaches READY in the single run. Returns the flow result dict.
    Raises RuntimeError on a fail-closed abort.
    """
    return drive.run_guided_consent_flow(
        [core_path], drive.up_rules,
    )


class ConsentCaptureRegression(unittest.TestCase):
    def test_01_rc0_no_ready_aborts(self):
        # rc=0 but the mandatory READY marker is absent => production run_tty raises.
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "",
        ], exit_code=0)
        with tempfile.TemporaryDirectory() as d:
            try:
                run_capture("c01", core, drive.up_rules, exit_code=0)
                self.fail("expected ABORT (RuntimeError) on rc=0 without READY")
            except RuntimeError:
                pass
            finally:
                cleanup_fake_core(core)

    def test_02_required_prompt_missing_aborts(self):
        # Only the Environment prompt answered; the mandatory READY marker never
        # fired => production run_tty raises (non-optional READY coverage fails).
        core = write_fake_core(["Environment [demo]:"], exit_code=0)
        try:
            flow_ready(core, exit_code=0)
            self.fail("expected ABORT (RuntimeError) on missing required prompt")
        except RuntimeError:
            pass
        finally:
            cleanup_fake_core(core)

    def test_03_nonzero_without_hash_aborts(self):
        # rc != 0 without a confirm-hash AND without the documented confirm prompt:
        # the production run_tty aborts (fail-closed) before the flow can classify,
        # so NO second up is run.
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "",
            "unexpected failure",
        ], exit_code=7)
        try:
            flow_first(core, exit_code=7)
            self.fail("expected ABORT (RuntimeError) on rc!=0 without documented prompt")
        except RuntimeError:
            pass
        finally:
            cleanup_fake_core(core)

    def test_04_nonzero_with_foreign_error_aborts(self):
        # rc != 0 with a FOREIGN error text (no documented confirm prompt):
        # production run_tty aborts (fail-closed); NO second up is run. This is the
        # exact review-128c foreign-error counter-probe measured against the real
        # production decision path.
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "",
            "core: panic: unknown error 0xdeadbeef",
        ], exit_code=3)
        try:
            flow_first(core, exit_code=3)
            self.fail("expected ABORT (RuntimeError) on foreign error text")
        except RuntimeError:
            pass
        finally:
            cleanup_fake_core(core)

    def test_05_nonzero_with_incomplete_interactions_aborts(self):
        # Only the Environment prompt answered; Application name (required as
        # part of non-optional READY coverage) never fired => production run_tty
        # raises before the flow can classify.
        core = write_fake_core(["Environment [demo]:"], exit_code=3)
        try:
            flow_first(core, exit_code=3)
            self.fail("expected ABORT (RuntimeError) on incomplete interactions")
        except RuntimeError:
            pass
        finally:
            cleanup_fake_core(core)

    def test_06_documented_abort_then_second_up_ready(self):
        # Documented candidate-consent abort (hash + documented prompt) -> second
        # up reaches READY, via the PRODUCTION flow (drive.run_guided_consent_flow
        # drives the real abort->second-up sequence; the fake core is stateful so
        # the first invocation aborts and the second reaches READY).
        digest = "b" * 64
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "",
            f"Re-run with --confirm-candidate {digest} to acknowledge this exact submission.",
        ], exit_code=3)
        try:
            res = flow_abort_then_second(core, exit_code=3)
            self.assertEqual("second_up", res["outcome"])
            self.assertEqual(3, res["first_rc"])
            self.assertEqual(digest, res["confirm_hash"])
            self.assertEqual(0, res["second_rc"])
            self.assertIn("--confirm-candidate", " ".join(res["second_argv"]))
            self.assertFalse(res["foreign_error_second_up"])
        except RuntimeError as e:
            self.assertTrue(False, f"documented abort should reach second_up, got: {e}")
        finally:
            cleanup_fake_core(core)

    def test_07_regular_success_no_hash_ready(self):
        # Regular success (rc=0, no hash, READY) => clean ready path.
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "",
            "READY",
        ], exit_code=0)
        try:
            res = flow_ready(core, exit_code=0)
            self.assertEqual("ready", res["outcome"])
            self.assertEqual(0, res["first_rc"])
            self.assertIsNone(res["confirm_hash"])
            self.assertIsNone(res["second_rc"])
            self.assertFalse(res["foreign_error_second_up"])
        except RuntimeError as e:
            self.assertTrue(False, f"regular success should reach ready, got: {e}")
        finally:
            cleanup_fake_core(core)

    def test_08_foreign_error_never_reaches_second_up_assertion(self):
        # Assertion in the PRODUCTION path: a foreign error (no documented
        # confirm prompt) never triggers a second up. Every foreign-error probe
        # fails closed in drive.run_guided_consent_flow (foreign_error_second_up
        # is always False, second_rc/second_argv are None or the flow raises).
        foreign_cores = [
            write_fake_core([
                "Application name [demo]:",
                "Environment [demo]:",
                "",
                "core: panic: unknown error 0xdeadbeef",
            ], exit_code=3),
        ]
        try:
            res = flow_first(foreign_cores[0], exit_code=3)
            self.assertEqual("abort", res["outcome"])
            self.assertIsNone(res["second_rc"])
            self.assertIsNone(res["second_argv"])
            self.assertFalse(res["foreign_error_second_up"])
        except RuntimeError:
            # Fail-closed abort (no second up) is equally a valid production
            # outcome: a foreign error reached no second run.
            pass
        finally:
            os.unlink(foreign_cores[0])

    def test_09_hash_and_documented_prompt_with_foreign_error_aborts(self):
        # The exact review-128d REZEPT #1 bypass: a non-zero transcript that
        # carries a VALID 64-hex confirm-hash AND the documented
        # ``Re-run with --confirm-candidate`` prompt AND a FOREIGN panic/error
        # line. This must classify as a hard ABORT with NO second up — the hash
        # + consent hint co-occurring with any foreign signature is never a
        # documented between-state.
        digest = "a" * 64
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "",
            f"Re-run with --confirm-candidate {digest} to acknowledge this exact submission.",
            "core: panic: unknown error 0xdeadbeef",
        ], exit_code=3)
        try:
            res = flow_first(core, exit_code=3)
            self.assertEqual("abort", res["outcome"],
                             "hash+documented-prompt+foreign-error must abort, not second_up")
            self.assertIsNone(res["second_rc"],
                             "a foreign error must never reach a second up")
            self.assertIsNone(res["second_argv"],
                             "a foreign error must never reach a second up")
            self.assertFalse(res["foreign_error_second_up"])
        except RuntimeError:
            # Fail-closed abort (no second up) is equally a valid production
            # outcome: the foreign error reached no second run.
            pass
        finally:
            cleanup_fake_core(core)

    def test_10_documented_abort_without_foreign_signature_reaches_second_up(self):
        # Control: a non-zero exit carrying the hash AND the documented prompt
        # AND NO foreign signature IS a genuine documented abort and must reach
        # second_up (regression guard against over-tightening the fail-closed
        # check). This must stay green after the R1 fix.
        digest = "b" * 64
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "",
            "Error: record deployment before mutation: candidate submission requires an explicit operator/automation\n consent (--confirm-candidate); refusing to record deployment state: candidate submission requires an explicit operator/automation consent (--confirm-candidate); refusing to record deployment state",
            f"Re-run with --confirm-candidate {digest} to acknowledge this exact submission.",
        ], exit_code=3)
        try:
            res = flow_abort_then_second(core, exit_code=3)
            self.assertEqual("second_up", res["outcome"])
            self.assertEqual(3, res["first_rc"])
            self.assertEqual(digest, res["confirm_hash"])
            self.assertEqual(0, res["second_rc"])
            self.assertFalse(res["foreign_error_second_up"])
        except RuntimeError as e:
            self.assertTrue(False, f"documented abort (no foreign error) should reach second_up, got: {e}")
        finally:
            cleanup_fake_core(core)

    def test_11_foreign_error_signature_detected_by_production_helper(self):
        # The production helper classifies the foreign signature; the documented
        # abort prompt must NOT be flagged.
        self.assertIsNotNone(drive.find_foreign_error_signature(
            "core: panic: unknown error 0xdeadbeef"))
        self.assertEqual(
            "Traceback",
            drive.find_foreign_error_signature("a Traceback (most recent call last)")),
        self.assertIsNone(drive.find_foreign_error_signature(
            "Re-run with --confirm-candidate " + "a" * 64
            + " to acknowledge this exact submission."))
        self.assertIsNone(drive.find_foreign_error_signature(
            "Error: record deployment before mutation: candidate submission requires an explicit operator/automation\n consent (--confirm-candidate); refusing to record deployment state: candidate submission requires an explicit operator/automation consent (--confirm-candidate); refusing to record deployment state"))
        self.assertIsNone(drive.find_foreign_error_signature(
            "\x1b[31mError:\x1b[0m record deployment before mutation: candidate submission requires an explicit operator/automation\n"
            " consent (--confirm-candidate); refusing to record deployment state: candidate submission requires an explicit operator/automation consent (--confirm-candidate); refusing to record deployment state"))
        digest = "d" * 64
        hard_wrapped = (
            "\x1b[31mRe-run with --confirm-candidate " + digest[:27] + "\x1b[0m\n" + digest[27:]
            + " to acknowledge this exact submission.\n"
            + "Error: record deployment befo\nre mutation: candidate submission requires an explicit "
            + "operator/automati\non consent (--confirm-candidate); refusing to record deployment state: "
            + "candidate submission requires an explicit operator/automation consent "
            + "(--confirm-candidate); refusing to record deployment state"
        )
        self.assertEqual(digest, drive.capture_confirm_hash(hard_wrapped))
        self.assertTrue(drive.contains_candidate_abort_prompt(hard_wrapped))
        self.assertIsNone(drive.find_foreign_error_signature(hard_wrapped))
        self.assertEqual("Error:", drive.find_foreign_error_signature(
            hard_wrapped + "\nError: unrelated deployment failure"))
        self.assertEqual("Error:", drive.find_foreign_error_signature(
            "Error: unrelated deployment failure"))
        self.assertIsNone(drive.find_foreign_error_signature("READY"))

    def test_13_unrelated_error_with_candidate_hash_still_aborts(self):
        digest = "c" * 64
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "Error: unrelated deployment failure",
            f"Re-run with --confirm-candidate {digest} to acknowledge this exact submission.",
        ], exit_code=3)
        try:
            result = flow_first(core, exit_code=3)
            self.assertEqual("abort", result["outcome"])
            self.assertIsNone(result["second_argv"])
            self.assertIsNone(result["second_rc"])
            self.assertFalse(result["foreign_error_second_up"])
        finally:
            cleanup_fake_core(core)

    def test_14_immediate_exit_bytes_are_in_the_capture_transcript(self):
        digest = "e" * 64
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            "",
            "Error: record deployment before mutation: candidate submission requires an explicit "
            "operator/automation consent (--confirm-candidate); refusing to record deployment state: "
            "candidate submission requires an explicit operator/automation consent "
            "(--confirm-candidate); refusing to record deployment state",
            f"Re-run with --confirm-candidate {digest} to acknowledge this exact submission.",
        ], exit_code=3, delay=0.1, final_delay=0)
        try:
            result = flow_abort_then_second(core, exit_code=3)
            self.assertEqual("second_up", result["outcome"])
            self.assertEqual(digest, result["confirm_hash"])
            self.assertEqual(0, result["second_rc"])
        finally:
            cleanup_fake_core(core)

    def test_12_provider_impact_plan_prompt_is_confirmed(self):
        prompt = "Apply these changes? [y/N]"
        core = write_fake_core([
            "Application name [demo]:",
            "Environment [demo]:",
            prompt,
            "READY",
        ], exit_code=0)
        apply_rule = next(
            rule for rule in drive.up_rules
            if rule.pattern.pattern == r"Apply these changes\? \[y/N\]:?\s*$"
        )
        try:
            run_capture("c12", core, drive.up_rules, exit_code=0)
            self.assertEqual(1, apply_rule.used)
            self.assertEqual("y\n", apply_rule.value(None, ""))
        finally:
            apply_rule.used = 0
            cleanup_fake_core(core)


if __name__ == "__main__":
    # unittest.main() handles discovery; this block additionally emits the
    # one-line-per-case evidence the review recipe requires.
    import select  # noqa: F401  (kept for parity with harness imports)
    RESULTS = []

    def check(name, expected, actual):
        ok = "OK" if (expected is actual or expected == actual) else "XX"
        RESULTS.append((ok, name, expected, actual))
        print(f"{ok} | {name} | expected={expected!r} actual={actual!r}")

    # Run each case directly for the evidence transcript.
    tc = ConsentCaptureRegression()
    for method in [
        "test_01_rc0_no_ready_aborts",
        "test_02_required_prompt_missing_aborts",
        "test_03_nonzero_without_hash_aborts",
        "test_04_nonzero_with_foreign_error_aborts",
        "test_05_nonzero_with_incomplete_interactions_aborts",
        "test_06_documented_abort_then_second_up_ready",
        "test_07_regular_success_no_hash_ready",
        "test_08_foreign_error_never_reaches_second_up_assertion",
        "test_09_hash_and_documented_prompt_with_foreign_error_aborts",
        "test_10_documented_abort_without_foreign_signature_reaches_second_up",
        "test_11_foreign_error_signature_detected_by_production_helper",
        "test_12_provider_impact_plan_prompt_is_confirmed",
        "test_13_unrelated_error_with_candidate_hash_still_aborts",
    ]:
        try:
            getattr(tc, method)()
            check(method, "OK", "OK")
        except Exception as e:  # noqa: BLE001
            check(method, "OK", f"FAIL:{e}")
    print("---")
    fails = [r for r in RESULTS if r[0] == "XX"]
    if fails:
        print(f"CONSENT-CAPTURE EVIDENCE FAILURES: {len(fails)}")
        sys.exit(1)
    print(f"CONSENT-CAPTURE EVIDENCE PASS: {len(RESULTS)} cases")
    unittest.main(verbosity=2)
