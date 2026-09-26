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

BaseHarbor v0.4.15 keeps the deployment destination separate from the repository intent. You can inspect the effective destination at any time with:

```bash
baha target
baha target -o json
```

For explicit local targets, create and activate one before `baha up`, for example:

```bash
baha target create laptop-docker --provider docker --access local-docker --reference local --scope default --default
eval "$(baha target activate laptop-docker)"
```

### Optional shell integration

The normal demo does not require shell customization. If you want it afterwards:

```bash
source <(baha completion bash)
source <(baha shell-init bash)
baha config prompt
```

`baha config prompt` opens the guided prompt wizard. Completion and prompt integration are optional developer conveniences and do not change Target identity or deployment ownership.

- `inspect` shows what BaseHarbor detects without changing the repository.
- `init` turns the detected application intent into `baseharbor.yaml`.
- `up` converges the managed services, secrets, runtime bindings and application workload.

On the first run BaseHarbor can ask for required setup such as the OpenBao recovery location and application-owned secrets. After that, the application should be ready.

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

## Run the complete two-application demo

The repository also contains `companion-app/`, a second ordinary Compose application. Deploying it proves that BaseHarbor can manage two independent applications on the same Target and then create an explicit directional connection between them.

After the main demo is READY:

```bash
(
  cd companion-app
  baha app inspect .
  baha app init --quick
  baha up --yes
  baha doctor
)
```

The companion application listens on `http://localhost:8081` and exposes `/healthz` and `/hello`.

Create the same directed connection used by the release acceptance suite:

```bash
baha connect baseharbor-demo/demo-app companion-app/companion-app
baha connections
curl http://localhost:8081/hello
```

Remove the connection again:

```bash
baha disconnect baseharbor-demo/demo-app companion-app/companion-app
```

When you are finished with the second app:

```bash
(
  cd companion-app
  baha app destroy --yes
)
```

The full acceptance suite performs this companion adoption and connectivity flow automatically through the `connectivity` gate.

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

BaseHarbor v0.4.16 recovery units can include managed SQL, the application-owned secret scope, managed S3 objects, BaseHarbor-owned workload volumes and selectable application log history. External data remains outside BaseHarbor ownership and unsupported state is reported explicitly instead of being silently omitted.

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

To intentionally remove the complete BaseHarbor-managed installation state across all Targets while preserving application source repositories:

```bash
baha destroy --all
baha destroy --all --yes
```

Without `--yes`, interactive use requires confirmation. The full acceptance suite exercises this cleanup as its final destructive gate.

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

The suite validates the guided developer path, Bash completion/shell integration/Target-aware prompt, deterministic lifecycle, capability, security, the companion-app cross-application connectivity flow, reconciliation, failure, recovery and final full-installation destroy scenarios on Docker and Podman/Quadlet.

Each acceptance run creates an isolated explicit BaseHarbor Target for the selected runtime and isolates BaseHarbor config/state through temporary XDG config/data roots. This proves the v0.4.15 Target boundary instead of relying on legacy repository-local platform state.

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
