#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


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
    expected = case.get("expected_bindings", [])
    lines = [
        "services:",
        "  demo-app:",
        "    image: busybox:1.37",
        '    user: "65532:65532"',
        "    command:",
        '      - sh',
        '      - -c',
        '      - mkdir -p /tmp/www && printf "ok\\n" > /tmp/www/index.html && exec httpd -f -p 8080 -h /tmp/www',
        "    ports:",
        '      - "${DEMO_HTTP_PORT:-8080}:8080"',
        "    labels:",
        '      io.baseharbor.workload.protocol: "http"',
        "    environment:",
    ]
    for name in expected:
        lines.append("      " + name + ": ${" + name + ":-}")
    if "S3_ENDPOINT" in expected:
        for name in ("S3_ACCESS_KEY", "S3_SECRET_KEY"):
            lines.append("      " + name + ": ${" + name + ":-}")
    lines += [
        "    read_only: true",
        "    cap_drop:",
        "      - ALL",
        "    security_opt:",
        "      - no-new-privileges:true",
        "    tmpfs:",
        "      - /tmp",
        "    restart: unless-stopped",
        "",
    ]
    Path(a.output).write_text("\n".join(lines))


if __name__ == "__main__":
    main()
