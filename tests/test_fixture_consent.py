import importlib.util
import copy
import json
import subprocess
import unittest
from pathlib import Path

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
