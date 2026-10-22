#!/usr/bin/env python3
"""Exercise registered New/Edit/Footprint contracts without starting a runtime."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time


def snapshot(root):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("unexpected symlink in isolated static fixture")
        if path.is_file():
            result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


@contextmanager
def mcp_session(baha, project, env=None):
    """Use the actual bounded stdio transport for static and native Footprint reads."""
    process = subprocess.Popen([baha, "mcp", "serve"], cwd=project, env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, bufsize=1)
    request_id = 0

    def call(method, params):
        nonlocal request_id
        request_id += 1
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id,
                                        "method": method, "params": params}) + "\n")
        process.stdin.flush()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            line = process.stdout.readline()
            if not line:
                raise RuntimeError("MCP process ended before its response")
            response = json.loads(line)
            if response.get("id") == request_id:
                if "error" in response:
                    raise RuntimeError("MCP request rejected at the protocol boundary")
                return response["result"]
        raise RuntimeError("MCP response timeout")
    try:
        call("initialize", {"protocolVersion": "2026-07-28", "capabilities": {},
                            "clientInfo": {"name": "baseharbor-demo-static", "version": "1"}})
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n")
        process.stdin.flush()
        yield call
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def main():
    baha, output = sys.argv[1:]
    with tempfile.TemporaryDirectory(prefix="baseharbor-mcp-static-") as directory:
        root = Path(directory)
        project = root / "project"
        project.mkdir()
        (project / "compose.yaml").write_text("services:\n  api:\n    image: alpine:3.22\n    command: [sleep, '300']\n")
        env = {**os.environ, "BASEHARBOR_STATE_DIR": str(root / "state"),
               "XDG_CONFIG_HOME": str(root / "config"), "XDG_DATA_HOME": str(root / "data"),
               "BASEHARBOR_TARGET": "mcp-static", "BASEHARBOR_LOGS_ENABLED": "false"}

        def cli(*arguments):
            return json.loads(subprocess.check_output([baha, *arguments], cwd=project,
                                                     env=env, timeout=30))

        subprocess.run([baha, "target", "create", "mcp-static", "--provider", "docker",
                        "--access", "local-docker", "--reference", "local", "--scope",
                        "default", "--default"], cwd=project, env=env, check=True,
                       stdout=subprocess.DEVNULL, timeout=30)
        initialized = cli("init", "--quick", "--json")
        if not initialized.get("application_id"):
            raise RuntimeError("source-only init did not establish application identity")
        before = snapshot(root)
        with mcp_session(baha, project, env) as call:
            tools = {tool["name"]: tool for tool in call("tools/list", {})["tools"]}
            for name in ["baseharbor.app.new", "baseharbor.app.edit", "baseharbor.app.footprint.show"]:
                if name not in tools:
                    raise RuntimeError("registered application operation is missing")
            footprint = call("tools/call", {"name": "baseharbor.app.footprint.show",
                                            "arguments": {"target": "mcp-static"}})
            if footprint.get("isError"):
                raise RuntimeError("source-only Footprint call failed")
            actual = footprint.get("structuredContent")
            expected = cli("app", "footprint", "show", "-o", "json")
            if (not isinstance(actual, dict) or actual.get("version") != "baseharbor.footprint/v1"
                    or actual.get("target") != "mcp-static" or actual != expected):
                raise RuntimeError("CLI/JSON and MCP Footprint contracts differ")
            proposed = call("tools/call", {"name": "baseharbor.app.edit", "arguments": {
                "target": "mcp-static", "phase": "propose", "desired": {
                    "target": "mcp-static", "snapshot_revision": "deliberately-stale-static-snapshot"}}})
            refusal = proposed.get("structuredContent", {})
            if (proposed.get("isError") is not True or refusal.get("contract_version") != "v1"
                    or refusal.get("error", {}).get("code") != "conflict"):
                raise RuntimeError("stale Edit proposal did not return a typed conflict")
            unconsented = call("tools/call", {"name": "baseharbor.app.edit", "arguments": {
                "target": "mcp-static", "phase": "apply", "desired": {
                    "target": "mcp-static", "snapshot_revision": "deliberately-stale-static-snapshot"}}})
            rejected = unconsented.get("structuredContent", {})
            if (unconsented.get("isError") is not True or rejected.get("contract_version") != "v1"
                    or rejected.get("error", {}).get("code") != "validation_failed"):
                raise RuntimeError("Edit apply without proposal/consent was not rejected")
        if snapshot(root) != before:
            raise RuntimeError("Footprint or rejected Edit proposal changed source/state")
        Path(output).write_text(json.dumps({"scope": "source-only-static-mcp", "result": "success",
            "footprint_cli_json_parity": True, "stale_edit_proposal": "conflict",
            "unconsented_edit_apply": "validation_failed",
            "source_and_state_unchanged": True, "native_runtime_qualified": False}, indent=2) + "\n")


if __name__ == "__main__":
    main()
