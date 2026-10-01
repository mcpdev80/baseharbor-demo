#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def render(case):
    caps = set(case["capabilities"])
    management = set(case.get("management_ui", []))
    name = "matrix-" + case["id"]
    out = [
        "version: 1",
        "app:",
        "  id: 11111111-1111-4111-8111-111111111111",
        f"  name: {name}",
        "  environment: dev",
    ]
    services = []
    if "sql" in caps:
        services += ["  sql:", "    enabled: true"]
        if "sql" in management:
            services += ["    management_ui: true"]
    if "cache" in caps:
        services += ["  cache:", "    enabled: true"]
    if "object_storage" in caps:
        services += ["  object_storage:", "    buckets:", "      uploads: {}"]
    if "secrets" in caps:
        services += ["  secrets:", "    enabled: true"]
    if "identity" in caps:
        services += ["  identity:", "    enabled: true"]
    if services:
        out += ["services:"] + services
    if "identity" in caps:
        out += [
            "identity:",
            "  callback_paths:",
            "    - /oauth/callback",
            "  logout_paths:",
            "    - /",
            "  scopes:",
            "    - openid",
            "    - profile",
            "    - email",
        ]
    if "secrets" in caps:
        out += [
            "secrets:",
            "  required:",
            "    - name: APP_SECRET",
            "      generate:",
            "        type: random",
            "        length: 32",
        ]
    out += [
        "workload:",
        "  compose: compose.yaml",
        "  services:",
        "    - demo-app",
        "exposure:",
        "  http:",
        "    - name: app",
        "      service: demo-app",
        "      port: 8080",
        "      protocol: http",
        "      visibility: public",
    ]
    if "metrics" in caps:
        out += [
            "metrics:",
            "  sources:",
            "    - name: app",
            "      service: demo-app",
            "      port: 8080",
            "      path: /metrics",
        ]
    if "logs" in caps:
        out += ["logs:", "  collect:", "    - application"]
    if "telemetry" in caps:
        out += ["telemetry:", "  otlp:", "    signals:", "      - traces"]
    return "\n".join(out) + "\n"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--matrix", required=True)
    p.add_argument("--case", required=True)
    p.add_argument("--output", required=True)
    a = p.parse_args()
    data = json.loads(Path(a.matrix).read_text())
    case = next((x for x in data["cases"] if x["id"] == a.case), None)
    if not case:
        raise SystemExit(f"unknown matrix case: {a.case}")
    Path(a.output).write_text(render(case))


if __name__ == "__main__":
    main()
