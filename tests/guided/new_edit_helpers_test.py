#!/usr/bin/env python3
"""Small regressions for fail-closed PTY choices, consent and byte inventory."""
import os
from contextlib import redirect_stdout
from pathlib import Path
import sys
import tempfile
import unittest

from new_edit import CurrentConsent, filesystem_snapshot, picker_keys
import drive


class FixtureHelpersTest(unittest.TestCase):
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
