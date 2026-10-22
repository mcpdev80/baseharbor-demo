#!/usr/bin/env python3
"""Real public CLI journeys, bounded to the existing Demo fixture Target.

The light gate exercises zero needs. SQL journeys import these same PTY/state
helpers from the existing heavy data-capabilities gate. No private controller,
registry writes, approval flags or synthesized provider IDs are used.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess

from drive import ANSI_ESCAPE, ARTIFACT_DIR, BAHA, ROOT, Rule, run_tty

NEEDS_END = r"No SQL, identity service, secrets service or management stack is mandatory\."
PICKER_END = r"P: optional provider preference · Esc/Ctrl\+C: cancel"


def native_environment(runtime):
    """Use the host engine context, preserving BaseHarbor's separate XDG state."""
    environment = os.environ.copy()
    if Path(runtime).name == "podman":
        environment.pop("XDG_CONFIG_HOME", None)
        environment.pop("XDG_DATA_HOME", None)
    return environment


def cli(project, *arguments):
    return subprocess.check_output([BAHA, *arguments], cwd=project, timeout=120,
                                   env={**os.environ, "BASEHARBOR_LOGS_ENABLED": "false"})


def footprint(project):
    result = json.loads(cli(project, "app", "footprint", "show", "-o", "json"))
    if (result.get("version") != "baseharbor.footprint/v1"
            or result.get("target") != os.environ["BASEHARBOR_TARGET"]
            or not result.get("application_id")):
        raise RuntimeError("Footprint lost its version, application or fixture Target identity")
    return result


def footprint_parity(project):
    # Reuse the existing MCP gate's bounded real stdio client.
    module_path = Path(__file__).resolve().parents[1] / "mcp" / "new-edit-static.py"
    spec = importlib.util.spec_from_file_location("demo_mcp_new_edit", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    expected = footprint(project)
    with module.mcp_session(BAHA, project, {**os.environ, "BASEHARBOR_LOGS_ENABLED": "false"}) as call:
        result = call("tools/call", {"name": "baseharbor.app.footprint.show", "arguments": {
            "target": expected["target"]}})
    if result.get("isError") or result.get("structuredContent") != expected:
        raise RuntimeError("actual native CLI JSON/MCP Footprint contracts differ")
    return expected


def filesystem_snapshot(roots):
    """Compare bytes, types, modes and inventories; never disclose state contents."""
    result = {}
    excluded = [ARTIFACT_DIR.resolve()]
    for root in roots:
        root = Path(root)
        if not root.exists():
            result[str(root)] = None
            continue
        for path in [root, *sorted(root.rglob("*"))]:
            if ".git" in path.relative_to(root).parts:
                continue
            if any(path == ignored or ignored in path.parents for ignored in excluded):
                continue
            info = path.lstat()
            item = [stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode)]
            if path.is_symlink():
                item.append(os.readlink(path))
            elif path.is_file():
                item.append(hashlib.sha256(path.read_bytes()).hexdigest())
            result[str(path)] = item
    return result


def state_snapshot(project, native=True):
    roots = [ROOT, project, Path(os.environ["XDG_CONFIG_HOME"]), Path(os.environ["XDG_DATA_HOME"])]
    if os.environ.get("BASEHARBOR_STATE_DIR"):
        roots.append(Path(os.environ["BASEHARBOR_STATE_DIR"]))
    result = {"files": filesystem_snapshot(roots)}
    if native:
        runtime = os.environ["BASEHARBOR_TEST_RUNTIME"]
        environment = native_environment(runtime)
        # Ambient preservation needs only stable public metadata, never a full
        # inspect of unrelated containers and their environment/configuration.
        result["containers"] = sorted(subprocess.check_output([runtime, "ps", "-a", "--no-trunc",
            "--format", "{{.ID}}\t{{.Names}}\t{{.State}}"], timeout=30,
            env=environment).decode().splitlines())
        for kind in ["volume", "network"]:
            result[kind] = sorted(subprocess.check_output([runtime, kind, "ls", "-q"], timeout=30,
                env=environment).decode().split())
    return result


def assert_unchanged(before, project, native=True):
    if state_snapshot(project, native) != before:
        raise RuntimeError("No/Cancel changed source, Target state or native resource inventory")


def stack_go(match, text):
    choices = re.findall(r"(?m)^\s*(\d+)\. go \([^\r\n]+\)", ANSI_ESCAPE.sub("", text))
    if len(choices) != 1:
        raise RuntimeError("actual stack catalog did not offer exactly one Go stack")
    return choices[0] + "\n"


def picker_keys(text, sql=False):
    clean = ANSI_ESCAPE.sub("", text)
    # Use the most recent frame; the renderer can repaint while earlier frames
    # remain in the transcript. Refuse an unknown/missing row instead of choosing
    # a guessed capability index.
    frame = clean.rsplit("What does your application need?", 1)[-1]
    rows = re.findall(r"(?m)^\s*([>]?)\s*\[([ x])\]\s+([^\r\n]+?) —", frame)
    if len(rows) != 5 or sum(pointer == ">" for pointer, _, _ in rows) != 1:
        raise RuntimeError("actual needs picker did not render its five everyday choices")
    desired = {"SQL database"} if sql else set()
    labels = {label for _, _, label in rows}
    if not desired <= labels:
        raise RuntimeError("actual needs picker did not offer the requested SQL capability")
    cursor = next(i for i, row in enumerate(rows) if row[0] == ">")
    keys = []
    for index, (_, mark, label) in enumerate(rows):
        if (mark == "x") == (label in desired):
            continue
        keys.extend(["\x1b[B" if index > cursor else "\x1b[A"] * abs(index - cursor))
        keys.append(" ")
        cursor = index
    return keys + ["\r"]


class CurrentConsent:
    """Only the displayed operation's exact ordered non-destructive plan."""
    def __init__(self):
        self.plan = None
        self.stage = 0
        self.total = None

    def respond(self, match, text):
        stage, total, plan = int(match[1]), int(match[2]), match[3]
        if self.plan is None:
            self.plan, self.total = plan, total
        if plan != self.plan or total != self.total or stage != self.stage + 1 or stage > total:
            raise RuntimeError("provider consequence plan changed or confirmation was replayed")
        self.stage = stage
        return "yes\n"

    def rule(self):
        return Rule(r"(?:Confirm the displayed provider changes|Achtung: confirm the displayed outcome without a working alternative) \(([12])/([12]), plan ([0-9a-f]{64})\)\? \[y/N\]:\s*$",
                    callback=self.respond, repeat=True, optional=True)


def new_application(parent, name, *, sql=False, decision="run", native=True, environment=None):
    project = parent / name
    if project.exists():
        raise RuntimeError("New fixture refuses to reuse an existing application directory")
    before = state_snapshot(parent, native)
    picker_count = 0

    def picker(match, text):
        nonlocal picker_count
        picker_count += 1
        if decision == "cancel" or picker_count > 1:
            assert_unchanged(before, parent, native)
            return "\x1b"  # actual New terminal Cancel, never controller injection
        return picker_keys(text, sql)

    rules = [Rule(r"Application name:\s*$", name + "\n"),
             Rule(r"Project location(?::[^\r\n]*\$ | \[[^\]]+\]:\s*)$", str(parent) + "\n"),
             Rule(r"Choose a stack.*?Selection \[1\]:\s*$", callback=stack_go),
             Rule(r"After creation \(create-only or run\) \[create-only\]:\s*$", "run\n"),
             Rule(PICKER_END, callback=picker)]
    if decision != "cancel":
        returned_picker = Rule(PICKER_END, callback=picker, optional=True)
        returned_picker.used = 1  # only arm after the real No decision

        def confirm(match, text):
            if decision == "eof":
                return "\x04"
            if decision == "no":
                assert_unchanged(before, parent, native)
                returned_picker.used = 0
                returned_picker.optional = False
                return "n\n"
            return "y\n"

        rules.append(Rule(r"Create project files and continue into the separately authorized lifecycle\? \[Y/n\]\s*$",
                          callback=confirm))
        rules.append(returned_picker)
    consent = CurrentConsent()
    rules.extend([consent.rule(),
        Rule(r"Is this installation running on a machine where you write code\?.*?Choice \[1\]:\s*$", "1\n", optional=True),
        Rule(r"PostgreSQL host port \[\d+\]:\s*$", "\n", optional=True)])
    run_tty("new-edit-" + name, [BAHA, "app", "new"], rules, cwd=ROOT,
            env={"BASEHARBOR_LOGS_ENABLED": "false", **(environment or {})},
            timeout=600, no_output_timeout=90)
    if decision in ("no", "cancel", "eof"):
        assert_unchanged(before, parent, native)
        if project.exists():
            raise RuntimeError("New No/Cancel wrote a project")
        if decision == "no" and picker_count != 2:
            raise RuntimeError("New No did not return to the needs picker before Cancel")
        return None
    actual = footprint(project)
    if "Lifecycle: VERIFIED" not in (ARTIFACT_DIR / ("new-edit-" + name + ".txt")).read_text():
        raise RuntimeError("New returned without its completed lifecycle receipt")
    requirements = actual.get("requirements") or []
    kinds = {row["requirement"]["kind"] for row in requirements}
    if kinds != ({"database.sql"} if sql else set()):
        raise RuntimeError("New did not persist exactly the selected needs")
    if not actual.get("complete"):
        raise RuntimeError("New did not establish a complete native Footprint")
    return project


def edit_application(project, operation, *, instance=None, native=True, environment=None):
    """Drive the actual public Edit needs/preview/consequence prompts."""
    before = state_snapshot(project, native)
    consent = CurrentConsent()
    if operation in ("no", "cancel"):
        def cancel(match, text):
            assert_unchanged(before, project, native)
            return "cancel\n"
        rules = [Rule(NEEDS_END, callback=cancel)] if operation == "cancel" else [
            Rule(NEEDS_END, "enter\n"),
            Rule(r"Read-only decision preview \(not execution\)", "no\n"),
            Rule(NEEDS_END, callback=cancel),
        ]
    elif operation in ("add", "remove"):
        rules = [Rule(NEEDS_END, "space\n"), Rule(NEEDS_END, "enter\n"),
                 Rule(r"Read-only decision preview \(not execution\)", "yes\n")]
    elif operation == "switch" and instance:
        requirements = [row["requirement"] for row in footprint(project).get("requirements") or []
                        if row["requirement"]["kind"] == "database.sql"]
        if len(requirements) != 1:
            raise RuntimeError("provider switch requires exactly one actual SQL requirement")
        reference = requirements[0]["kind"] + "/" + requirements[0]["name"]
        rules = [Rule(r"\[[ x]\] " + re.escape(instance) + r" \(postgresql\):[^\r\n]+",
                      "provider " + reference + " " + instance + "\n"),
                 Rule(NEEDS_END, "enter\n"),
                 Rule(r"Read-only decision preview \(not execution\)", "yes\n")]
    else:
        raise ValueError("unknown Edit fixture operation")
    rules.append(consent.rule())
    run_tty("new-edit-" + project.name + "-" + operation, [BAHA, "app", "edit"], rules,
            cwd=project, env={"BASEHARBOR_LOGS_ENABLED": "false", **(environment or {})},
            timeout=600, no_output_timeout=90, expected_returncodes=(0, 1) if operation in ("no", "cancel") else (0,))
    if operation in ("no", "cancel"):
        assert_unchanged(before, project, native)
        transcript = (ARTIFACT_DIR / ("new-edit-" + project.name + "-" + operation + ".txt")).read_text()
        if not any(message in transcript for message in (
                "Cancelled; no application changes.", "Error: wizard cancelled without changes")):
            raise RuntimeError("Edit did not report the actual Cancel outcome")
    elif consent.plan is not None and consent.stage != consent.total:
        raise RuntimeError("Edit did not consume every required consequence confirmation")
    return footprint(project)


def main():
    parent = ROOT / ".new-edit-fixtures"
    parent.mkdir(exist_ok=True)
    new_application(parent, "new-cancel", decision="cancel")
    new_application(parent, "new-no", decision="no")
    project = new_application(parent, "new-zero")
    edit_application(project, "cancel")
    edit_application(project, "no")
    result = footprint_parity(project)
    (ARTIFACT_DIR / "new-edit-zero.json").write_text(json.dumps({
        "journey": "real-cli-new-zero-needs", "target": result["target"],
        "application_id": result["application_id"], "requirements": result["requirements"],
        "new_no_cancel_unchanged": True, "native_runtime_qualified": True,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
