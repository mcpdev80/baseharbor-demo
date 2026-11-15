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

from drive import ANSI_ESCAPE, ARTIFACT_DIR, BAHA, ROOT, Rule, capture_confirm_hash, run_tty

NEEDS_END = r"No SQL, identity service, secrets service or management stack is mandatory\."
PICKER_END = r"[Pp]: (?:optional )?provider preference(?: · b/←: previous row)? · Esc/Ctrl\+C: cancel"


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


def edit_picker_rule(sql):
    """Change only the SQL checkbox shown by the current Edit needs picker."""
    changed = False

    def respond(match, text):
        nonlocal changed
        clean = ANSI_ESCAPE.sub("", text)
        frame = clean.rsplit("What does your application need?", 1)[-1]
        rows = re.findall(r"(?m)^\s*([>]?)\s*\[([ x])\]\s+([^\r\n]+?) —", frame)
        if len(rows) != 5 or sum(pointer == ">" for pointer, _, _ in rows) != 1:
            raise RuntimeError("Edit needs picker did not render its five everyday choices")
        sql_rows = [(index, row) for index, row in enumerate(rows) if row[2] == "SQL database"]
        if len(sql_rows) != 1:
            raise RuntimeError("Edit needs picker did not render exactly one SQL choice")
        index, (pointer, mark, _) = sql_rows[0]
        cursor = next(i for i, row in enumerate(rows) if row[0] == ">")
        selected = mark == "x"
        if selected != sql:
            if changed:
                # A redraw has not yet reflected the first key. Wait for output
                # instead of toggling the same visible state twice.
                return None
            changed = True
            keys = [("down\n" if index > cursor else "up\n")] * abs(index - cursor)
            # Edit's needs surface reads complete lines. Send a real Space
            # command, cycle the cursor to force a redraw, then wait for the
            # next rendered frame before deciding whether Enter is safe.
            return keys + [" \n", "down\n", "up\n"]
        rule.repeat = False
        # driveAppEditWizard reads newline-delimited commands from its stdin
        # reader; a bare carriage return leaves it waiting forever.
        return "enter\n"

    rule = Rule(NEEDS_END, callback=respond, repeat=True)
    return rule


class CurrentConsent:
    """Only the displayed operation's exact ordered non-destructive plan."""
    def __init__(self):
        self.plan = None
        self.stage = 0
        self.total = None

    def reset(self):
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


def apply_changes_rule(decision, *, require_provider_changes=False):
    """Confirm provider-plan changes when this journey selects a provider."""
    return Rule(r"Apply these changes\? \[y/N\]:?\s*$", "y\n", repeat=True,
                optional=decision != "run" or not require_provider_changes)


def new_application(parent, name, *, sql=False, decision="run", native=True, environment=None,
                    mode="run"):
    if mode not in ("run", "create-only"):
        raise ValueError("New fixture mode must be run or create-only")
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
             Rule(r"After creation \(create-only or run\) \[create-only\]:\s*$", mode + "\n"),
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

        rules.append(Rule(r"Create project files (?:only \(does not start containers or deploy providers\)|and continue into the separately authorized lifecycle)\? \[Y/n\]\s*$",
                          callback=confirm))
        rules.append(returned_picker)
    consent = CurrentConsent()

    def confirm_candidate(match, text):
        # New retries the apply after this exact candidate is explicitly bound.
        # Provider impact consent is independently re-evaluated on that retry.
        consent.reset()
        return "y\n"

    if mode == "run":
        rules.extend([
            Rule(r"Bind this exact candidate and continue with its lifecycle\? \[y/N\]\s*$", callback=confirm_candidate, optional=decision != "run"),
            consent.rule(),
            apply_changes_rule(decision, require_provider_changes=sql),
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
    if mode == "run" and "Lifecycle: VERIFIED" not in (ARTIFACT_DIR / ("new-edit-" + name + ".txt")).read_text():
        raise RuntimeError("New returned without its completed lifecycle receipt")
    requirements = actual.get("requirements") or []
    kinds = {row["requirement"]["kind"] for row in requirements}
    if kinds != ({"database.sql"} if sql else set()):
        raise RuntimeError("New did not persist exactly the selected needs")
    if not actual.get("complete"):
        raise RuntimeError("New did not establish a complete native Footprint")
    return project


def apply_created_application(project, *, environment=None, name=None):
    """Bind the current source and run the normal explicitly consented lifecycle."""
    argv = [BAHA, "app", "apply"]
    env = {**os.environ, "BASEHARBOR_LOGS_ENABLED": "false", **(environment or {})}
    first = subprocess.run(argv, cwd=project, env=env, capture_output=True, text=True, timeout=120)
    transcript = first.stdout + first.stderr
    digest = capture_confirm_hash(transcript)
    if first.returncode == 0 or digest is None:
        raise RuntimeError("app apply did not produce the exact candidate-consent challenge: " + transcript[-2000:])

    consent = CurrentConsent()
    rules = [consent.rule(), apply_changes_rule("run", require_provider_changes=True),
             Rule(r"Is this installation running on a machine where you write code\?.*?Choice \[1\]:\s*$", "1\n", optional=True),
             Rule(r"PostgreSQL host port \[\d+\]:\s*$", "\n", optional=True)]
    label = name or project.name
    run_tty("new-edit-" + label + "-apply", [*argv, "--confirm-candidate", digest], rules,
            cwd=project, env={"BASEHARBOR_LOGS_ENABLED": "false", **(environment or {})},
            timeout=600, no_output_timeout=120)


def provider_choice_response(text, instance):
    """Select only the requested instance offered for the current SQL need."""
    frame = ANSI_ESCAPE.sub("", text).rsplit("What does your application need?", 1)[-1]
    references = re.findall(r"(?m)^(database\.sql/[^\s]+) on Target [^\r\n]+", frame)
    candidate = re.search(r"(?m)^\[[ x]\] " + re.escape(instance) + r" \(postgresql\):[^\r\n]+", frame)
    if len(references) != 1 or candidate is None:
        raise RuntimeError("provider selection requires one current SQL need and its offered instance")
    return "provider " + references[0] + " " + instance + "\n"


def provider_choice_rule(instance):
    return Rule(r"\[[ x]\] " + re.escape(instance) + r" \(postgresql\):[^\r\n]+",
                callback=lambda match, text: provider_choice_response(text, instance))


def zero_needs_no_rules(cancel):
    """Advance to preview, allowing one no-op retry; then return without execution."""
    attempts = 0
    advance = None

    def advance_to_preview(match, text):
        nonlocal attempts
        attempts += 1
        if attempts > 2:
            raise RuntimeError("zero-needs Edit did not advance to its preview after a bounded retry")
        return "enter\n"

    advance = Rule(NEEDS_END, callback=advance_to_preview, repeat=True)

    def decline_preview(match, text):
        advance.repeat = False
        return "no\n"

    return [advance,
            Rule(r"Read-only decision preview \(not execution\)", callback=decline_preview),
            Rule(NEEDS_END, callback=cancel)]


def edit_application(project, operation, *, instance=None, native=True, environment=None):
    """Drive the actual public Edit needs/preview/consequence prompts."""
    before = state_snapshot(project, native)
    consent = CurrentConsent()
    if operation in ("no", "cancel"):
        def cancel(match, text):
            assert_unchanged(before, project, native)
            return "cancel\n"
        if operation == "cancel":
            rules = [Rule(NEEDS_END, callback=cancel)]
        else:
            rules = zero_needs_no_rules(cancel)
    elif operation in ("add", "remove"):
        rules = [edit_picker_rule(operation == "add")]
        if operation == "add" and instance:
            rules.append(provider_choice_rule(instance))
        rules.append(Rule(r"Read-only decision preview \(not execution\)", "yes\n"))
    elif operation == "switch" and instance:
        rules = [provider_choice_rule(instance),
                 Rule(NEEDS_END, "enter\n"),
                 Rule(r"Read-only decision preview \(not execution\)", "yes\n")]
    else:
        raise ValueError("unknown Edit fixture operation")
    rules.append(consent.rule())
    run_tty("new-edit-" + project.name + "-" + operation, [BAHA, "app", "edit"], rules,
            cwd=project, env={"BASEHARBOR_LOGS_ENABLED": "false", **(environment or {})},
            timeout=600,
            # Core bounds a read-only preview refresh at 120s. Let that bounded
            # authority finish before the PTY harness declares the UI idle.
            no_output_timeout=150 if operation == "no" else 90,
            expected_returncodes=(0, 1) if operation in ("no", "cancel") else (0,))
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
