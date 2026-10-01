#!/usr/bin/env python3
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

PREFIX = {
    "sql": ("database.sql:",),
    "cache": ("cache.key-value:",),
    "object_storage": ("s3-bucket:",),
    "secrets": ("secrets-scope", "secret:"),
    "identity": ("identity:",),
    "metrics": ("metrics:",),
    "logs": ("logs:",),
    "telemetry": ("telemetry.otlp:",),
}

def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)

def has_prefix(resources, prefixes):
    return any(any(r == p or r.startswith(p) for p in prefixes) for r in resources)

def render_case(renderer, matrix, case_id, root):
    subprocess.run([
        "python3", str(renderer), "--matrix", str(matrix), "--case", case_id,
        "--output", str(root / "baseharbor.yaml")
    ], check=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baha", required=True)
    ap.add_argument("--demo-root", required=True)
    args = ap.parse_args()

    demo = Path(args.demo_root).resolve()
    matrix = demo / "tests/config-matrix/cases.json"
    renderer = demo / "tests/config-matrix/render.py"
    cases = json.loads(matrix.read_text())["cases"]

    with tempfile.TemporaryDirectory(prefix="baseharbor-config-matrix-") as td:
        root = Path(td)
        for case in cases:
            case_root = root / case["id"]
            case_root.mkdir()
            shutil.copy(demo / "compose.yaml", case_root / "compose.yaml")
            render_case(renderer, matrix, case["id"], case_root)
            p = run([args.baha, "app", "plan", "-o", "json"], case_root)
            if p.returncode:
                raise SystemExit(f"{case['id']}: plan failed:\n{p.stderr}")
            plan = json.loads(p.stdout)
            resources = [a["resource"] for a in plan.get("actions", [])]
            if "workload" not in resources or "exposure:app" not in resources:
                raise SystemExit(f"{case['id']}: workload/exposure missing: {resources}")
            enabled = set(case["capabilities"])
            for capability, prefixes in PREFIX.items():
                present = has_prefix(resources, prefixes)
                if capability in enabled and not present:
                    raise SystemExit(f"{case['id']}: {capability} missing from plan: {resources}")
                if capability not in enabled and present:
                    raise SystemExit(f"{case['id']}: phantom {capability} resource in plan: {resources}")
            print(f"PASS {case['id']}: {','.join(resources)}")

        negative = {
            "management-ui-without-provider": """version: 1
app:
  id: 11111111-1111-4111-8111-111111111111
  name: invalid-ui
  environment: dev
services:
  sql:
    enabled: false
    management_ui: true
workload:
  compose: compose.yaml
  services:
    - demo-app
""",
            "invalid-telemetry-signal": """version: 1
app:
  id: 11111111-1111-4111-8111-111111111111
  name: invalid-telemetry
  environment: dev
workload:
  compose: compose.yaml
  services:
    - demo-app
telemetry:
  otlp:
    signals:
      - bananas
""",
            "metrics-target-not-selected": """version: 1
app:
  id: 11111111-1111-4111-8111-111111111111
  name: invalid-metrics
  environment: dev
workload:
  compose: compose.yaml
  services:
    - demo-app
metrics:
  sources:
    - name: worker
      service: worker
      port: 8080
      path: /metrics
""",
            "runtime-permission-target-not-selected": """version: 1
app:
  id: 11111111-1111-4111-8111-111111111111
  name: invalid-runtime
  environment: dev
workload:
  compose: compose.yaml
  services:
    - demo-app
runtime:
  permissions:
    - capability: object-storage.s3/v1
      services:
        - worker
      operations:
        - runtime.create
""",
        }
        for name, manifest in negative.items():
            case_root = root / name
            case_root.mkdir()
            shutil.copy(demo / "compose.yaml", case_root / "compose.yaml")
            (case_root / "baseharbor.yaml").write_text(manifest)
            p = run([args.baha, "app", "plan", "-o", "json"], case_root)
            if p.returncode == 0:
                raise SystemExit(f"{name}: invalid contract unexpectedly planned successfully: {p.stdout}")
            print(f"PASS {name}: rejected before mutation")

if __name__ == "__main__":
    main()
