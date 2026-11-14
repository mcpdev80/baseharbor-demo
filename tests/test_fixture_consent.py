import contextlib
import copy
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("fixture_consent", Path(__file__).with_name("fixture-consent.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class ConsentTests(unittest.TestCase):
    def refusal(self):
        return {"contract_version": "v1", "error": {"code": "approval_required", "cause": "impact-confirmation-required", "details": {"scope": {"version": "baseharbor.provider-impact-scope/v1", "plan_id": "a" * 64, "confirmations_required": 2, "complete": False, "destructive": True}}}}

    def test_current_two_stages_with_separate_data_decision(self):
        consent = fixture.current_consent(self.refusal())
        self.assertTrue(consent["first"] and consent["second"] and consent["delete_data"])

    def test_partial_stale_and_other_errors_cannot_be_acknowledged(self):
        for code in ("conflict", "execution_failed", "validation_failed"):
            value = self.refusal()
            value["error"]["code"] = code
            with self.assertRaises(ValueError):
                fixture.current_consent(value)
        value = self.refusal()
        value["error"]["cause"] = "stale-impact-consent"
        with self.assertRaises(ValueError):
            fixture.current_consent(value)

    def test_missing_plan_or_incomplete_single_stage_is_rejected(self):
        for change in ({"plan_id": ""}, {"confirmations_required": 1}, {"complete": "false"}):
            value = self.refusal()
            value["error"]["details"]["scope"].update(change)
            with self.assertRaises(ValueError):
                fixture.current_consent(value)

    def candidate_refusal(self, digest):
        return {
            "contract_version": "v1",
            "error": {
                "code": "validation_failed",
                "message": "candidate submission requires an explicit operator/automation consent (--confirm-candidate); refusing to record deployment state",
                "next": f"Re-run with --confirm-candidate {digest} to acknowledge this exact submission.",
            },
        }

    def test_candidate_consent_accepts_only_documented_exact_digest(self):
        digest = "c" * 64
        self.assertEqual(fixture.candidate_confirmation(self.candidate_refusal(digest)), digest)
        wrapped = self.candidate_refusal(digest)
        direct = wrapped["error"]["message"]
        wrapped["error"]["message"] = "record deployment before mutation: " + direct + ": " + direct
        self.assertEqual(fixture.candidate_confirmation(wrapped), digest)
        for change in (
            {"contract_version": "v2"},
            {"error": {"code": "execution_failed"}},
            {"error": {"next": "Re-run --confirm-candidate " + digest}},
        ):
            value = self.candidate_refusal(digest)
            value.update(change)
            with self.assertRaises(ValueError):
                fixture.candidate_confirmation(value)

    def test_candidate_consent_rejects_unrecognized_wrapped_message(self):
        value = self.candidate_refusal("e" * 64)
        value["error"]["message"] = "unexpected preflight: " + value["error"]["message"]
        with self.assertRaises(ValueError):
            fixture.candidate_confirmation(value)

    def test_fixture_retries_only_with_reported_candidate_digest(self):
        digest = "d" * 64
        refusal = subprocess.CompletedProcess([], 1, b"", json.dumps(self.candidate_refusal(digest)).encode())
        success = subprocess.CompletedProcess([], 0, b"accepted\n", b"")
        seen_args = []
        replies = iter((refusal, success))

        def run(args, **_kwargs):
            seen_args.append(list(args))
            return next(replies)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            demo = root / "demo"
            fixture_root = root / "fixture"
            binary = root / "bin" / "baha"
            for path in (demo, fixture_root / "data", fixture_root / "config", binary.parent):
                path.mkdir(parents=True, exist_ok=True)
            binary.write_text("fixture binary")
            original_cwd = Path.cwd()
            os.chdir(demo)
            try:
                with mock.patch.dict(os.environ, {
                    "BASEHARBOR_DEMO_FIXTURE": str(fixture_root),
                    "DEMO_ROOT": str(demo),
                    "XDG_DATA_HOME": str(fixture_root / "data"),
                    "XDG_CONFIG_HOME": str(fixture_root / "config"),
                    "BAHA": str(binary),
                }), mock.patch.object(sys, "argv", [str(root / "tests" / "fixture-consent.py"), str(binary), "up", "--yes"]), \
                     mock.patch.object(subprocess, "run", side_effect=run), \
                     contextlib.redirect_stdout(io.TextIOWrapper(io.BytesIO())), \
                     contextlib.redirect_stderr(io.TextIOWrapper(io.BytesIO())):
                    self.assertEqual(fixture.main(), 0)
            finally:
                os.chdir(original_cwd)
        first, second = seen_args
        self.assertNotIn("--confirm-candidate", first)
        self.assertEqual(second[-2:], ["--confirm-candidate", digest])
        self.assertEqual(second.count("--json"), 1)

    def test_fixture_acknowledges_recomputed_candidate_after_provider_plan(self):
        initial_digest, recomputed_digest = "f" * 64, "9" * 64
        first_candidate = subprocess.CompletedProcess([], 1, b"", json.dumps(self.candidate_refusal(initial_digest)).encode())
        provider_plan = subprocess.CompletedProcess([], 1, b"", json.dumps(self.refusal()).encode())
        refreshed_candidate = subprocess.CompletedProcess([], 1, b"", json.dumps(self.candidate_refusal(recomputed_digest)).encode())
        success = subprocess.CompletedProcess([], 0, b"deployed\n", b"")
        seen = []
        replies = iter((first_candidate, provider_plan, refreshed_candidate, success))

        def run(args, **kwargs):
            seen.append((list(args), kwargs["env"].get("BASEHARBOR_PROVIDER_CHANGE_CONSENT")))
            return next(replies)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            demo = root / "demo"
            fixture_root = root / "fixture"
            binary = root / "bin" / "baha"
            for path in (demo, fixture_root / "data", fixture_root / "config", binary.parent):
                path.mkdir(parents=True, exist_ok=True)
            binary.write_text("fixture binary")
            original_cwd = Path.cwd()
            os.chdir(demo)
            try:
                with mock.patch.dict(os.environ, {
                    "BASEHARBOR_DEMO_FIXTURE": str(fixture_root),
                    "DEMO_ROOT": str(demo),
                    "XDG_DATA_HOME": str(fixture_root / "data"),
                    "XDG_CONFIG_HOME": str(fixture_root / "config"),
                    "BAHA": str(binary),
                }), mock.patch.object(sys, "argv", [str(root / "tests" / "fixture-consent.py"), str(binary), "up", "--yes"]), \
                     mock.patch.object(subprocess, "run", side_effect=run), \
                     contextlib.redirect_stdout(io.TextIOWrapper(io.BytesIO())), \
                     contextlib.redirect_stderr(io.TextIOWrapper(io.BytesIO())):
                    self.assertEqual(fixture.main(), 0)
            finally:
                os.chdir(original_cwd)

        self.assertEqual(len(seen), 4)
        self.assertEqual(seen[1][0][-2:], ["--confirm-candidate", initial_digest])
        self.assertIsNone(seen[1][1])
        self.assertIsNotNone(seen[2][1])
        self.assertEqual(seen[2][0][-2:], ["--confirm-candidate", initial_digest])
        self.assertEqual(seen[3][0][-2:], ["--confirm-candidate", recomputed_digest])
        self.assertEqual(seen[3][0].count("--confirm-candidate"), 1)
        self.assertIsNotNone(seen[3][1])

    def test_set_candidate_confirmation_replaces_stale_digest(self):
        args = ["baha", "up", "--confirm-candidate", "a" * 64, "--json"]
        self.assertEqual(
            fixture.set_candidate_confirmation(args, "b" * 64),
            ["baha", "up", "--json", "--confirm-candidate", "b" * 64],
        )
        with self.assertRaises(ValueError):
            fixture.set_candidate_confirmation(["baha", "up", "--confirm-candidate"], "b" * 64)

    def test_explicit_installation_remainder_cannot_expand_or_retry_failed_mutation(self):
        first, second = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
        child = lambda value: {"scope": {"owner": {"subject": value}}}
        previous = {"all": True, "scope": self.refusal()["error"]["details"]["scope"],
                    "application_resets": [child(first), child(second)], "resources": [{"target": "owned", "project": "owned", "kind": "volume", "name": "owned"}],
                    "local_state_selected_for_deletion": [{"reference": "/isolated/state"}]}
        previous["scope"]["owner"] = {"owner": "installation.destroy"}
        current = copy.deepcopy(previous)
        current["scope"]["plan_id"] = "b" * 64
        current["application_resets"] = [child(second)]
        current["continuation"] = {"previous_plan_id": "a" * 64, "completed_deployment_ids": [first]}
        report = {"all": True, "preview": False, "destroyed": False, "results": [{"status": "REMOVED"}]}

        def result(plan=current, progress=report):
            value = self.refusal()
            value["error"]["details"] = plan
            return subprocess.CompletedProcess([], 1, json.dumps(progress).encode(), json.dumps(value).encode())

        self.assertEqual(fixture.installation_remainder(previous, result()), current)
        diagnostic = {"status": "SKIPPED", "diagnostic": "unregistered-deployment-state", "target": "owned", "resource": "deployment orphan", "detail": "No runtime owner inferred; selected local state explicitly disclosed"}
        disclosed_previous = {**previous, "discovery": [diagnostic]}
        disclosed_current = {**current, "discovery": [diagnostic]}
        progress = {**report, "results": report["results"] + [diagnostic]}
        self.assertEqual(fixture.installation_remainder(disclosed_previous, result(disclosed_current, progress)), disclosed_current)
        runtime_diagnostic = {**diagnostic, "diagnostic": "unregistered-target-runtime", "resource": "runtime-provider"}
        runtime_previous = {**previous, "discovery": [runtime_diagnostic]}
        runtime_current = {**current, "discovery": [runtime_diagnostic]}
        runtime_progress = {**report, "results": report["results"] + [runtime_diagnostic]}
        self.assertEqual(fixture.installation_remainder(runtime_previous, result(runtime_current, runtime_progress)), runtime_current)
        for altered in ({**runtime_diagnostic, "diagnostic": "unknown"}, {**runtime_diagnostic, "status": "FAILED"}, {**runtime_diagnostic, "status": "DEFERRED"}):
            with self.assertRaises(ValueError):
                fixture.installation_remainder(runtime_previous, result(runtime_current, {**report, "results": report["results"] + [altered]}))
        with self.assertRaises(ValueError):
            fixture.installation_remainder(previous, result(runtime_current, runtime_progress))
        with self.assertRaises(ValueError):
            fixture.installation_remainder(previous, result(disclosed_current, progress))
        with self.assertRaises(ValueError):
            fixture.installation_remainder(disclosed_previous, result(current, progress))
        with self.assertRaises(ValueError):
            fixture.installation_remainder(disclosed_previous, result(disclosed_current, {**progress, "results": report["results"] + [{**diagnostic, "detail": "changed unknown state"}]}))
        for change in ("missing", "prior", "owner", "resource", "state", "no-progress"):
            altered = copy.deepcopy(current)
            if change == "missing":
                altered.pop("continuation")
            elif change == "prior":
                altered["continuation"]["previous_plan_id"] = "c" * 64
            elif change == "owner":
                altered["application_resets"] = []
            elif change == "resource":
                altered["resources"][0]["name"] = "foreign"
            elif change == "state":
                altered["local_state_selected_for_deletion"] = []
            else:
                altered["scope"]["plan_id"] = "a" * 64
            with self.assertRaises((ValueError, KeyError)):
                fixture.installation_remainder(previous, result(altered))
        for status in ("FAILED", "SKIPPED", "DEFERRED"):
            with self.assertRaises(ValueError):
                fixture.installation_remainder(previous, result(progress={**report, "results": report["results"] + [{"status": status}]}))


if __name__ == "__main__":
    unittest.main()
