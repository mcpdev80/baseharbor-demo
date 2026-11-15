#!/usr/bin/env python3
"""Small regressions for fail-closed PTY choices, consent and byte inventory."""
import os
from contextlib import redirect_stdout
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from new_edit import (CurrentConsent, edit_candidate_confirmation, edit_picker_rule,
                      edit_application, filesystem_snapshot, picker_keys,
                      provider_choice_response, provider_choice_rule,
                      resume_confirmed_edit_apply)
import drive


class FixtureHelpersTest(unittest.TestCase):
    def test_mutating_edit_tty_allowance_exceeds_core_preview_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            config, data = project / "config", project / "data"
            config.mkdir()
            data.mkdir()
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(config), "XDG_DATA_HOME": str(data)}):
                with patch("new_edit.run_tty", return_value=(0, "Edit complete\n")) as run:
                    with patch("new_edit.footprint", return_value={"ok": True}):
                        edit_application(project, "remove", native=False)
        self.assertEqual(run.call_args.kwargs["no_output_timeout"], 180)
        self.assertGreater(run.call_args.kwargs["no_output_timeout"], 120)

    def test_edit_candidate_confirmation_accepts_only_exact_consent_abort(self):
        digest = "a" * 64
        refusal = drive.EXPECTED_CANDIDATE_CONSENT_REFUSAL
        transcript = (f"Re-run with --confirm-candidate {digest} to acknowledge this exact submission.\n"
                      + refusal + "\nError: application machine: partial\n")
        self.assertEqual(edit_candidate_confirmation(2, transcript), digest)
        prefixed = transcript.replace(refusal, "Error: " + refusal)
        self.assertEqual(edit_candidate_confirmation(2, prefixed), digest)
        for invalid in (
            (2, transcript.replace(refusal, "Error: unrelated edit failure")),
            (2, transcript + "Error: unrelated failure\n"),
            (2, refusal),
            (0, transcript),
        ):
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                edit_candidate_confirmation(*invalid)
        self.assertIsNone(edit_candidate_confirmation(0, "Edit complete\n"))

    def test_confirmed_edit_apply_uses_exact_candidate_and_current_consent(self):
        digest = "b" * 64
        consent = CurrentConsent()
        consent.plan = "stale"
        project = Path("/tmp/project")
        with patch("new_edit.run_tty") as run:
            resume_confirmed_edit_apply(project, "remove", digest, consent,
                                        {"EXTRA": "value"})
        args, kwargs = run.call_args
        self.assertEqual(args[0], "new-edit-project-remove-apply")
        self.assertEqual(args[1], [drive.BAHA, "app", "apply", "--confirm-candidate", digest])
        self.assertEqual(kwargs["cwd"], project)
        self.assertEqual(kwargs["env"]["EXTRA"], "value")
        self.assertEqual(kwargs["env"]["BASEHARBOR_LOGS_ENABLED"], "false")
        self.assertIsNone(consent.plan)
        self.assertTrue(any("Confirm the displayed provider changes" in rule.pattern.pattern
                            for rule in args[2]))

    def test_explicit_provider_uses_current_actual_named_sql_row(self):
        instance = "postgresql/application/fixture/dev/default"
        frame = ("What does your application need?\n"
                 "database.sql/analytics on Target native-fixture — Automatic\n"
                 "Reason: Automatic: unresolved or ambiguous; choose an explicit compatible instance\n"
                 "[ ] " + instance + " (postgresql): supports SQL (scope: application)\n"
                 "[ ] postgresql/shared/other (postgresql): supports SQL (scope: shared)\n")
        expected = "provider database.sql/analytics " + instance + "\n"
        self.assertEqual(provider_choice_response(frame, instance), expected)
        rule = provider_choice_rule(instance)
        match = rule.match(frame)
        self.assertIsNotNone(match)
        self.assertEqual(rule.value(match, frame), expected)
        for invalid in (frame.replace(instance, "different-provider"),
                        frame + "database.sql/second on Target native-fixture — Automatic\n",
                        frame + "What does your application need?\nNo SQL need selected\n",
                        frame.replace("database.sql/analytics", "cache.key-value/cache")):
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                provider_choice_response(invalid, instance)

    def test_real_pty_prompts_survive_bounded_transcript_rollover(self):
        # A build can print more than the driver's bounded 64KiB transcript
        # before a later consequence prompt. This is a process/transport test,
        # not a replacement for a native BaseHarbor journey.
        child = "import sys; print('a'*70000+'first:',flush=True); assert input()=='one'; print('b'*1000+'second:',flush=True); assert input()=='two'"
        with tempfile.TemporaryDirectory() as directory:
            old_artifacts = drive.ARTIFACT_DIR
            try:
                drive.ARTIFACT_DIR = Path(directory)
                with open(os.devnull, "w") as output, redirect_stdout(output):
                    drive.run_tty("rollover", [sys.executable, "-c", child], [
                        drive.Rule(r"first:\s*$", "one\n"), drive.Rule(r"second:\s*$", "two\n")],
                        cwd=directory, timeout=5, no_output_timeout=2)
            finally:
                drive.ARTIFACT_DIR = old_artifacts

    def test_actual_picker_inventory_and_missing_rows(self):
        frame = "What does your application need?\n" + "\n".join([
            "> [ ] SQL database — data", "  [ ] Cache — cache",
            "  [ ] Protected application secrets — secrets", "  [ ] Application login — login",
            "  [x] TLS / HTTPS — exposure"])
        self.assertEqual(picker_keys(frame), ["\x1b[B"] * 4 + [" ", "\r"])
        self.assertEqual(picker_keys(frame, sql=True), [" "] + ["\x1b[B"] * 4 + [" ", "\r"])
        with self.assertRaises(RuntimeError):
            picker_keys(frame.replace("  [ ] Cache — cache\n", ""))

    def test_edit_picker_changes_only_visible_sql_choice_and_waits_for_redraw(self):
        checked = ("What does your application need?\n" + "\n".join([
            "> [x] SQL database — data", "  [ ] Cache — cache",
            "  [ ] Protected application secrets — secrets", "  [ ] Application login — login",
            "  [x] TLS / HTTPS — exposure", "No SQL, identity service, secrets service or management stack is mandatory."]))
        unchecked = checked.replace("> [x] SQL database", "> [ ] SQL database")
        rule = edit_picker_rule(False)
        match = rule.match(checked)
        self.assertIsNotNone(match)
        self.assertEqual(rule.value(match, checked), [" \n", "down\n", "up\n"])
        self.assertIsNone(rule.value(match, checked))  # stale frame: do not toggle twice
        match = rule.match(unchecked)
        self.assertIsNotNone(match)
        self.assertEqual(rule.value(match, unchecked), "enter\n")
        self.assertFalse(rule.repeat)

        already_unchecked = edit_picker_rule(False)
        match = already_unchecked.match(unchecked)
        self.assertEqual(already_unchecked.value(match, unchecked), "enter\n")

    def test_edit_picker_fails_closed_when_sql_row_is_missing(self):
        text = ("What does your application need?\n" + "\n".join([
            "> [ ] Cache — cache", "  [ ] Protected application secrets — secrets",
            "  [ ] Application login — login", "  [ ] TLS / HTTPS — exposure",
            "  [ ] Metrics — metrics",
            "No SQL, identity service, secrets service or management stack is mandatory."]))
        rule = edit_picker_rule(False)
        with self.assertRaisesRegex(RuntimeError, "exactly one SQL choice"):
            rule.value(rule.match(text), text)

    def test_consent_rejects_replayed_stale_and_impossible_stages(self):
        consent = CurrentConsent()
        rule = consent.rule()
        def approve(stage, total, plan):
            text = f"Confirm the displayed provider changes ({stage}/{total}, plan {plan})? [y/N]: "
            return consent.respond(rule.match(text), text)
        self.assertEqual(approve(1, 2, "a" * 64), "yes\n")
        with self.assertRaises(RuntimeError):
            approve(1, 2, "a" * 64)
        with self.assertRaises(RuntimeError):
            approve(2, 2, "b" * 64)
        self.assertEqual(approve(2, 2, "a" * 64), "yes\n")
        with self.assertRaises(RuntimeError):
            approve(2, 1, "a" * 64)
        self.assertIsNone(rule.match("Achtung: separately authorize permanent deletion of the displayed owned data (plan " + "a" * 64 + ")? [y/N]: "))

    def test_snapshot_detects_bytes_modes_links_and_empty_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.write_text("old")
            original_mode = source.stat().st_mode & 0o777
            before = filesystem_snapshot([root])
            source.write_text("new")
            self.assertNotEqual(filesystem_snapshot([root]), before)
            source.write_text("old")
            self.assertEqual(filesystem_snapshot([root]), before)
            source.chmod(original_mode ^ 0o100)
            self.assertNotEqual(filesystem_snapshot([root]), before)
            source.chmod(original_mode)
            (root / "empty").mkdir()
            self.assertNotEqual(filesystem_snapshot([root]), before)
            (root / "empty").rmdir()
            os.symlink("source", root / "link")
            self.assertNotEqual(filesystem_snapshot([root]), before)


if __name__ == "__main__":
    unittest.main()
