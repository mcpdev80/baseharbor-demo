#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "MCP"
python3 - "$BAHA" "$DEMO_ROOT" "$ARTIFACT_DIR/mcp.json" <<'PY'
import json, subprocess, sys, time
baha, cwd, output = sys.argv[1:]
p = subprocess.Popen([baha, "mcp", "serve"], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
try:
    def call(msg):
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()
        deadline = time.time() + 5
        while time.time() < deadline:
            line = p.stdout.readline()
            if line:
                return json.loads(line)
        raise RuntimeError("MCP response timeout")

    init = call({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28","capabilities":{},"clientInfo":{"name":"baseharbor-demo","version":"1"}}})
    p.stdin.write(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized","params":{}}) + "\n")
    p.stdin.flush()
    tools = call({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
    data = {"initialize":init,"tools":tools}
    open(output, "w").write(json.dumps(data, indent=2))
    names = {t["name"] for t in tools["result"]["tools"]}
    expected = {
        "baseharbor.target",
        "baseharbor.inspect",
        "baseharbor.plan",
        "baseharbor.apply",
        "baseharbor.status",
        "baseharbor.doctor",
        "baseharbor.observe",
        "baseharbor.update",
        "baseharbor.repair",
        "baseharbor.backup",
        "baseharbor.restore",
        "baseharbor.destroy",
        "baseharbor.policy.check",
        "baseharbor.policy.explain",
    }
    if names != expected:
        raise RuntimeError(f"unexpected MCP tools: {sorted(names)}")
finally:
    p.terminate()
    try: p.wait(timeout=2)
    except subprocess.TimeoutExpired: p.kill()
PY
assert_no_secret_leak "$ARTIFACT_DIR/mcp.json"
pass "MCP" "bounded semantic lifecycle stdio surface"
