<p align="center">
  <img src="https://raw.githubusercontent.com/mcpdev80/baseharbor/main/docs/brand/github_banner.png" alt="BaseHarbor" width="100%">
</p>

<h1 align="center">BaseHarbor Demo</h1>
<p align="center"><strong>Official reference application and external release acceptance suite.</strong></p>

<p align="center">
  A normal Compose application first. No committed <code>baseharbor.yaml</code>. No provider-specific application contract.
</p>

## What this repository proves

This repository is intentionally an ordinary Compose project before BaseHarbor touches it.

A pristine checkout contains:

```text
compose.yaml
application source
Dockerfiles

NO baseharbor.yaml
NO .baseharbor/
NO prepared BaseHarbor bindings
```

The canonical human adoption path is deliberately short:

```text
ordinary repository
      |
      v
baha app init
      |
      v
review detected intent
      |
      v
baha up
      |
      +--> OpenBao first-run recovery setup
      +--> managed provider/runtime credentials
      +--> missing application-secret input
      +--> backend/runtime convergence
      +--> workload build/start
      +--> readiness verification
      |
      v
READY
```

No manual YAML append, Compose rewrite, OpenBao bootstrap command, explicit preflight/apply sequence or shell-piped secret command is part of the normal human happy path.

The demo validates both:

- the guided human adoption path above;
- a deterministic non-interactive path for CI/agents and focused component regression tests.

## Capabilities exercised

The demo application uses application-facing interfaces only:

- SQL / PostgreSQL-compatible access
- Redis/Valkey-compatible cache
- S3-compatible object storage
- application-owned secrets
- OpenMetrics
- OTLP traces
- application logs
- BaseHarbor Runtime Resource API
- cross-application connectivity through the companion app

Concrete BaseHarbor reference providers are not application dependencies.

For BaseHarbor-managed execution the demo is fail-closed on transport security. The application consumes the canonical file bindings:

```text
TLS_CERT_FILE
TLS_KEY_FILE
```

If BaseHarbor runtime identity is present but those TLS bindings are missing, the demo refuses to start rather than silently downgrading to HTTP.

## Prerequisites

For the manual happy-path test you need:

- Linux
- Docker or Podman
- Git
- curl
- a BaseHarbor release or candidate build

The repository itself must start pristine:

```bash
git status --short
test ! -e baseharbor.yaml
test ! -e .baseharbor
```

## Install BaseHarbor for the test

### Published release

```bash
export BASEHARBOR_VERSION=v0.4.15
export BASEHARBOR_INSTALL_DIR="$PWD/.tools/bin"
bash scripts/install-baseharbor.sh
export PATH="$BASEHARBOR_INSTALL_DIR:$PATH"
baha version
```

Use the release version you actually want to validate.

### Candidate source

For a pre-release candidate:

```bash
export BASEHARBOR_SOURCE_REF=<commit-or-ref>
export BASEHARBOR_INSTALL_DIR="$PWD/.tools/bin"
bash scripts/install-baseharbor.sh
export PATH="$BASEHARBOR_INSTALL_DIR:$PATH"
baha version
```

## Complete manual BaseHarbor happy-path test

### 1. Inspect the pristine repository

Inspection is read-only:

```bash
baha app inspect .
```

Optional full evidence:

```bash
baha app inspect . --verbose
```

Expected result:

- the application workload is identified;
- repository PostgreSQL, Valkey and S3-compatible services are recognized as replaceable infrastructure;
- metrics, OTLP and Runtime API evidence is reported where detected;
- the repository is not modified.

### 2. Run guided adoption

```bash
baha app init
```

For this demo, select the root `compose.yaml` as the application workload if BaseHarbor asks because the companion application has its own Compose file.

Use the detected/default SQL, cache, object-storage, metrics and OTLP capabilities. Enable application logs as well.

For S3 use the logical bucket:

```text
uploads
```

Add the application-owned secret:

```text
APP_SECRET
```

Mark it required and choose:

```text
Ask for value during first apply
```

Before anything is written, BaseHarbor shows a human-readable adoption summary. Confirm it.

Afterwards:

```bash
test -f baseharbor.yaml
git diff -- compose.yaml
```

The second command must show no Compose modification.

### 3. Start everything through the normal repository command

Run:

```bash
baha up
```

On the first run BaseHarbor may ask where to create the operator-held OpenBao recovery file. Choose a secure path outside `.baseharbor/`, for example:

```text
/tmp/baseharbor-demo-openbao-recovery.json
```

When `APP_SECRET` is requested, enter a test value. Terminal echo is disabled and the value must not appear in normal output.

The same `baha up` operation then continues. No second apply command is required.

Expected convergence:

- OpenBao is initialized/unsealed through the normal repository flow;
- required application secrets are stored securely;
- managed SQL, cache and S3 services converge;
- runtime identity and Runtime API permissions are materialized;
- the repository workload is built and started;
- metrics/logs/traces are wired;
- the application reaches READY.

### 4. Verify the result

```bash
baha status
```

```bash
baha doctor
```

The application URL and runtime documentation URL shown by BaseHarbor can then be opened in a browser.

The demo UI exposes real capability actions for SQL, cache, object storage, secret presence, metrics, traces and runtime resources.

### 5. Verify lifecycle convergence

Stop only the application runtime:

```bash
baha app down
```

Start it again through the recommended repository command:

```bash
baha up
```

Verify:

```bash
baha doctor
```

A no-change run should converge without unnecessary rebuild/recreation:

```bash
baha up
```

### 6. Cleanup

```bash
baha app destroy --yes
```

Remove only generated local test files when desired:

```bash
rm -rf .baseharbor baseharbor.yaml
```

Keep the OpenBao recovery file under operator control until the corresponding managed state is intentionally discarded.

## Deterministic CI / agent path

The human guided flow is not replaced by CI-specific shortcuts.

Automation uses deterministic commands such as:

```bash
baha app init --quick
```

or explicit app-init flags where the desired contract is already known. Ambiguous detection fails closed instead of guessing.

Explicit secret automation remains available:

```bash
printf '%s' "$APP_SECRET" | baha app secret set APP_SECRET --stdin
```

That is an automation interface, not the recommended human command.

## Run the complete external acceptance suite

Published release:

```bash
BASEHARBOR_VERSION=v0.4.15 bash scripts/acceptance.sh
```

Candidate SHA/ref:

```bash
BASEHARBOR_SOURCE_REF=<commit-or-ref> bash scripts/acceptance.sh
```

The suite includes a dedicated `guided` gate for the pristine-repository human flow and separate deterministic/component gates.

Evidence is written to:

```text
artifacts/results.tsv
artifacts/groups.tsv
artifacts/acceptance.json
```

Typical coverage includes:

```text
Guided Adoption Happy Path
Repository Inspection / Deterministic Init
Application Lifecycle
SQL
Cache
Object Storage
Secrets
Metrics
Telemetry / Traces
Logs
Cross-App Connectivity
Backup / Restore
Reconciliation
Workload Security
Agent Interface
MCP
Secret Leak Checks
```

## Run without BaseHarbor

The repository remains independently usable as a normal Compose project:

```bash
docker compose --profile standalone up --build
```

Open:

```text
http://localhost:8080
```

The standalone profile starts local PostgreSQL, Valkey and S3-compatible storage solely for standalone demo use.

## Companion application

`companion-app/` is a second ordinary Compose application used for directional connectivity, isolation and ownership-boundary tests.

It is intentionally why guided detection can see more than one Compose file: the user must be able to identify the application workload without BaseHarbor rewriting either repository Compose file.

## CI and release policy

The demo has two responsibilities:

1. prove the primary guided developer experience from a pristine repository;
2. provide deterministic focused gates for release regression coverage.

BaseHarbor pre-release validation must execute the external demo against the exact BaseHarbor candidate SHA and an exact BaseHarbor Demo SHA.

The final BaseHarbor release does **not** rerun the same expensive acceptance matrix. It consumes the successful immutable pre-release approval/evidence and performs only release-only checks and publishing.

This repository therefore acts as tutorial, showcase, external consumer contract and release gate.

## Long-term runtime target

The application intent remains stable:

```text
same application
same application contract

Compose       now
Kubernetes    later
OpenShift     later
```
