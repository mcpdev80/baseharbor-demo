#!/usr/bin/env python3
"""Qualify default demo from native containers without retaining secret fields."""
import argparse
import json
import os
import re
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--profile", choices=("default", "recovery"), default="default")
parser.add_argument("--wait-required-providers-seconds", type=float, default=0)
keycloak_mode = parser.add_mutually_exclusive_group()
keycloak_mode.add_argument("--snapshot-keycloak-baseline", action="store_true")
keycloak_mode.add_argument("--compare-keycloak-baseline")
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
required = {"postgresql", "openbao", "seaweedfs", "valkey", "loki"}
if args.profile == "default":
    required.add("keycloak")


def collect_native_topology():
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
    unselected_counts = {}
    for item in native:
        config = item.get("Config") or {}
        labels = config.get("Labels") or {}
        project = labels.get("com.docker.compose.project", "")
        service = labels.get("com.docker.compose.service", "")
        # Podman may return the immutable image ID in Config.Image and keep
        # the selected registry/tag in ImageName. Docker generally fills only
        # Config.Image. Check both so a digest-only ID cannot hide a managed
        # provider image from the ownership inventory.
        image_repositories = {
            image.split("@", 1)[0].rsplit("/", 1)[-1].split(":", 1)[0]
            for image in (str(config.get("Image") or ""), str(item.get("ImageName") or ""))
            if image
        }
        running = bool((item.get("State") or {}).get("Running"))
        auxiliary = bool(re.search(r"(?:-admin|-init|-access|-ui)(?:-[1-9][0-9]*)?$|sentinel|etcd", service))
        provider = ""
        if not auxiliary:
            for name, marker in [("postgresql", "postgres:"), ("postgresql", "spilo-"), ("openbao", "openbao:"), ("keycloak", "keycloak:"), ("seaweedfs", "seaweedfs:"), ("valkey", "valkey:"), ("valkey", "baseharbor-valkey:"), ("prometheus", "prometheus:"), ("otel-collector", "opentelemetry-collector"), ("loki", "loki:"), ("tempo", "tempo:"), ("rabbitmq", "rabbitmq:"), ("mongodb", "mongo:")]:
                if any((repository == marker[:-1] if marker.endswith(":") else marker in repository)
                       for repository in image_repositories):
                    provider = name
                    break
        if not project.startswith("bh-" + target + "-"):
            if provider:
                key = (provider, running)
                unselected_counts[key] = unselected_counts.get(key, 0) + 1
            continue
        if provider:
            root = re.sub(r"-(?:member-|node-)?[1-9][0-9]*$", "", service)
            key = (project, provider, root)
            if running:
                groups[key] = groups.get(key, 0) + 1
        volumes = sorted(m["Name"] for m in item.get("Mounts", []) if m.get("Type") == "volume" and m.get("Name"))
        # Public artifacts and failure logs may contain only an allowlisted
        # provider label, never an arbitrary private image repository name.
        rows.append({"project": project, "service": service, "role": provider or "unclassified", "running": running, "volumes": volumes})
    return groups, rows, unselected_counts


deadline = time.monotonic() + max(0, args.wait_required_providers_seconds)
while True:
    groups, rows, unselected_counts = collect_native_topology()
    observed = {provider for _, provider, _ in groups}
    missing = required - observed
    if not missing or time.monotonic() >= deadline:
        break
    time.sleep(min(1, max(0, deadline - time.monotonic())))
if not rows:
    unselected = "; ".join(
        f"unselected {provider} running={int(running)} count={count}"
        for (provider, running), count in sorted(unselected_counts.items())
    )
    raise SystemExit("no selected demo-owned native containers found" + (f"; {unselected}" if unselected else ""))
running_keycloak = sorted(
    f"{row['project']}/{row['service']}"
    for row in rows
    if row["role"] == "keycloak" and row["running"]
)
if args.snapshot_keycloak_baseline:
    Path(args.output).write_text(json.dumps({
        "schema": "baseharbor.demo-keycloak-baseline/v1",
        "services": running_keycloak,
    }, indent=2) + "\n")
    print("Native Keycloak baseline captured")
    raise SystemExit(0)
if args.compare_keycloak_baseline:
    baseline_path = Path(args.compare_keycloak_baseline)
    try:
        baseline = json.loads(baseline_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read Keycloak baseline: {baseline_path}") from exc
    if (
        not isinstance(baseline, dict)
        or baseline.get("schema") != "baseharbor.demo-keycloak-baseline/v1"
        or not isinstance(baseline.get("services"), list)
        or not all(isinstance(service, str) for service in baseline["services"])
    ):
        raise SystemExit("invalid Keycloak baseline schema")
    introduced = sorted(set(running_keycloak) - set(baseline["services"]))
    if introduced:
        raise SystemExit(
            "recovery fixture introduced unrequested Identity/management Core; "
            "new running Keycloak project/service: " + ", ".join(introduced)
        )
if not required <= observed:
    missing = ",".join(sorted(required - observed))
    inventory = "; ".join(
        f"{row['project']}/{row['service']} role={row['role']} running={str(row['running']).lower()}"
        for row in rows
    )
    unselected = "; ".join(
        f"unselected {provider} running={int(running)} count={count}"
        for (provider, running), count in sorted(unselected_counts.items())
    )
    diagnostic = f"; selected containers: {inventory or 'none'}"
    if unselected:
        diagnostic += f"; unselected containers: {unselected}"
    raise SystemExit(f"required native default providers absent: {missing}{diagnostic}")
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
summary = {"selected_profile": args.profile, "schema": "baseharbor.demo-native-topology/v1", "runtime": engine, "ha_requested": False, "ha_active": False, "members": [{"project": project, "provider": provider, "instance": root, "count": count} for (project, provider, root), count in sorted(groups.items())], "services": sorted(rows, key=lambda row: (row["project"], row["service"]))}
Path(args.output).write_text(json.dumps(summary, indent=2) + "\n")
print("Native default demo topology PASS: exactly one physical provider per type across projects; helpers excluded")
