<p align="center">
  <img src="https://raw.githubusercontent.com/mcpdev80/baseharbor/main/docs/brand/github_banner.png" alt="BaseHarbor" width="100%">
</p>

<h1 align="center">BaseHarbor Demo</h1>
<p align="center"><strong>A normal application repository adopted through BaseHarbor's source-neutral workload model.</strong></p>

This repository starts as an ordinary application repository: no committed `baseharbor.yaml`, no prepared BaseHarbor state and no provider-specific application contract.

## v0.4.23 candidate

v0.4.23 is being qualified and is not approved for pre-release yet. The published
release remains v0.4.22. Run candidate acceptance with an explicit immutable Core
commit; the release candidate also pins this Demo repository to an exact commit.

BaseHarbor Core includes SQL, Secrets and Identity, realized by PostgreSQL,
OpenBao and Keycloak. The Web Console is optional. When the first application
needs Core services, guided setup offers to bootstrap them and continues the
original application workflow only after verified Core readiness. A retry
reconciles the same owned installation.

The setup asks whether this is a development or deployment machine. This changes
source/workspace defaults; TLS and protected credentials remain required. Core
can also be set up without this Demo, another application or a repository through
`baha up --control-plane-only`.

Core capabilities are mandatory; provider placement may be shared or
application-isolated. This Demo's shared-provider examples describe its selected
reference topology. Additional isolation can add provider instances and resource
consumption. Use measured observations for the selected topology rather than
assuming a universal memory minimum.

An optional Console connects to one selected Core in the same installation and
security boundary. Same-origin HTTPS is the preferred topology.

## Try it

Requirements: Linux, Docker or Podman, Git, and `baha` in `PATH`.

From a pristine checkout:

```bash
baha app inspect .
baha app init
baha up
```

That's the normal developer path.

BaseHarbor keeps repository workload syntax separate from portable application intent. Compose, repository-authored Quadlet and raw Kubernetes YAML are inspected through the same Workload Source Adapter boundary; this demo is the Compose source example. You can inspect the effective destination at any time with:

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
- provider management surfaces for PostgreSQL, cache, durable key-value, MongoDB document storage, RabbitMQ messaging, object storage, OpenBao, identity and Prometheus
- dedicated atomic semantic proofs for `database.key-value`, `database.document`, `messaging.queue`, `messaging.pubsub` and `messaging.stream`
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

The companion application exposes `/healthz` and `/hello` through its canonical BaseHarbor development route. Use `baha status` from `companion-app/` to read the effective HTTPS URL and gateway port; the runtime may select a fallback host port when a preferred port is already occupied.

Create the same directed connection used by the release acceptance suite:

```bash
baha connect demo/demo-app companion-app/companion-app
baha connections

(
  cd companion-app
  baha status
)
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

The reference workload itself is HTTPS-only. Its Compose service declares:

```yaml
labels:
  io.baseharbor.workload.protocol: "https"
```

BaseHarbor uses that declaration for the canonical development route, verifies the workload certificate with the BaseHarbor-issued workload CA, and sends the workload service name as TLS SNI. The demo intentionally has no plaintext HTTP fallback.

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

The guided demo keeps provider placement explicit and capability-first. Repository workload syntax stays outside the portable application contract: `baseharbor.yaml` contains only logical workload components.

Availability stays equally small in portable intent: a global `ha: true|false` plus sparse per-component overrides where needed. Provider/runtime topology, replica/member identities and failure-domain mechanics remain BaseHarbor realization details. `baha status` and `baha doctor` report the resolved availability truth and fail closed when a selected realization cannot satisfy the requested guarantee. Management credentials, application-service credentials and internal machine identities remain separate ownership classes; the demo never receives provider-admin credentials as application bindings. The scanner may resolve an obviously dominant repository source without persisting extra metadata; `baseharbor.repository.yaml` is written only when an explicit source choice must be retained. Shared PostgreSQL and cache Valkey remain Target-owned with application-isolated resources; durable key-value, document-database and messaging capabilities are exercised through dedicated atomic provider gates so their heavier application-scoped providers do not inflate every guided run.

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

Selected development management surfaces reuse one Target- and environment-scoped developer login. The default username is `developer`, but it is only a default: set another username explicitly with `baha dev credentials --username USER`. The credential is reused by later shared management surfaces in the same Target/environment. The password is revealed only through the explicit `baha dev credentials` command and is never included in normal status, doctor or acceptance evidence.

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

BaseHarbor recovery units can include managed SQL, the application-owned secret scope, managed S3 objects, BaseHarbor-owned workload volumes and selectable application log history. External data remains outside BaseHarbor ownership and unsupported state is reported explicitly instead of being silently omitted.

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

BaseHarbor adopts an existing application without rewriting its repository workload source or leaking source-native/provider details into the portable application contract.

The same application intent is consumed through standard interfaces:

- OCI workloads
- source-neutral logical workload components
- Compose as this repository's selected workload source
- repository-authored Podman Quadlet and raw Kubernetes YAML as equivalent inspection/adoption source families
- Docker/Podman as the current local runtime realization path
- SQL-compatible database access
- Redis/Valkey-compatible cache access
- durable key-value semantics distinct from cache
- document-database semantics through the MongoDB reference provider
- queue, pub/sub and stream messaging semantics through the RabbitMQ reference provider
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
BASEHARBOR_VERSION=v0.4.22 bash scripts/acceptance.sh
```

Against a candidate commit or ref:

```bash
BASEHARBOR_SOURCE_REF=<commit-or-ref> bash scripts/acceptance.sh
```

The release validation uses independently rerunnable atomic gates. Static contract/DX gates require no provider containers; Docker and Podman gates start only the resource profile required by the selected capability. Dedicated gates cover durable key-value, MongoDB document storage, RabbitMQ messaging, managed OIDC identity, observability, reconciliation, failure, recovery and final cleanup.

Each acceptance run creates an isolated explicit BaseHarbor Target for the selected runtime and isolates BaseHarbor config/state through temporary XDG config/data roots. This proves the Target boundary and the source/capability/provider/runtime contracts instead of relying on repository-source syntax inside portable application intent.

Evidence is written below `artifacts/`.

## Run without BaseHarbor

The demo remains HTTPS-only even in standalone mode. Create a local development certificate first:

```bash
mkdir -p .demo-tls
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout .demo-tls/tls.key \
  -out .demo-tls/tls.crt \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

Then start the normal Compose file plus the standalone TLS override:

```bash
docker compose -f compose.yaml -f compose.standalone.yaml --profile standalone up --build
```

Open:

```text
https://localhost:8080
```

The certificate is intentionally local/self-signed in standalone mode. Under BaseHarbor, certificate issuance, projection and trust are managed by BaseHarbor instead.
