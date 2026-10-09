#!/usr/bin/env python3
"""Qualify default demo from native containers without retaining secret fields."""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
args = parser.parse_args()
engine = os.environ["CONTAINER_CLI"]
target = os.environ["BASEHARBOR_TARGET"].replace(".", "-")
if engine not in {"docker", "podman"}:
    raise SystemExit("native default topology requires Docker or Podman")
native_environment = dict(os.environ)
if engine == "podman":
    # Match Core's native Podman command environment. The demo XDG paths are
    # BaseHarbor state isolation, not a separate Podman container store.
    native_environment.pop("XDG_CONFIG_HOME", None)
    native_environment.pop("XDG_DATA_HOME", None)
# Enumerate native IDs first. Podman's label-presence filter differs between
# versions; ownership is checked against inspect labels below on both engines.
ids = subprocess.check_output([engine, "ps", "-a", "--format", "{{.ID}}"], text=True, env=native_environment).split()
if not ids:
    raise SystemExit("native inventory is empty")
# Inspect output stays in memory: credentials/environment/bind paths are never
# printed, written or copied into the public qualification artifact.
native = json.loads(subprocess.check_output([engine, "inspect", *ids], text=True, env=native_environment))
groups = {}
rows = []
for item in native:
    config = item.get("Config") or {}
    labels = config.get("Labels") or {}
    project = labels.get("com.docker.compose.project", "")
    service = labels.get("com.docker.compose.service", "")
    if not project.startswith("bh-" + target + "-"):
        continue
    image = str(config.get("Image") or item.get("ImageName") or "")
    running = bool((item.get("State") or {}).get("Running"))
    auxiliary = bool(re.search(r"(?:-admin|-init|-access|-ui)$|sentinel|etcd", service))
    provider = ""
    if not auxiliary:
        for name, marker in [("postgresql", "postgres:"), ("postgresql", "spilo-"), ("openbao", "openbao:"), ("keycloak", "keycloak:"), ("seaweedfs", "seaweedfs:"), ("valkey", "valkey:"), ("prometheus", "prometheus:"), ("otel-collector", "opentelemetry-collector"), ("loki", "loki:"), ("tempo", "tempo:"), ("rabbitmq", "rabbitmq:"), ("mongodb", "mongo:")]:
            if marker in image:
                provider = name
                break
    if provider:
        root = re.sub(r"-(?:member-|node-)?[1-9][0-9]*$", "", service)
        key = (project, provider, root)
        if running:
            groups[key] = groups.get(key, 0) + 1
    volumes = sorted(m["Name"] for m in item.get("Mounts", []) if m.get("Type") == "volume" and m.get("Name"))
    rows.append({"project": project, "service": service, "role": provider or "auxiliary", "running": running, "volumes": volumes})
if not rows:
    raise SystemExit("no selected demo-owned native containers found")
required = {"postgresql", "openbao", "keycloak", "seaweedfs", "valkey", "loki"}
observed = {provider for _, provider, _ in groups}
if not required <= observed:
    raise SystemExit("required native default providers absent: " + ",".join(sorted(required - observed)))
violations = [f"{project}/{provider}/{root}: {count} members" for (project, provider, root), count in groups.items() if count != 1]
if violations:
    raise SystemExit("unexpected implicit default HA: " + "; ".join(violations))
physical_members = {}
for (_, provider, _), count in groups.items():
    physical_members[provider] = physical_members.get(provider, 0) + count
duplicates = [f"{provider}: {count} physical members across projects" for provider, count in physical_members.items() if count != 1]
if duplicates:
    raise SystemExit("duplicate shared default provider: " + "; ".join(duplicates))
if any(row["service"] == "keycloak-db" or row["service"].startswith("keycloak-db-member-") for row in rows):
    raise SystemExit("shared Keycloak must consume Core PostgreSQL, not own a SQL server")
summary = {"schema": "baseharbor.demo-native-topology/v1", "runtime": engine, "ha_requested": False, "ha_active": False, "members": [{"project": project, "provider": provider, "instance": root, "count": count} for (project, provider, root), count in sorted(groups.items())], "services": sorted(rows, key=lambda row: (row["project"], row["service"]))}
Path(args.output).write_text(json.dumps(summary, indent=2) + "\n")
print("Native default demo topology PASS: exactly one physical provider per type across projects; helpers excluded")
