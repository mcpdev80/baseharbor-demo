import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch


class NativeTopologyQualificationTests(unittest.TestCase):
    def fixture(self):
        return [self.container(name, image) for name, image in [
            ("postgres-member-1", "docker.io/library/postgres:18"),
            ("openbao-member-1", "docker.io/openbao/openbao:2"),
            ("keycloak-1", "quay.io/keycloak/keycloak:26"),
            ("seaweedfs-node-1", "docker.io/chrislusf/seaweedfs:4"),
            ("valkey", "docker.io/valkey/valkey:9"),
            ("loki", "docker.io/grafana/loki:3"),
        ]]

    def container(self, service, image, project="bh-test-core-shared"):
        return {"Config": {"Image": image, "Env": ["PRIVATE_VALUE=must-not-persist"], "Labels": {"com.docker.compose.project": project, "com.docker.compose.service": service}}, "State": {"Running": True}}

    def invoke(self, containers, output):
        with patch.dict(os.environ, {"CONTAINER_CLI": "podman", "BASEHARBOR_TARGET": "test", "XDG_CONFIG_HOME": "/isolated/baseharbor/config", "XDG_DATA_HOME": "/isolated/baseharbor/data"}), patch.object(sys, "argv", ["native-default-topology.py", "--output", str(output)]), patch("subprocess.check_output", side_effect=["owned-id\n", json.dumps(containers)]) as native:
            runpy.run_path(str(Path(__file__).with_name("native-default-topology.py")), run_name="__main__")
            for call in native.call_args_list:
                self.assertNotIn("XDG_CONFIG_HOME", call.kwargs["env"])
                self.assertNotIn("XDG_DATA_HOME", call.kwargs["env"])

    def test_auxiliary_and_foreign_resources_never_become_replicas_or_leak_secrets(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "qualified.json"
            containers = self.fixture() + [self.container("postgres-admin", "postgres:18"), self.container("postgres-init", "postgres:18"), self.container("seaweedfs-node-2", "chrislusf/seaweedfs:4", "foreign-project")]
            self.invoke(containers, path)
            result = path.read_text()
            self.assertNotIn("PRIVATE_VALUE", result)
            self.assertNotIn("must-not-persist", result)
            self.assertNotIn("foreign-project", result)
            self.assertTrue(all(m["count"] == 1 for m in json.loads(result)["members"]))

    def test_digest_pinned_native_provider_images_are_classified(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "qualified.json"
            containers = self.fixture()
            for item in containers:
                repository = item["Config"]["Image"].rsplit(":", 1)[0]
                item["Config"]["Image"] = repository + "@sha256:" + "b" * 64
            self.invoke(containers, path)
            self.assertEqual({m["provider"] for m in json.loads(path.read_text())["members"]},
                             {"postgresql", "openbao", "keycloak", "seaweedfs", "valkey", "loki"})

    def test_foreign_digest_pinned_keycloak_cannot_satisfy_required_provider(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "qualified.json"
            containers = [c for c in self.fixture() if c["Config"]["Labels"]["com.docker.compose.service"] != "keycloak-1"]
            containers.append(self.container("keycloak-1", "quay.io/keycloak/keycloak@sha256:" + "b" * 64, "foreign-project"))
            with self.assertRaisesRegex(SystemExit, "required native default providers absent: keycloak"):
                self.invoke(containers, path)
            self.assertFalse(path.exists())

    def test_native_extra_data_member_blocks_default_acceptance(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "qualified.json"
            with self.assertRaisesRegex(SystemExit, "unexpected implicit default HA"):
                self.invoke(self.fixture() + [self.container("seaweedfs-node-2", "chrislusf/seaweedfs:4")], path)
            self.assertFalse(path.exists())

    def test_separate_shared_keycloak_database_is_not_mistaken_for_a_single_topology(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "qualified.json"
            with self.assertRaisesRegex(SystemExit, "duplicate shared default provider"):
                self.invoke(self.fixture() + [self.container("keycloak-db", "postgres:18", "bh-test-identity-shared")], path)
            self.assertFalse(path.exists())

    def test_separate_single_shared_provider_on_another_project_blocks_acceptance(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "qualified.json"
            with self.assertRaisesRegex(SystemExit, "duplicate shared default provider"):
                self.invoke(self.fixture() + [self.container("shared-postgres-dev", "postgres:18", "bh-test-shared")], path)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
