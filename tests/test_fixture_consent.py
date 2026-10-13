import importlib.util
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


if __name__ == "__main__":
    unittest.main()
