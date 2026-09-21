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

The acceptance suite starts from:

```text
compose.yaml
application source
Dockerfiles

NO baseharbor.yaml
NO .baseharbor/
NO prepared BaseHarbor bindings
```

Then it exercises the real adoption path:

```text
ordinary repository
      ↓
baha app inspect
      ↓
baha app init
      ↓
plan / policy / preflight
      ↓
apply / verify
      ↓
real application capability tests
      ↓
reconciliation / connectivity / security
      ↓
backup / restore
```

The demo always validates a **published BaseHarbor release**, never BaseHarbor `develop`.

## Fast and presentation-ready

The main application is a small Go binary with server-rendered HTML and a tiny amount of vanilla JavaScript.

There is no Node/React build chain.

The UI provides real interactive operations for:

- SQL
- Redis/Valkey-compatible cache
- S3-compatible object storage
- secret binding verification
- OpenMetrics
- OTLP traces
- Runtime Resource API
- cross-app connectivity through the companion app

The application uses only standard application-facing interfaces. Concrete BaseHarbor reference providers are not application dependencies.

## Run without BaseHarbor

The repository remains understandable as a normal Compose project.

```bash
docker compose --profile standalone up --build
```

Open:

```text
http://localhost:8080
```

The standalone profile starts local PostgreSQL, Valkey and S3-compatible storage solely so the demo can also run without BaseHarbor.

## Run the BaseHarbor release acceptance

The acceptance suite installs an exact published release and starts from a pristine repository state.

```bash
BASEHARBOR_VERSION=v0.4.14 bash scripts/acceptance.sh
```

The result is written to:

```text
artifacts/results.tsv
artifacts/acceptance.json
```

Example summary:

```text
BaseHarbor v0.4.14 Acceptance

Repository Inspection        PASS
Application Init Quick       PASS
Application Init Deterministic PASS
Plan                         PASS
Policy                       PASS
SQL                          PASS
Cache                        PASS
Object Storage               PASS
Secrets                      PASS
Metrics                      PASS
Telemetry / Traces           PASS
Logs                         PASS
Cross-App Connectivity       PASS
Backup / Restore             PASS
Reconciliation               PASS
Workload Security            PASS
Agent Interface              PASS
MCP                          PASS
Secret Leak Checks           PASS

RESULT                       PASS
```

## Companion application

`companion-app/` is a second small ordinary Compose application used for:

- `baha connect`
- `baha connections`
- `baha disconnect`
- directional connectivity
- isolation
- ownership boundaries

It is independently adopted by BaseHarbor during acceptance.

## CI policy

GitHub Actions are intentionally economical.

- `validate.yml` — manual lightweight source/build validation.
- `acceptance.yml` — manual exact-release acceptance or `repository_dispatch` from a BaseHarbor release.
- no automatic push/PR acceptance matrix.

A future BaseHarbor release workflow can dispatch:

```json
{
  "event_type": "baseharbor_release",
  "client_payload": {
    "version": "v0.4.14"
  }
}
```

## Brand

The demo follows the canonical **BaseHarbor CI v1.0** from `mcpdev80/baseharbor/docs/brand`.

Canonical palette:

```text
Harbor Navy    #0B152A
Ocean Blue     #0068E9
Signal Blue    #0583FB
Harbor Orange  #F96509
Mist           #E3EAF1
White          #FFFFFF
```

Typography:

- Inter
- JetBrains Mono

The BaseHarbor master artwork remains canonical and is not redrawn or re-typeset.

## Long-term runtime target

The application and intent remain the same:

```text
same application
same application contract

Compose       now
Kubernetes    later
OpenShift     later
```

That makes this repository a showcase, tutorial, regression suite and external consumer test for every BaseHarbor release.
