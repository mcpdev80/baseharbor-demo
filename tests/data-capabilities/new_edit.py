#!/usr/bin/env python3
"""Native SQL New/Edit journeys inside the existing heavy data gate.

Provider IDs come from public Footprint and the actual Edit candidate view.
Native probes operate only on containers in Core's read-only destroy inventory
whose exact project labels agree. SQL probe values are fixture-owned UUIDs;
credentials remain inside their containers and never enter receipts.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
import re
import stat
import signal

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "guided"))
from new_edit import (ARTIFACT_DIR, ROOT, cli, edit_application, footprint,
                      footprint_parity, new_application, native_environment)

RUNTIME = os.environ["BASEHARBOR_TEST_RUNTIME"]
OWNER_LABEL = "org.baseharbor.demo.new-edit-owner"


def receipt_path():
    fixture = Path(os.environ["BASEHARBOR_DEMO_FIXTURE"])
    if (fixture.is_symlink() or not fixture.is_dir() or fixture.stat().st_uid != os.getuid()
            or stat.S_IMODE(fixture.stat().st_mode) & 0o077):
        raise RuntimeError("foreign sentinel fixture directory is not owned and private")
    return fixture / "new-edit-foreign.json"


def read_receipt():
    path = receipt_path()
    if not path.exists() and not path.is_symlink():
        return None
    if path.is_symlink():
        raise RuntimeError("foreign sentinel receipt must not be a symlink")
    # O_NOFOLLOW keeps a concurrent symlink replacement from changing which
    # private receipt is read after the presence check.
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "r") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 65536):
            raise RuntimeError("foreign sentinel receipt has unsafe type, owner, permissions or size")
        result = json.loads(source.read(65537))
    if (result.get("version") != "demo-new-edit-foreign/v1" or result.get("runtime") != RUNTIME
            or result.get("target") != os.environ["BASEHARBOR_TARGET"]
            or not re.fullmatch(r"[0-9a-f]{32}", result.get("nonce", ""))
            or not re.fullmatch(r"[0-9a-f]{64}", result.get("container_id", ""))):
        raise RuntimeError("foreign sentinel receipt has an invalid identity")
    return result


def verify_foreign(receipt, *, require_unchanged):
    token = receipt["nonce"][:12]
    project = "foreign-new-edit-" + token
    item = inspect(receipt["container_id"])
    labels = item.get("Config", {}).get("Labels") or {}
    if (item["Id"] != receipt["container_id"] or not receipt.get("created")
            or item.get("Created") != receipt["created"]
            or item.get("Name", "").lstrip("/") != "bh-new-edit-foreign-" + token
            or labels.get(OWNER_LABEL) != receipt["nonce"]
            or labels.get("com.docker.compose.project") != project
            or labels.get("io.podman.compose.project") != project
            or receipt.get("volume_name") != project):
        raise RuntimeError("foreign sentinel native immutable identity changed")
    volume = json.loads(native("volume", "inspect", project))[0]
    if (volume.get("Name") != project or (volume.get("Labels") or {}).get(OWNER_LABEL) != receipt["nonce"]
            or not receipt["volume"].get("CreatedAt") or volume.get("CreatedAt") != receipt["volume"]["CreatedAt"]):
        raise RuntimeError("foreign sentinel volume immutable identity changed")
    if require_unchanged and (item["State"].get("Paused") is not True
            or labels != receipt["labels"] or volume != receipt["volume"]):
        raise RuntimeError("Core teardown changed a foreign paused container or its volume")
    return item


def foreign_finalize(remove=False):
    receipt = read_receipt()
    if receipt is None:
        if not remove and (ARTIFACT_DIR / "new-edit-sql.json").exists():
            raise RuntimeError("SQL journey claimed preservation without its private sentinel identity")
        return
    item = verify_foreign(receipt, require_unchanged=not remove)
    if remove:
        if item["State"].get("Paused"):
            native("unpause", receipt["container_id"])
        native("rm", "-f", receipt["container_id"])
        # Recheck the volume's immutable identity immediately before removal.
        current = json.loads(native("volume", "inspect", receipt["volume_name"]))[0]
        if (current.get("CreatedAt") != receipt["volume"].get("CreatedAt")
                or (current.get("Labels") or {}).get(OWNER_LABEL) != receipt["nonce"]):
            raise RuntimeError("foreign sentinel volume identity changed before owner removal")
        native("volume", "rm", receipt["volume_name"])
        receipt_path().unlink()


def native(*arguments, input=None, timeout=20):
    process = subprocess.Popen([RUNTIME, *arguments], stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                               env=native_environment(RUNTIME))
    try:
        output, _ = process.communicate(input=input, timeout=timeout)
    except subprocess.TimeoutExpired:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        raise RuntimeError("native fixture operation exceeded its deadline") from None
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        raise
    if process.returncode:
        raise RuntimeError(f"native fixture {arguments[0]} failed (exit {process.returncode}); private ownership arguments are withheld")
    return output


def inspect(identifier):
    values = json.loads(native("inspect", identifier))
    if len(values) != 1:
        raise RuntimeError("native resource identity is ambiguous")
    return values[0]


def owned_postgres():
    preview = json.loads(cli(ROOT, "destroy", "--all", "--json"))
    if preview.get("preview") is not True or preview.get("destroyed") is not False:
        raise RuntimeError("ownership query did not return a read-only destroy preview")
    result = {}
    for resource in preview.get("resources", []):
        if resource.get("target") != os.environ["BASEHARBOR_TARGET"] or resource.get("kind") != "container":
            continue
        item = inspect(resource["name"])
        labels = item.get("Config", {}).get("Labels") or {}
        projects = [labels[key] for key in ("com.docker.compose.project", "io.podman.compose.project") if key in labels]
        if not projects or any(project != resource["project"] for project in projects):
            raise RuntimeError("observed container ownership differs from Core's exact project inventory")
        if item.get("Name", "").lstrip("/") != resource["name"].lstrip("/"):
            raise RuntimeError("native name differs from Core's observed inventory")
        image = item.get("Config", {}).get("Image", "")
        if image.split(":")[0].split("/")[-1] == "postgres":
            result[item["Id"]] = item
    return result


def sql_container(container, sql):
    # The production image's PostgreSQL administrator environment stays inside
    # the container. Never inspect or print its values on the runner.
    command = 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql --no-psqlrc -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'
    return native("exec", "-i", container, "sh", "-ec", command, input=sql.encode()).decode().strip()


def volumes(item):
    names = sorted(mount["Name"] for mount in item.get("Mounts", []) if mount.get("Type") == "volume")
    if not names:
        raise RuntimeError("SQL provider has no observed persistent native volume")
    return {name: json.loads(native("volume", "inspect", name))[0] for name in names}


def retained_sql(expected_volumes):
    matches = []
    for identifier, item in owned_postgres().items():
        mounted = {mount["Name"] for mount in item.get("Mounts", []) if mount.get("Type") == "volume"}
        if mounted == set(expected_volumes):
            if volumes(item) != expected_volumes:
                raise RuntimeError("retained SQL volume metadata changed")
            matches.append(identifier)
    if len(matches) != 1:
        raise RuntimeError("retained SQL provider has no unique observed native realization")
    return matches[0]


def selected_sql(result):
    rows = [row for row in result.get("requirements") or [] if row["requirement"]["kind"] == "database.sql"]
    if len(rows) != 1 or rows[0].get("binding") != "bound" or rows[0].get("state") != "running" or not rows[0].get("instance_id"):
        raise RuntimeError("Footprint does not prove exactly one running SQL binding")
    return rows[0]["instance_id"]


def marker(container, value, create=False):
    if create:
        sql_container(container, "CREATE TABLE IF NOT EXISTS demo_new_edit_retention (value TEXT PRIMARY KEY);\n"
                      + "INSERT INTO demo_new_edit_retention VALUES ('" + value + "');\n")
    if sql_container(container, "SELECT value FROM demo_new_edit_retention WHERE value='" + value + "';\n") != value:
        raise RuntimeError("native SQL marker was not preserved")


def sibling_sql():
    base, ca, resolve = sys.argv[1:]
    result = json.loads(subprocess.check_output(["curl", "-fsS", "--cacert", ca, "--resolve", resolve,
                                                "-X", "POST", base + "/api/sql"], timeout=30))
    if not isinstance(result.get("id"), int) or not isinstance(result.get("records"), int):
        raise RuntimeError("sibling SQL HTTP oracle did not return its real persisted record")
    return result


def main():
    sibling_before = sibling_sql()
    sibling_footprint = footprint_parity(ROOT)
    shared_id = selected_sql(sibling_footprint)
    shared_facts = [row for row in sibling_footprint.get("existing", []) if row["instance_id"] == shared_id]
    if len(shared_facts) != 1 or shared_facts[0].get("shared") is not True:
        raise RuntimeError("existing data gate did not establish an actual compatible shared SQL provider")
    previous = owned_postgres()
    if len(previous) != 1:
        raise RuntimeError("bounded single-provider SQL fixture requires exactly one existing native PostgreSQL provider")
    shared_container = next(iter(previous))
    shared_volumes = volumes(previous[shared_container])
    shared_marker = uuid.uuid4().hex
    marker(shared_container, shared_marker, create=True)

    # The sentinel has intentionally foreign ownership and an otherwise
    # plausible name. Core operations must preserve its actual identity/state.
    nonce = uuid.uuid4().hex
    token = nonce[:12]
    foreign_project = "foreign-new-edit-" + token
    private_receipt = receipt_path()
    if private_receipt.exists() or private_receipt.is_symlink():
        raise RuntimeError("foreign sentinel receipt already exists; refusing replacement")
    foreign_volume = native("volume", "create", "--label", OWNER_LABEL + "=" + nonce,
                            foreign_project).decode().strip()
    foreign = None
    handed_off = False
    try:
        foreign = native("run", "-d", "--name", "bh-new-edit-foreign-" + token,
            "--label", "com.docker.compose.project=" + foreign_project,
            "--label", "io.podman.compose.project=" + foreign_project,
            "--label", OWNER_LABEL + "=" + nonce,
            "--volume", foreign_volume + ":/fixture", "alpine:3.22", "sleep", "infinity",
            timeout=90).decode().strip()
        native("pause", foreign)
        foreign_before = inspect(foreign)
        foreign_volume_before = json.loads(native("volume", "inspect", foreign_volume))
        if foreign_before["State"].get("Paused") is not True:
            raise RuntimeError("foreign sentinel did not enter the required paused state")
        receipt = {"version": "demo-new-edit-foreign/v1", "runtime": RUNTIME,
            "target": os.environ["BASEHARBOR_TARGET"], "nonce": nonce,
            "container_id": foreign_before["Id"], "created": foreign_before.get("Created"),
            "labels": foreign_before["Config"]["Labels"], "volume_name": foreign_volume,
            "volume": foreign_volume_before[0]}
        with os.fdopen(os.open(private_receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
            json.dump(receipt, output)
            output.write("\n")
        handed_off = True  # acceptance EXIT verifies then separately removes it
        verify_foreign(receipt, require_unchanged=True)

        parent = ROOT / ".new-edit-fixtures"
        parent.mkdir(exist_ok=True)
        project = new_application(parent, "new-sql", sql=True,
            environment={"BASEHARBOR_PROVIDER_POSTGRESQL_SCOPE": "application"})
        dedicated_id = selected_sql(footprint_parity(project))
        if dedicated_id == shared_id:
            raise RuntimeError("New did not create the requested separate application SQL provider")
        created = owned_postgres()
        candidates = set(created) - set(previous)
        if len(candidates) != 1:
            raise RuntimeError("New SQL provider has no unique real native PostgreSQL realization")
        dedicated_container = candidates.pop()
        dedicated_volumes = volumes(created[dedicated_container])
        own_marker = uuid.uuid4().hex
        marker(dedicated_container, own_marker, create=True)
        edit_application(project, "cancel")
        edit_application(project, "no")

        removed = edit_application(project, "remove")
        if removed.get("requirements"):
            raise RuntimeError("Edit remove did not persist zero managed needs")
        added = edit_application(project, "add", environment={"BASEHARBOR_PROVIDER_POSTGRESQL_SCOPE": "application"})
        if selected_sql(added) != dedicated_id:
            raise RuntimeError("Edit re-add failed to reuse the retained actual SQL provider")
        dedicated_container = retained_sql(dedicated_volumes)
        marker(dedicated_container, own_marker)

        switched = edit_application(project, "switch", instance=shared_id)
        if selected_sql(switched) != shared_id:
            raise RuntimeError("Edit did not bind the genuine selected shared SQL provider")
        marker(shared_container, shared_marker)
        returned = edit_application(project, "switch", instance=dedicated_id)
        if selected_sql(returned) != dedicated_id:
            raise RuntimeError("Edit did not return to its retained application SQL provider")
        dedicated_container = retained_sql(dedicated_volumes)
        marker(dedicated_container, own_marker)
        footprint_parity(project)

        if volumes(inspect(shared_container)) != shared_volumes:
            raise RuntimeError("shared sibling SQL volume identity changed")
        marker(shared_container, shared_marker)
        if selected_sql(footprint_parity(ROOT)) != shared_id:
            raise RuntimeError("Edit changed the sibling application's provider binding")
        sibling_after = sibling_sql()
        if sibling_after["id"] <= sibling_before["id"] or sibling_after["records"] <= sibling_before["records"]:
            raise RuntimeError("sibling application SQL data was not retained across New/Edit")
        foreign_after = inspect(foreign)
        if (foreign_after["Id"] != foreign_before["Id"] or foreign_after["State"].get("Paused") is not True
                or foreign_after["Config"].get("Labels") != foreign_before["Config"].get("Labels")
                or json.loads(native("volume", "inspect", foreign_volume)) != foreign_volume_before):
            raise RuntimeError("New/Edit changed a foreign paused resource or its volume")
        (ARTIFACT_DIR / "new-edit-sql.json").write_text(json.dumps({
            "journey": "real-cli-native-sql-new-edit", "target": os.environ["BASEHARBOR_TARGET"],
            "application_id": returned["application_id"], "application_provider": dedicated_id,
            "shared_provider": shared_id, "add_remove_switch": True, "no_cancel_unchanged": True,
            "own_sql_marker_preserved": True, "shared_sql_marker_preserved": True,
            "sibling_sql_preserved": True, "foreign_paused_container_and_volume_preserved": True,
            "cli_json_mcp_footprint_parity": True, "native_runtime_qualified": True,
        }, indent=2) + "\n")
    finally:
        # A completed receipt belongs to the acceptance EXIT proof. If creation
        # failed before handoff, remove only our exact newly created resources.
        if not handed_off:
            if foreign:
                if inspect(foreign)["State"].get("Paused"):
                    native("unpause", foreign)
                native("rm", "-f", foreign)
            native("volume", "rm", foreign_volume)


if __name__ == "__main__":
    def interrupted(signum, frame):
        # Let native() reap its separate process group before an outer
        # acceptance deadline or cancellation exits this bounded helper.
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    if sys.argv[1:] == ["--foreign-check"]:
        foreign_finalize()
    elif sys.argv[1:] == ["--foreign-remove"]:
        foreign_finalize(remove=True)
    else:
        main()
