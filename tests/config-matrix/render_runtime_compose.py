#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--matrix",required=True)
    p.add_argument("--case",required=True)
    p.add_argument("--output",required=True)
    a=p.parse_args()
    data=json.loads(Path(a.matrix).read_text())
    case=next((x for x in data["cases"] if x["id"]==a.case),None)
    if not case:
        raise SystemExit(f"unknown matrix case: {a.case}")
    expected=case.get("expected_bindings",[])
    lines=[
        "services:","  demo-app:","    build:","      context: ./demo-app",
        '    ports:','      - "${DEMO_HTTPS_PORT:-8080}:8080"',
        "    labels:",'      io.baseharbor.workload.protocol: "https"',
        "    environment:",'      PORT: "8080"','      APP_STATE_DIR: "/var/lib/baseharbor-demo"',
    ]
    for name in expected:
        lines.append("      "+name+": ${"+name+":-}")
    if "S3_ENDPOINT" in expected:
        for name in ("S3_ACCESS_KEY","S3_SECRET_KEY"):
            lines.append("      "+name+": ${"+name+":-}")
    lines += ["    volumes:","      - demo-app-state:/var/lib/baseharbor-demo","    restart: unless-stopped","","volumes:","  demo-app-state:",""]
    Path(a.output).write_text("\n".join(lines))

if __name__=="__main__":
    main()
