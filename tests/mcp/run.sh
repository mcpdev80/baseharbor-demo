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
    entries = tools["result"]["tools"]
    names = {t["name"] for t in entries}
    if len(names) != len(entries):
        raise RuntimeError("duplicate MCP tool names")
    expected = {
        "baseharbor.installation.destroy",
        "baseharbor.release.check",
        "baseharbor.control-plane.status",
        "baseharbor.control-plane.doctor",
        "baseharbor.control-plane.up",
        "baseharbor.control-plane.stop",
        "baseharbor.control-plane.repair",
        "baseharbor.control-plane.destroy",
        "baseharbor.openbao.status",
        "baseharbor.openbao.bootstrap",
        "baseharbor.openbao.unseal",
        "baseharbor.openbao.rotate",
        "baseharbor.dev.domain",
        "baseharbor.dev.credentials",
        "baseharbor.app.environment",
        "baseharbor.app.connection",
        "baseharbor.connectivity.list",
        "baseharbor.connectivity.connect",
        "baseharbor.connectivity.disconnect",
        "baseharbor.operator.identity",
        "baseharbor.provider.init",
        "baseharbor.provider.test",
        "baseharbor.workspace.show",
        "baseharbor.app.show",
        "baseharbor.app.create",
        "baseharbor.app.adopt",
        "baseharbor.app.configure",
        "baseharbor.runtime-identity.rotate",
        "baseharbor.runtime-identity.revoke",
        "baseharbor.tls.update",
        "baseharbor.trust.status",
        "baseharbor.trust.export",
        "baseharbor.trust.install",
        "baseharbor.app.stop",
        "baseharbor.app.preflight",
        "baseharbor.secret.list",
        "baseharbor.secret.set",
        "baseharbor.secret.delete",
        "baseharbor.secret.tls-set",
        "baseharbor.target.create",
        "baseharbor.target.delete",
        "baseharbor.stack.list",
        "baseharbor.stack.show",
        "baseharbor.stack.create",
        "baseharbor.workspace.init",
        "baseharbor.workspace.map",
        "baseharbor.target",
        "baseharbor.target.list",
        "baseharbor.runtime.capabilities",
        "baseharbor.runtime.list",
        "baseharbor.runtime.inspect",
        "baseharbor.runtime.metrics",
        "baseharbor.runtime.start",
        "baseharbor.runtime.stop",
        "baseharbor.runtime.restart",
        "baseharbor.app.list",
        "baseharbor.inspect",
        "baseharbor.workspace.list",
        "baseharbor.workspace.resolve",
        "baseharbor.workspace.status",
        "baseharbor.workspace.update",
        "baseharbor.app.new",
        "baseharbor.plan",
        "baseharbor.apply",
        "baseharbor.status",
        "baseharbor.doctor",
        "baseharbor.observe",
        "baseharbor.evidence",
        "baseharbor.update",
        "baseharbor.repair",
        "baseharbor.backup",
        "baseharbor.restore",
        "baseharbor.destroy",
        "baseharbor.policy.check",
        "baseharbor.provider.list",
        "baseharbor.provider.inspect",
        "baseharbor.provider.verify",
        "baseharbor.provider.add",
        "baseharbor.provider.remove",
        "baseharbor.organization.inspect",
        "baseharbor.organization.check",
        "baseharbor.organization.set",
        "baseharbor.organization.update",
        "baseharbor.policy.explain",
    }
    if names != expected:
        raise RuntimeError(f"MCP contract mismatch: missing={sorted(expected - names)} unexpected={sorted(names - expected)}")
    read_only = {
        "baseharbor.release.check",
        "baseharbor.control-plane.status",
        "baseharbor.control-plane.doctor",
        "baseharbor.openbao.status",
        "baseharbor.app.environment",
        "baseharbor.app.connection",
        "baseharbor.connectivity.list",
        "baseharbor.operator.identity",
        "baseharbor.provider.test",
        "baseharbor.workspace.show",
        "baseharbor.app.show",
        "baseharbor.trust.status",
        "baseharbor.app.preflight",
        "baseharbor.secret.list",
        "baseharbor.stack.list",
        "baseharbor.stack.show",
        "baseharbor.target",
        "baseharbor.target.list",
        "baseharbor.runtime.capabilities",
        "baseharbor.runtime.list",
        "baseharbor.runtime.inspect",
        "baseharbor.runtime.metrics",
        "baseharbor.app.list",
        "baseharbor.inspect",
        "baseharbor.workspace.list",
        "baseharbor.workspace.resolve",
        "baseharbor.workspace.status",
        "baseharbor.plan",
        "baseharbor.status",
        "baseharbor.doctor",
        "baseharbor.observe",
        "baseharbor.evidence",
        "baseharbor.policy.check",
        "baseharbor.provider.list",
        "baseharbor.provider.inspect",
        "baseharbor.provider.verify",
        "baseharbor.organization.inspect",
        "baseharbor.organization.check",
        "baseharbor.policy.explain",
    }
    destructive = {
        "baseharbor.installation.destroy",
        "baseharbor.control-plane.destroy",
        "baseharbor.runtime-identity.revoke",
        "baseharbor.secret.delete",
        "baseharbor.destroy",
        "baseharbor.provider.remove",
    }
    for tool in entries:
        name = tool["name"]
        schema = tool.get("inputSchema", {})
        if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
            raise RuntimeError(f"unbounded MCP input schema: {name}")
        annotations = tool.get("annotations", {})
        if annotations.get("readOnlyHint") is not (name in read_only) or annotations.get("destructiveHint") is not (name in destructive):
            raise RuntimeError(f"incorrect MCP safety annotations: {name}")
finally:
    p.terminate()
    try: p.wait(timeout=2)
    except subprocess.TimeoutExpired: p.kill()
PY
assert_no_secret_leak "$ARTIFACT_DIR/mcp.json"
pass "MCP" "bounded semantic lifecycle stdio surface"
