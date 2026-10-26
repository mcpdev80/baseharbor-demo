#!/usr/bin/env python3
"""Fixture identity, permission and SQL workload transition regressions."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys
import copy

os.environ.setdefault("BASEHARBOR_TEST_RUNTIME", "docker")
spec = importlib.util.spec_from_file_location("demo_native_new_edit", Path(__file__).with_name("new_edit.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
import new_edit as guided


class SentinelIdentityTest(unittest.TestCase):
    def test_canonical_postgres_layout_excludes_same_image_admin_and_init(self):
        # Layouts from Core internal/runtime/assets/compose-single.yaml,
        # application/runtime_postgres.go and shared_postgres_single.go.
        # These are role/metadata regressions, not native SQL success mocks.
        server = {"Config": {"Image": "docker.io/library/postgres:18-alpine",
            "Labels": {"com.docker.compose.service": "postgres-member-1"},
            "Env": ["POSTGRES_USER=fixture", "POSTGRES_PASSWORD=fixture", "POSTGRES_DB=fixture"]},
            "State": {"Running": True}, "Mounts": [{"Type": "volume", "Name": "owned-postgres-data-1",
                "Destination": "/var/lib/postgresql", "RW": True}]}
        for service in ["postgres-member-1", "postgres", "shared-postgres-dev"]:
            with self.subTest(server=service):
                actual = copy.deepcopy(server)
                actual["Config"]["Labels"] = {"com.docker.compose.service": service, "io.podman.compose.service": service}
                self.assertTrue(fixture.is_postgres_server(actual))
        for service, environment in [("postgres-admin", ["PGPASSWORD=fixture"]),
                ("postgres-init", ["POSTGRES_USER=fixture", "POSTGRES_DB=postgres", "PGPASSWORD=fixture"])]:
            with self.subTest(helper=service):
                actual = copy.deepcopy(server)
                actual["Config"]["Labels"]["com.docker.compose.service"] = service
                actual["Config"]["Env"] = environment
                actual["Mounts"] = [{"Type": "bind", "Destination": "/run/baseharbor/postgres-ca/ca.pem", "RW": False}]
                self.assertFalse(fixture.is_postgres_server(actual))
                # Same image and even a misleading data mount cannot promote a
                # canonical admin/init service into the real SQL server role.
                actual["Mounts"] = server["Mounts"]
                actual["Config"]["Env"] = server["Config"]["Env"]
                self.assertFalse(fixture.is_postgres_server(actual))
        for mutation in ["missing-data", "tmpfs-data", "read-only-data", "conflicting-service", "missing-password"]:
            with self.subTest(invalid=mutation):
                actual = copy.deepcopy(server)
                if mutation == "missing-data":
                    actual["Mounts"] = []
                elif mutation == "tmpfs-data":
                    actual["Mounts"][0]["Type"] = "tmpfs"
                elif mutation == "read-only-data":
                    actual["Mounts"][0]["RW"] = False
                elif mutation == "conflicting-service":
                    actual["Config"]["Labels"]["io.podman.compose.service"] = "postgres-admin"
                else:
                    actual["Config"]["Env"] = ["POSTGRES_USER=fixture", "POSTGRES_DB=fixture"]
                self.assertFalse(fixture.is_postgres_server(actual))

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.env = patch.dict(os.environ, {"BASEHARBOR_DEMO_FIXTURE": self.directory.name, "BASEHARBOR_TARGET": "fixture"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.nonce = "a" * 32
        self.identifier = "b" * 64
        project = "foreign-new-edit-" + self.nonce[:12]
        labels = {fixture.OWNER_LABEL: self.nonce, "com.docker.compose.project": project, "io.podman.compose.project": project}
        self.item = {"Id": self.identifier, "Created": "2026-10-21T00:00:00Z",
            "Name": "/bh-new-edit-foreign-" + self.nonce[:12], "State": {"Paused": True}, "Config": {"Labels": labels}}
        self.volume = {"Name": project, "CreatedAt": "2026-10-21T00:00:00Z", "Labels": {fixture.OWNER_LABEL: self.nonce}}
        self.receipt = {"version": "demo-new-edit-foreign/v1", "runtime": fixture.RUNTIME, "target": "fixture",
            "nonce": self.nonce, "container_id": self.identifier, "created": self.item["Created"],
            "labels": labels, "volume_name": project, "volume": self.volume}
        self.path = Path(self.directory.name) / "new-edit-foreign.json"
        self.calls = []

    def write_receipt(self):
        self.path.write_text(json.dumps(self.receipt))
        self.path.chmod(0o600)

    def native(self, *arguments, **kwargs):
        self.calls.append(arguments)
        if arguments[0] == "inspect":
            self.assertEqual(arguments[1], self.identifier)
            return json.dumps([self.item]).encode()
        if arguments[:2] == ("volume", "inspect"):
            self.assertEqual(arguments[2], self.volume["Name"])
            return json.dumps([self.volume]).encode()
        return b""

    def test_missing_receipt_does_not_invoke_runtime(self):
        with patch.object(fixture, "native", side_effect=self.native):
            fixture.foreign_finalize()
            fixture.foreign_finalize(remove=True)
        self.assertEqual(self.calls, [])

    def test_public_success_without_private_identity_blocks_proof(self):
        (Path(self.directory.name) / "new-edit-sql.json").write_text("{}")
        with patch.object(fixture, "ARTIFACT_DIR", Path(self.directory.name)), patch.object(fixture, "native", side_effect=self.native):
            with self.assertRaises(RuntimeError):
                fixture.foreign_finalize()
            fixture.foreign_finalize(remove=True)
        self.assertEqual(self.calls, [])

    def test_pause_failure_blocks_proof_but_exact_owner_can_remove(self):
        self.write_receipt()
        self.item["State"]["Paused"] = False
        with patch.object(fixture, "native", side_effect=self.native):
            with self.assertRaises(RuntimeError):
                fixture.foreign_finalize()
            fixture.foreign_finalize(remove=True)
        self.assertIn(("rm", "-f", self.identifier), self.calls)
        self.assertIn(("volume", "rm", self.volume["Name"]), self.calls)
        self.assertFalse(self.path.exists())

    def test_replaced_native_identity_never_removes_resources(self):
        self.write_receipt()
        self.item["Created"] = "replaced"
        with patch.object(fixture, "native", side_effect=self.native):
            with self.assertRaises(RuntimeError):
                fixture.foreign_finalize(remove=True)
        self.assertEqual(self.calls, [("inspect", self.identifier)])

    def test_world_readable_or_symlink_receipt_is_rejected(self):
        self.write_receipt()
        self.path.chmod(0o644)
        with self.assertRaises(RuntimeError):
            fixture.read_receipt()
        self.path.unlink()
        self.path.symlink_to(Path(self.directory.name) / "missing")
        with self.assertRaises(RuntimeError):
            fixture.read_receipt()

    def test_actual_child_engine_context_and_metadata_only_snapshot(self):
        root = Path(self.directory.name)
        audit = root / "engine-calls.jsonl"
        program = "#!" + sys.executable + "\n" + '''import json, os, sys
data = {key: os.environ.get(key) for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR"]}
with open(os.environ["DEMO_ENV_AUDIT"], "a") as output:
    output.write(json.dumps({"arguments": sys.argv[1:], "environment": data}) + "\\n")
if sys.argv[1:] == ["env"]:
    print(json.dumps(data))
'''
        with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(root / "config"),
                "XDG_DATA_HOME": str(root / "data"), "XDG_RUNTIME_DIR": "/run/user/fixture",
                "DEMO_ENV_AUDIT": str(audit)}):
            for runtime in ["podman", "docker"]:
                executable = root / runtime
                executable.write_text(program)
                executable.chmod(0o700)
                with patch.object(fixture, "RUNTIME", str(executable)):
                    actual = json.loads(fixture.native("env"))
                expected_config = None if runtime == "podman" else str(root / "config")
                expected_data = None if runtime == "podman" else str(root / "data")
                self.assertEqual(actual, {"XDG_CONFIG_HOME": expected_config,
                    "XDG_DATA_HOME": expected_data, "XDG_RUNTIME_DIR": "/run/user/fixture"})
                audit.unlink()
                with patch.dict(os.environ, {"BASEHARBOR_TEST_RUNTIME": str(executable)}), patch.object(guided, "ROOT", root):
                    guided.state_snapshot(root)
                calls = [json.loads(line) for line in audit.read_text().splitlines()]
                self.assertEqual([call["arguments"] for call in calls], [
                    ["ps", "-a", "--no-trunc", "--format", "{{.ID}}\t{{.Names}}\t{{.State}}"],
                    ["volume", "ls", "-q"], ["network", "ls", "-q"]])
                self.assertTrue(all(call["environment"] == actual for call in calls))
                # Public baha commands must still use the isolated fixture state.
                with patch.object(guided, "BAHA", str(executable)):
                    baha_environment = json.loads(guided.cli(root, "env"))
                self.assertEqual(baha_environment["XDG_CONFIG_HOME"], str(root / "config"))
                self.assertEqual(baha_environment["XDG_DATA_HOME"], str(root / "data"))
                self.assertEqual(os.environ["XDG_CONFIG_HOME"], str(root / "config"))



class SQLWorkloadTransitionTest(unittest.TestCase):
    def test_removal_adapts_usage_and_add_restores_exact_strict_source(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            path = project / "main.go"
            original = b"package main\n// keep application code\n" + fixture.SQL_STARTUP + b"// keep HTTP readiness\n"
            path.write_bytes(original)
            path.chmod(0o640)
            saved, staged = fixture.prepare_sql_removal_workload(project)
            self.assertEqual(saved, original)
            self.assertEqual(path.read_bytes(), staged)
            self.assertIn(b'if os.Getenv("DATABASE_URL") != "" {', staged)
            self.assertIn(fixture.SQL_STARTUP, staged)
            self.assertIn(b'keep HTTP readiness', staged)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            fixture.restore_sql_workload(project, saved, staged)
            self.assertEqual(path.read_bytes(), original)

    def test_unknown_or_duplicated_startup_is_not_changed(self):
        for source in (b"unknown application source", fixture.SQL_STARTUP * 2):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                project = Path(directory)
                path = project / "main.go"
                path.write_bytes(source)
                with self.assertRaises(RuntimeError):
                    fixture.prepare_sql_removal_workload(project)
                self.assertEqual(path.read_bytes(), source)

    def test_restore_preserves_concurrent_application_edit_and_link(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            path = project / "main.go"
            path.write_bytes(fixture.SQL_STARTUP)
            original, staged = fixture.prepare_sql_removal_workload(project)
            concurrent = staged + b"// developer changed source\n"
            path.write_bytes(concurrent)
            with self.assertRaises(RuntimeError):
                fixture.restore_sql_workload(project, original, staged)
            self.assertEqual(path.read_bytes(), concurrent)
            external = project / "external.go"
            external.write_bytes(staged)
            path.unlink()
            path.symlink_to(external)
            for action in (lambda: fixture.prepare_sql_removal_workload(project),
                           lambda: fixture.restore_sql_workload(project, original, staged)):
                with self.assertRaises(RuntimeError):
                    action()
            self.assertEqual(external.read_bytes(), staged)

class RetainedSQLIdentityRegressionTest(unittest.TestCase):
    # Demo126: retained SQL comparisons must use only (Name, sorted Labels,
    # CreatedAt); runtime-derived Namespace/Options drift is not a change.
    CREATED = "2026-10-22T00:00:00Z"
    LABELS = {"app": "sql", "env": "fixture"}

    def volume(self, name, *, labels=None, created=CREATED, **extra):
        result = {"Name": name, "Driver": "local", "CreatedAt": created,
                  "Labels": dict(self.LABELS if labels is None else labels)}
        result.update(extra)
        return result

    def container(self, identifier, names):
        return {identifier: {"Id": identifier, "State": {"Running": True},
                "Mounts": [{"Type": "volume", "Name": name, "Destination": "/var/lib/postgresql", "RW": True} for name in names]}}

    def drive(self, expected, observed, containers):
        def native(*arguments, **kwargs):
            self.assertEqual(arguments[:2], ("volume", "inspect"))
            return json.dumps([copy.deepcopy(observed[arguments[2]])]).encode()
        with patch.object(fixture, "owned_postgres", return_value=containers), patch.object(fixture, "native", side_effect=native):
            return fixture.retained_sql(expected)

    def test_namespace_and_options_drift_preserves_retained_sql(self):
        expected = {"bh-pg-data": self.volume("bh-pg-data", Namespace="default", Options={"device": "/old/path"})}
        observed = {"bh-pg-data": self.volume("bh-pg-data", Namespace="rootless", Options={"device": "/new/path", "type": "bind"})}
        self.assertEqual(self.drive(expected, observed, self.container("c" * 64, ["bh-pg-data"])), "c" * 64)

    def test_reordered_labels_preserve_retained_sql(self):
        expected = {"bh-pg-data": self.volume("bh-pg-data", labels={"app": "sql", "env": "fixture"})}
        observed = {"bh-pg-data": self.volume("bh-pg-data", labels={"env": "fixture", "app": "sql"})}
        self.assertEqual(fixture._volume_identity(expected["bh-pg-data"]), fixture._volume_identity(observed["bh-pg-data"]))
        self.assertEqual(self.drive(expected, observed, self.container("c" * 64, ["bh-pg-data"])), "c" * 64)

    def test_each_changed_identity_field_raises(self):
        for mutation in ("name", "labels", "created"):
            with self.subTest(mutation=mutation):
                expected = {"bh-pg-data": self.volume("bh-pg-data")}
                observed = {"bh-pg-data": self.volume("bh-pg-data")}
                if mutation == "name":
                    observed["bh-pg-data"]["Name"] = "bh-pg-data-replacement"
                elif mutation == "labels":
                    observed["bh-pg-data"]["Labels"]["app"] = "changed"
                else:
                    observed["bh-pg-data"]["CreatedAt"] = "2026-10-23T00:00:00Z"
                with self.assertRaisesRegex(RuntimeError, "retained SQL volume metadata changed"):
                    self.drive(expected, observed, self.container("c" * 64, ["bh-pg-data"]))

    def test_distinct_names_with_equal_labels_and_time_are_distinguishable(self):
        expected = {"vol-a": self.volume("vol-a"), "vol-b": self.volume("vol-b")}
        self.assertEqual(len({fixture._volume_identity(v) for v in expected.values()}), 2)
        self.assertEqual(self.drive(expected, copy.deepcopy(expected), self.container("c" * 64, ["vol-a", "vol-b"])), "c" * 64)
        # A replaced volume collapsing both identities into one must be rejected
        # even though Labels and CreatedAt alone were always identical.
        collapsed = {"vol-a": self.volume("vol-a"), "vol-b": self.volume("vol-a")}
        with self.assertRaisesRegex(RuntimeError, "retained SQL volume metadata changed"):
            self.drive(expected, collapsed, self.container("c" * 64, ["vol-a", "vol-b"]))

    def test_duplicate_matching_containers_raise_uniqueness_error(self):
        expected = {"bh-pg-data": self.volume("bh-pg-data")}
        containers = self.container("c" * 64, ["bh-pg-data"])
        containers.update(self.container("d" * 64, ["bh-pg-data"]))
        with self.assertRaisesRegex(RuntimeError, "retained SQL provider has no unique observed native realization"):
            self.drive(expected, copy.deepcopy(expected), containers)

if __name__ == "__main__":
    unittest.main()
