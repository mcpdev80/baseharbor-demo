#!/usr/bin/env python3
"""Author an explicit source-only fixture through the real bounded MCP API."""
import hashlib
import json
import pathlib
import selectors
import subprocess
import sys
import uuid

baha, repository, name, component, output = sys.argv[1:]
repository = pathlib.Path(repository).resolve()
process = subprocess.Popen([baha, "mcp", "serve"], cwd=repository,
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, bufsize=1)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)


def call(identifier, method, params):
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier,
                                   "method": method, "params": params}) + "\n")
    process.stdin.flush()
    if not selector.select(timeout=10):
        raise RuntimeError("source-authoring MCP response timeout")
    reply = json.loads(process.stdout.readline())
    if reply.get("id") != identifier or "error" in reply:
        raise RuntimeError("source-authoring MCP transport failed")
    return reply["result"]


def empty_value(schema):
    kind = schema.get("type")
    if isinstance(kind, list):
        if "null" in kind:
            return None
        kind = kind[0]
    if kind == "object":
        return {key: empty_value(schema["properties"][key])
                for key in schema.get("required", [])}
    return {"array": [], "boolean": False, "integer": 0, "string": ""}[kind]


try:
    call(1, "initialize", {"protocolVersion": "2026-07-28", "capabilities": {},
                          "clientInfo": {"name": "static-source-authoring", "version": "1"}})
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    process.stdin.flush()
    tools = call(2, "tools/list", {})["tools"]
    tool = next(tool for tool in tools if tool["name"] == "baseharbor.app.adopt")
    intent = empty_value(tool["inputSchema"]["properties"]["intent"])
    intent.update(Version=1, ApplicationID=str(uuid.uuid4()), Name=name, Environment="dev")
    intent["Workload"]["Components"] = [component]
    args = {"repository": str(repository), "intent": intent}
    result = call(3, "tools/call", {"name": tool["name"], "arguments": args})
    if result.get("isError"):
        raise RuntimeError("explicit source authoring was rejected")
    manifest = repository / "baseharbor.yaml"
    before = hashlib.sha256(manifest.read_bytes()).hexdigest()
    denied = call(4, "tools/call", {"name": tool["name"], "arguments": args})
    if not denied.get("isError") or hashlib.sha256(manifest.read_bytes()).hexdigest() != before:
        raise RuntimeError("source authoring overwrote an existing manifest")
    pathlib.Path(output).write_text(json.dumps(result, indent=2) + "\n")
finally:
    selector.close()
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
