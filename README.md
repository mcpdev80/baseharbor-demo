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

BaseHarbor v0.4.17 keeps the deployment destination separate from repository intent and adds standards-first managed application identity. You can inspect the effective destination at any time with:

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

- shared PostgreSQL with an application-isolated database and role
- shared Valkey provider lifecycle with an application-isolated cache service
- S3-compatible object storage
- secrets
- metrics
- traces
- logs
- BaseHarbor Runtime Resources
- standard OIDC application identity
- provider management surfaces for PostgreSQL, cache, object storage, OpenBao, identity and Prometheus
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
baha connect demo/demo-app companion-app/companion-app
baha connections
curl http://localhost:8081/hello
```

Remove the connection again:

```bash
baha disconnect demo/demo-app companion-app/companion-app
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

OIDC_ISSUER
OIDC_CLIENT_ID
OIDC_SCOPES
OIDC_CLIENT_SECRET_FILE
OIDC_CA_FILE
```

For example, `DATABASE_CA_FILE=/run/baseharbor/.../ca.pem` is only a path reference. BaseHarbor mounts the referenced CA into the workload container read-only. This keeps the application contract portable and avoids multiline certificate data or private keys in environment files.

## Managed identity and management UIs

When Identity/OIDC is selected, the demo app consumes only standard application-facing bindings:

```text
OIDC_ISSUER
OIDC_CLIENT_ID
OIDC_SCOPES
OIDC_CLIENT_SECRET_FILE
OIDC_CA_FILE
```

The application calls the issuer's standard `/.well-known/openid-configuration` endpoint with the provided trust file. It does not call Keycloak administration APIs and does not depend on a BaseHarbor authentication SDK.

The guided v0.4.17 demo deliberately uses **shared placement for every managed provider except the application workload**. PostgreSQL is one Target-owned provider with application-isolated databases/roles. Valkey uses one Target-owned provider lifecycle with isolated per-application cache resources so normal Redis/Valkey clients keep working without cross-application key access.

The guided demo also selects the optional management surfaces. In local dev, `baha status` reports their HTTPS URLs and semantic purpose:

- PostgreSQL -> pgAdmin
- cache -> Redis Commander
- object storage -> shared SeaweedFS Admin
- secrets -> shared OpenBao UI
- identity -> user-facing Keycloak login/account plus a separate Keycloak administration surface
- observability -> Prometheus web UI

Provider-admin credentials are not projected into the demo application.

For shared PostgreSQL this boundary is explicit: `baseharbor_admin` belongs only to the BaseHarbor control plane. The demo workload receives an application-specific PostgreSQL role, password and database through its normal Service Binding. The guided/security gates require `postgres/isolation` verification and fail if `baseharbor_admin` appears in the workload binding or status evidence.

For local development, BaseHarbor derives canonical browser URLs from one Target-scoped development domain. With the default domain the demo uses addresses such as:

```text
https://demo.baha.localhost
https://demo.baha.localhost/swagger/
https://pgadmin.baha.localhost
https://cache.baha.localhost
https://auth.baha.localhost
https://auth-admin.baha.localhost
https://storage.baha.localhost
https://secrets.baha.localhost
https://metrics.baha.localhost
```

Random loopback ports remain runtime implementation detail. The domain can be inspected or changed with `baha dev domain [DOMAIN]`.

Selected development management surfaces reuse one Target-scoped developer login. The default username is `developer`; the generated password is revealed only through the explicit `baha dev credentials` command and is never included in normal status, doctor or acceptance evidence.

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

BaseHarbor v0.4.17 recovery units can include managed SQL, the application-owned secret scope, managed S3 objects, BaseHarbor-owned workload volumes and selectable application log history. External data remains outside BaseHarbor ownership and unsupported state is reported explicitly instead of being silently omitted.

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
BASEHARBOR_VERSION=v0.4.17 bash scripts/acceptance.sh
```

Against a candidate commit or ref:

```bash
BASEHARBOR_SOURCE_REF=<commit-or-ref> bash scripts/acceptance.sh
```

The suite validates the guided developer path, Bash completion/shell integration/Target-aware prompt, deterministic lifecycle, capabilities, managed OIDC identity, provider management surfaces, security, the companion-app cross-application connectivity flow, reconciliation, failure, recovery and final full-installation destroy scenarios on Docker and Podman/Quadlet.

Each acceptance run creates an isolated explicit BaseHarbor Target for the selected runtime and isolates BaseHarbor config/state through temporary XDG config/data roots. This proves the Target boundary and the v0.4.17 managed-identity/provider-interface contract instead of relying on legacy repository-local platform state.

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
