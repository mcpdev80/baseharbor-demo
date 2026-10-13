#!/usr/bin/env python3
"""Acknowledge one actual current Core refusal in an isolated positive fixture."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def current_consent(value):
    error = value.get("error", {})
    if (value.get("contract_version"), error.get("code"), error.get("cause")) != (
        "v1", "approval_required", "impact-confirmation-required"
    ):
        raise ValueError("not a current provider-plan refusal")
    details = error.get("details", {})
    plan = details.get("scope", details)
    if plan.get("version") not in {"baseharbor.provider-impact/v1", "baseharbor.provider-impact-scope/v1"}:
        raise ValueError("unsupported impact contract")
    if not re.fullmatch(r"[0-9a-f]{64}", plan.get("plan_id", "")):
        raise ValueError("missing immutable plan ID")
    count = plan.get("confirmations_required")
    if type(count) is not int or count not in (1, 2):
        raise ValueError("invalid acknowledgement stages")
    if any(type(plan.get(key)) is not bool for key in ("destructive", "complete")):
        raise ValueError("untyped consequence flags")
    if (plan["destructive"] or not plan["complete"] or plan.get("attention")) and count != 2:
        raise ValueError("incomplete consequence needs two stages")
    return {"plan_id": plan["plan_id"], "first": True, "second": count == 2, "delete_data": plan["destructive"]}


def main():
    fixture = Path(os.environ["BASEHARBOR_DEMO_FIXTURE"]).resolve(strict=True)
    root = Path(os.environ["DEMO_ROOT"]).resolve(strict=True)
    cwd = Path.cwd().resolve(strict=True)
    if cwd != root and root not in cwd.parents:
        raise ValueError("fixture command outside selected Demo source")
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME"):
        if fixture not in Path(os.environ[key]).resolve().parents:
            raise ValueError("provider owner outside isolated fixture")
    args = sys.argv[1:]
    if not args or Path(args[0]).resolve() != Path(os.environ["BAHA"]).resolve():
        raise ValueError("only selected Core binary may acknowledge fixture plans")
    if "--json" not in args:
        args.append("--json")
    env = dict(os.environ)
    env.pop("BASEHARBOR_PROVIDER_CHANGE_CONSENT", None)
    result = subprocess.run(args, env=env, capture_output=True, timeout=900)
    if result.returncode:
        try:
            consent = current_consent(json.loads(result.stderr))
        except (ValueError, TypeError, AttributeError):
            sys.stdout.buffer.write(result.stdout)
            sys.stderr.buffer.write(result.stderr)
            return result.returncode
        print("isolated-demo-fixture: explicit current-plan stages and separate owned-data consent", file=sys.stderr)
        env["BASEHARBOR_PROVIDER_CHANGE_CONSENT"] = json.dumps(consent)
        result = subprocess.run(args, env=env, capture_output=True, timeout=900)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
