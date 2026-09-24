<p align="center">
  <img src="https://raw.githubusercontent.com/mcpdev80/baseharbor/main/docs/brand/github_banner.png" alt="BaseHarbor" width="100%">
</p>

<h1 align="center">BaseHarbor Demo</h1>
<p align="center"><strong>A normal Compose application adopted and operated by BaseHarbor.</strong></p>

This repository starts as an ordinary application repository: no committed `baseharbor.yaml`, no prepared BaseHarbor state and no provider-specific application contract.

## Try it

Requirements: Linux, Docker or Podman, Git, and `baha` in `PATH`.

From a pristine checkout:

```bash
baha app inspect .
baha app init
baha up
```

That's the normal developer path.

- `inspect` shows what BaseHarbor detects without changing the repository.
- `init` turns the detected application intent into `baseharbor.yaml`.
- `up` converges the managed services, secrets, runtime bindings and application workload.

On the first run BaseHarbor can ask for required setup such as the OpenBao recovery location and application-owned secrets. After that, the application should be ready.

## Contexts and deployment targets

BaseHarbor is designed to manage more than one deployment target from the same installed CLI.

A deployment is identified by three independent dimensions:

```text
context + application + environment
```

For example, the same application may exist at the same time as:

```text
local    / baseharbor-demo / dev
k3s      / baseharbor-demo / dev
k8s-prod / mailflow        / prod
```

The repository continues to describe portable application intent. The selected BaseHarbor **context** describes where BaseHarbor operates: runtime provider, runtime access reference and target scope. The **environment** remains application/deployment policy and is not inferred from the runtime target.

This separation is intentional so local Docker/Podman operation and later Kubernetes/OpenShift targets use the same BaseHarbor model.

The active context is intended to be shell-local, similar to a Python virtual environment, so multiple terminals can safely target different contexts at the same time. Optional prompt integration can keep the target visible before a command is entered, for example:

```text
[k3s] ~/projects/baseharbor-demo $
[k8s-prod PROD] ~/projects/mailflow $
```

Prompt presentation is configurable: compact or detailed, text-only or color-assisted, before/after the path (and right-prompt where supported). Production must remain recognizable without relying on color alone.

The concrete v0.4.15 context/deployment-registry implementation is tracked in BaseHarbor issue #408. Kubernetes/OpenShift runtime implementations remain later work; the point of the v0.4.15 foundation is that they can be added without changing the portable application contract.

## Check the application

```bash
baha status
baha doctor
```

`status` shows the current application state. `doctor` verifies the application boundary and reports actionable problems.

The demo UI exercises real integrations for:

- SQL
- cache
- S3-compatible object storage
- secrets
- metrics
- traces
- logs
- BaseHarbor Runtime Resources
- cross-application connectivity

## TLS and trust bindings

BaseHarbor keeps transport configuration and certificate material separate.

The workload receives URLs and file paths through environment variables, while certificate and trust material is mounted read-only as files inside the container. PEM data is not embedded in `.env` values.

The demo consumes the same runtime contract a normal application receives:

```text
DATABASE_URL
DATABASE_CA_FILE

REDIS_URL / VALKEY_URL
REDIS_CA_FILE / VALKEY_CA_FILE

S3_ENDPOINT / AWS_ENDPOINT_URL
AWS_CA_BUNDLE

OTEL_EXPORTER_OTLP_ENDPOINT
OTEL_EXPORTER_OTLP_CERTIFICATE

TLS_CERT_FILE
TLS_KEY_FILE

BASEHARBOR_RUNTIME_CA_FILE
BASEHARBOR_RUNTIME_CLIENT_CERT_FILE
BASEHARBOR_RUNTIME_CLIENT_KEY_FILE
```

For example, `DATABASE_CA_FILE=/run/baseharbor/.../ca.pem` is only a path reference. BaseHarbor mounts the referenced CA into the workload container read-only. This keeps the application contract portable and avoids multiline certificate data or private keys in environment files.

## Backup and restore

Interactive backup:

```bash
baha app backup
```

Restore the created archive:

```bash
baha app restore ./<backup>.bhbackup
```

BaseHarbor encrypts the recovery unit, verifies it before restore and only reports success after the restored application is healthy again.

> Current recovery units cover managed SQL state and the application-owned secret scope. Managed S3 contents are not yet part of the recovery unit, so BaseHarbor intentionally fails closed when managed S3 resources are declared.

## Stop or remove it

Stop the application workload:

```bash
baha app down
```

Bring it back:

```bash
baha up
```

Remove the managed application resources:

```bash
baha app destroy --yes
```

The repository-owned Compose files stay untouched.

## What this demo proves

BaseHarbor adopts an existing application without rewriting its Compose model or leaking provider details into the application contract.

The same application intent is consumed through standard interfaces:

- OCI workloads
- Compose today
- Podman Quadlet as an equivalent local runtime path
- SQL-compatible database access
- Redis/Valkey-compatible cache access
- S3-compatible object storage
- OpenMetrics
- OpenTelemetry
- standard application logs
- TLS file bindings
- BaseHarbor Runtime API

The application describes what it needs. BaseHarbor decides how that intent is realized.

## Run the full acceptance suite

Against a published BaseHarbor release:

```bash
BASEHARBOR_VERSION=v0.4.15 bash scripts/acceptance.sh
```

Against a candidate commit or ref:

```bash
BASEHARBOR_SOURCE_REF=<commit-or-ref> bash scripts/acceptance.sh
```

The suite validates the guided developer path plus deterministic lifecycle, capability, security, connectivity, reconciliation, failure and recovery scenarios on Docker and Podman/Quadlet.

Evidence is written below `artifacts/`.

## Run without BaseHarbor

The demo is still a normal Compose application:

```bash
docker compose --profile standalone up --build
```

Open:

```text
http://localhost:8080
```

The standalone profile starts local backing services only for standalone demo use.
