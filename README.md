# Trino + OPA: Fine-Grained Access Control

A complete guide to deploying [Open Policy Agent (OPA)](https://www.openpolicyagent.org/) as an authorization engine for [Trino](https://trino.io/), with hot policy reloading so you never need to restart either service after a policy change.

---

## Table of Contents

1. [What is OPA?](#what-is-opa)
2. [Why OPA with Trino?](#why-opa-with-trino)
3. [How it Works](#how-it-works)
4. [Repository Layout](#repository-layout)
5. [Quick Start (Docker Compose)](#quick-start-docker-compose)
6. [Writing Policies in Rego](#writing-policies-in-rego)
7. [Testing Policies Without Trino](#testing-policies-without-trino)
8. [Hot Reload: No Restart Required](#hot-reload-no-restart-required)
9. [Production: Kubernetes](#production-kubernetes)
10. [Trino Helm Chart Explained](#trino-helm-chart-explained)
11. [Production: Terraform](#production-terraform)
12. [The Batch API](#the-batch-api)
13. [CI: GitHub Actions & GitLab CI](#ci-github-actions--gitlab-ci)
14. [Troubleshooting](#troubleshooting)

---

## What is OPA?

**Open Policy Agent (OPA)** is a general-purpose policy engine that decouples authorization logic from application code. Instead of embedding `if user == "admin"` checks throughout your services, you write policies in a declarative language called **Rego** and OPA evaluates them at runtime via a simple HTTP API.

Key properties:

- **Language-agnostic** — OPA is a standalone service; any application calls it over HTTP.
- **Declarative** — Rego policies describe *what is allowed*, not *how to check it*.
- **Fast** — policy evaluation is typically sub-millisecond.
- **Hot-reloadable** — policies can be updated without restarting OPA or the services that consume it.

---

## Why OPA with Trino?

Trino's built-in access control options (file-based, system-level) are coarse-grained and require a Trino restart to apply changes. OPA gives you:

| Feature | Trino file-based | Trino + OPA |
|---|---|---|
| Row/column filtering | No | Yes |
| Policy updates without restart | No | Yes |
| Logic reuse across services | No | Yes |
| Unit-testable policies | No | Yes |
| Audit log via OPA decision logs | No | Yes |

Trino ships with a built-in OPA access-control plugin (available since Trino 435). You configure it once and it calls OPA for every authorization decision.

---

## How it Works

```
 User query
     │
     ▼
┌─────────┐    HTTP POST /v1/data/trino/allow    ┌─────────┐
│  Trino  │ ─────────────────────────────────────▶│   OPA   │
│ (query  │ ◀─────────────────────────────────────│(policy  │
│ engine) │         {"result": true/false}        │ engine) │
└─────────┘                                       └─────────┘
                                                      │
                                              loads opa/trino.rego
```

1. A user submits a SQL query to Trino.
2. Trino's OPA plugin sends a JSON payload describing the action (operation, catalog, schema, table, user identity) to OPA's REST API.
3. OPA evaluates the request against your Rego policy and returns `true` or `false`.
4. Trino allows or denies the query.

For listing operations (show catalogs, show tables, etc.), Trino uses the **batch endpoint** to evaluate a list of resources in a single OPA call, which is much more efficient than one call per resource.

---

## Repository Layout

```
trino-opa/
├── .github/
│   └── workflows/
│       └── ci.yml              # GitHub Actions pipeline
├── .gitlab-ci.yml              # GitLab CI pipeline
├── docker-compose.yml          # Local dev: Trino + OPA with hot reload
├── opa/
│   ├── trino.rego              # Example RBAC policy
│   └── trino_test.rego         # OPA unit tests (run in CI)
├── trino/
│   ├── config.properties       # Trino coordinator config (Docker Compose)
│   ├── access-control.properties  # Points Trino at OPA
│   └── catalog/
│       ├── analytics_prod.properties  # tpch connector (read-only test data)
│       ├── analytics_stage.properties
│       ├── reporting.properties
│       ├── bi_prod.properties
│       └── sandbox.properties         # memory connector (writable)
├── kubernetes/
│   ├── opa-configmap.yaml      # Policy stored as a ConfigMap
│   ├── opa-deployment.yaml     # OPA Deployment with auto-restart on policy change
│   └── opa-service.yaml        # ClusterIP Service for Trino → OPA traffic
└── terraform/
    ├── main.tf                 # Providers, namespace, backend config
    ├── variables.tf            # All input variables with defaults
    ├── trino.tf                # Trino Helm release
    ├── helm-values.yml         # Helm values template (rendered by trino.tf)
    └── opa.tf                  # OPA Deployment, Service, and ConfigMap
```

---

## Quick Start (Docker Compose)

### Prerequisites

- Docker and Docker Compose
- (Optional) Trino CLI or any JDBC client

### 1. Start the stack

```bash
docker compose up -d
```

This starts:
- **OPA** on `http://localhost:8181` — watching `./opa/` for policy changes
- **Trino** on `http://localhost:8080` — configured to call OPA for every authorization decision

### 2. Verify OPA is running

```bash
curl http://localhost:8181/health
# {"healthy": true}
```

### 3. Connect to Trino

```bash
# Using the Trino CLI (download from https://trino.io/download.html)
trino --server http://localhost:8080 --user admin
```

### 4. Explore the test catalogs

Five catalogs are pre-configured to match the example policy:

| Catalog | Connector | Who can access |
|---|---|---|
| `analytics_prod` | `tpch` (read-only, generated data) | `admin`, `read_only_user` |
| `analytics_stage` | `tpch` | `admin`, `read_only_user` |
| `reporting` | `tpch` | `admin`, `read_only_user` |
| `bi_prod` | `tpch` | `admin`, analyst users (`alice`, `bob`, `charlie`) |
| `sandbox` | `memory` (writable, in-memory) | `admin`, analyst users (full access in `dev_*` schemas) |

The `tpch` connector ships built-in with Trino and generates TPC-H benchmark data on the fly — no external database needed. The `memory` connector stores tables in-process; data is lost when Trino restarts, which is fine for testing writes.

```sql
-- As admin: see all catalogs
SHOW CATALOGS;

-- As read_only_user: only analytics_prod, analytics_stage, reporting visible
SHOW CATALOGS;

-- Query generated tpch data
SELECT * FROM analytics_prod.tiny.orders LIMIT 10;

-- As alice: create a dev schema and table in the sandbox
CREATE SCHEMA sandbox.dev_alice;
CREATE TABLE sandbox.dev_alice.test (id bigint, name varchar);
INSERT INTO sandbox.dev_alice.test VALUES (1, 'hello');

-- As alice: writing to a non-dev schema is denied
CREATE SCHEMA sandbox.production;  -- ACCESS DENIED
```

### 5. Edit a policy — no restart needed

Open `opa/trino.rego`, add a rule, and save. OPA picks up the change immediately (within ~1 second) because it was started with `--watch`. Trino's next query will use the updated policy.

---

## Writing Policies in Rego

Rego is a purpose-built policy language. Here's how the example policy in `opa/trino.rego` is structured.

### Package declaration

```rego
package trino

import future.keywords.if
import future.keywords.in
```

The package name `trino` must match the URL path Trino calls: `/v1/data/trino/allow`.

### Default deny

```rego
default allow := false
```

Every request is denied unless a rule explicitly grants access. This is the safe baseline.

### Admin — full access

```rego
allow if {
    input.context.identity.user == "admin"
}
```

`input` is the JSON object Trino sends to OPA. `input.context.identity.user` is the authenticated username.

### Read-only user

```rego
_read_only_catalogs := {"analytics_prod", "analytics_stage", "reporting"}

_read_ops := {
    "ExecuteQuery", "AccessCatalog", "FilterCatalogs",
    "ShowSchemas",  "FilterSchemas",
    "ShowTables",   "FilterTables",
    "ShowColumns",  "FilterColumns",
    "SelectFromColumns",
    "ExecuteFunction", "FilterFunctions",
    "ExecuteProcedure",
}

allow if {
    input.context.identity.user == "read_only_user"
    input.action.operation in _read_ops
    input.action.resource.table.catalogName in _read_only_catalogs
}
```

All conditions in a rule body must be true for the rule to fire. This reads as: "allow if the user is `read_only_user` AND the operation is a read operation AND the catalog is in the permitted set."

### Browsing without a table resource

Some operations (e.g., `SHOW SCHEMAS`) don't have a table resource in the request yet. Without this rule, `read_only_user` would be denied before they can even see the schema list:

```rego
allow if {
    input.context.identity.user == "read_only_user"
    input.action.operation in {"ExecuteQuery", "AccessCatalog", "FilterCatalogs", "ShowSchemas", "FilterSchemas"}
    not input.action.resource.table
}
```

### Scoped write access (dev_ schemas)

```rego
allow if {
    input.context.identity.user in _analyst_users
    input.action.resource.table.catalogName == "sandbox"
    startswith(input.action.resource.table.schemaName, "dev_")
}
```

Analysts can write freely to any schema whose name starts with `dev_` in the `sandbox` catalog. All other write operations are denied.

### Inspecting the input object

To see exactly what Trino sends to OPA, query OPA's data API directly:

```bash
# What does OPA receive for a given query? Enable decision logging:
# Add --log-level=debug to OPA's startup arguments.

# Or test a request manually:
curl -s -X POST http://localhost:8181/v1/data/trino/allow \
  -H "Content-Type: application/json" \
  -d '{
    "input": {
      "context": {"identity": {"user": "alice"}},
      "action": {
        "operation": "SelectFromColumns",
        "resource": {
          "table": {
            "catalogName": "bi_prod",
            "schemaName":  "public",
            "tableName":   "orders"
          }
        }
      }
    }
  }'
# {"result": true}
```

---

## Testing Policies Without Trino

OPA has a built-in test runner. Create test files alongside your policy:

```bash
# opa/trino_test.rego
package trino_test

import data.trino

test_admin_allowed {
    trino.allow with input as {
        "context": {"identity": {"user": "admin"}},
        "action": {"operation": "DropTable", "resource": {}}
    }
}

test_read_only_user_select_allowed {
    trino.allow with input as {
        "context": {"identity": {"user": "read_only_user"}},
        "action": {
            "operation": "SelectFromColumns",
            "resource": {"table": {"catalogName": "analytics_prod", "schemaName": "public", "tableName": "sales"}}
        }
    }
}

test_read_only_user_write_denied {
    not trino.allow with input as {
        "context": {"identity": {"user": "read_only_user"}},
        "action": {
            "operation": "InsertIntoTable",
            "resource": {"table": {"catalogName": "analytics_prod", "schemaName": "public", "tableName": "sales"}}
        }
    }
}
```

Run the tests:

```bash
docker run --rm -v $(pwd)/opa:/policies openpolicyagent/opa:latest \
  test /policies --verbose
```

All tests pass → safe to deploy.

---

## Hot Reload: No Restart Required

### Local (Docker Compose)

OPA is started with `--watch` and bound to all interfaces so other containers can reach it:

```yaml
command: ["run", "--server", "--watch", "--addr=0.0.0.0:8181", "--log-level=info", "/policies"]
```

`--watch` polls the policy directory for file changes and reloads automatically. Edit `opa/trino.rego`, save — done. **No OPA restart, no Trino restart.**

### Production (Kubernetes)

Kubernetes mounts ConfigMaps into pods. When the ConfigMap is updated, Kubernetes eventually propagates the new file into running pods — but OPA only reads files at startup.

The solution used here: **annotate the pod with a hash of the ConfigMap**. When the hash changes, Kubernetes sees a different pod spec and performs a rolling restart automatically.

With plain `kubectl`:

```bash
# 1. Update the ConfigMap
kubectl create configmap trino-opa-policies \
  --from-file=trino.rego=./opa/trino.rego \
  --namespace=trino \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Trigger a rolling restart
kubectl rollout restart deployment/trino-opa -n trino

# 3. Watch the rollout
kubectl rollout status deployment/trino-opa -n trino
```

With **Terraform**, this is automatic — the `configmap-hash` annotation is computed from the ConfigMap content, so `terraform apply` restarts OPA whenever the policy file changes (see `terraform/opa.tf`).

### Why not use OPA's --watch in Kubernetes?

Kubernetes mounts ConfigMap data via a symlink (`..data/` indirection). OPA's `--watch` follows the symlink target, not the symlink itself, and can end up seeing duplicate package definitions when the symlink is atomically updated. Mounting with `subPath` avoids the symlink entirely and delivers a plain file — but `subPath` mounts are not updated live by Kubernetes. The rolling restart approach is therefore more reliable in production.

---

## Production: Kubernetes

Apply the manifests in order:

```bash
# Create namespace if it doesn't exist
kubectl create namespace trino --dry-run=client -o yaml | kubectl apply -f -

# Apply OPA resources
kubectl apply -f kubernetes/opa-configmap.yaml
kubectl apply -f kubernetes/opa-deployment.yaml
kubectl apply -f kubernetes/opa-service.yaml
```

After your Trino Helm chart or deployment is configured with `access-control.properties` pointing to `http://trino-opa:8181/v1/data/trino/allow`, Trino will call OPA for every authorization decision.

**To update the policy:**

```bash
# Edit opa/trino.rego, then:
kubectl create configmap trino-opa-policies \
  --from-file=trino.rego=./opa/trino.rego \
  --namespace=trino \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/trino-opa -n trino
```

A rolling restart means one new OPA pod comes up and passes its readiness probe before the old pod is terminated. Trino sees no downtime.

### Trino Helm chart configuration

Add to your `values.yaml`:

```yaml
additionalConfigFiles:
  access-control.properties: |
    access-control.name=opa
    opa.policy.uri=http://trino-opa:8181/v1/data/trino/allow
    opa.policy.batched-uri=http://trino-opa:8181/v1/data/trino/batch
```

The `trino-opa` hostname resolves via Kubernetes DNS to the ClusterIP service defined in `opa-service.yaml`.

---

## Trino Helm Chart Explained

The official Trino Helm chart (from `https://trinodb.github.io/charts`) is the standard way to run Trino in Kubernetes. This section walks through every significant section of `terraform/helm-values.yml`.

### Adding the chart repository

```bash
helm repo add trino https://trinodb.github.io/charts
helm repo update

# Check available versions
helm search repo trino/trino --versions
```

### Image

```yaml
image:
  repository: trinodb/trino
  tag: "481"
  pullPolicy: IfNotPresent
```

`tag` is the Trino release version. The chart version and the Trino version are independent — always pin both. Use `IfNotPresent` in production to avoid surprise image pulls during rollouts.

### Server

```yaml
server:
  workers: 2
  node:
    environment: production
    dataDir: /data/trino
  config:
    authenticationType: "PASSWORD"
    query:
      maxMemory: "6GB"
```

- `workers` — number of worker pods. The coordinator is always a single pod deployed separately.
- `authenticationType: "PASSWORD"` — enables htpasswd-style basic authentication. Other options: `OAUTH2`, `CERTIFICATE`, `KERBEROS`.
- `query.maxMemory` — total memory allowed per query across all nodes. Queries that exceed this are killed.

### additionalConfigProperties

```yaml
additionalConfigProperties:
  - internal-communication.shared-secret=mysecret
  - http-server.process-forwarded=true
```

These lines are appended verbatim to Trino's `config.properties` on every node.

- `internal-communication.shared-secret` — a random string (generate with `openssl rand -hex 32`) that authenticates coordinator ↔ worker traffic. Required when `authenticationType` is set.
- `http-server.process-forwarded=true` — trust the `X-Forwarded-For` header from a load balancer or ingress, so Trino reports the real client IP in query logs.

### Authentication

```yaml
auth:
  passwordAuth: "admin:$2y$10$...\nalice:$2y$10$..."
```

Each line is `username:bcrypt_hash`. Generate a hash:

```bash
# Apache htpasswd (available via the httpd-tools / apache2-utils package)
htpasswd -bnBC 10 '' mypassword | tr -d ':'

# Python alternative (no extra packages needed)
python3 -c "import bcrypt; print(bcrypt.hashpw(b'mypassword', bcrypt.gensalt(10)).decode())"
```

The Helm chart creates a Kubernetes Secret from this string and mounts it as `/etc/trino/password.db`. Trino's `PASSWORD` authentication reads that file.

### Coordinator

```yaml
coordinator:
  jvm:
    maxHeapSize: "8G"
    gcMethod:
      type: "UseG1GC"
      g1:
        heapRegionSize: "32M"

  config:
    memory:
      heapHeadroomPerNode: "1GB"
    query:
      maxMemoryPerNode: "4GB"

  resources:
    requests:
      memory: "10Gi"
      cpu: "3"
    limits:
      memory: "10Gi"
      cpu: "3"
```

**JVM heap vs pod memory:** The JVM heap (`maxHeapSize`) must be smaller than the pod's memory limit. The difference is consumed by JVM off-heap memory (code cache, native buffers, GC overhead). A safe rule: heap ≈ 75% of limit.

**G1GC with 32M regions** is the recommended garbage collector for Trino. It reduces GC pause times compared to the default CMS/Parallel collectors, which matters for interactive query latency.

**`heapHeadroomPerNode`:** Trino uses this value to compute how much of the heap is available for query memory. It reserves this amount from the heap before assigning memory to queries — think of it as a buffer against GC pressure. A common value is 10% of the heap.

**`maxMemoryPerNode`:** The maximum memory a single query can use on the coordinator. Should be less than (heap − headroom).

**Requests = limits** is intentional for the JVM: since the JVM pre-allocates heap at startup, there is no benefit to setting a lower request. Kubernetes will schedule the pod on a node with enough memory and the pod will use it immediately.

### Worker

```yaml
worker:
  jvm:
    maxHeapSize: "8G"

  config:
    memory:
      heapHeadroomPerNode: "1GB"
    query:
      maxMemoryPerNode: "6GB"

  gracefulShutdown:
    enabled: true
    gracePeriodSeconds: 120

  terminationGracePeriodSeconds: 240
```

Workers are sized separately from the coordinator. It's common to give workers more memory per node since they do the heavy lifting (data scanning, joins, aggregations).

**Graceful shutdown:** When a worker pod is terminated (e.g., during a rolling update), Trino needs to drain in-flight query fragments before the pod exits. With `gracefulShutdown.enabled: true`, the worker:
1. Signals to the coordinator that it is going away.
2. Waits up to `gracePeriodSeconds` for running fragments to complete.
3. Terminates cleanly.

`terminationGracePeriodSeconds` must be greater than `gracePeriodSeconds` to give Kubernetes time to let the shutdown complete before it sends `SIGKILL`.

### OPA access control via `additionalConfigFiles`

```yaml
coordinator:
  additionalConfigFiles:
    access-control.properties: |
      access-control.name=opa
      opa.policy.uri=http://trino-opa:8181/v1/data/trino/allow
      opa.policy.batched-uri=http://trino-opa:8181/v1/data/trino/batch
```

`additionalConfigFiles` is a map of filename → content. The Helm chart mounts each entry as a file under `/etc/trino/`. This is how `access-control.properties` ends up in the coordinator container without modifying the Docker image.

Note that this is under `coordinator:` only — workers do not run the access control plugin. All authorization decisions go through the coordinator.

`trino-opa` is the Kubernetes DNS name of the OPA ClusterIP Service. Trino resolves it within the cluster.

### Ingress

```yaml
ingress:
  enabled: true
  annotations:
    kubernetes.io/ingress.class: "nginx"
  hosts:
    - host: "trino.example.com"
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: "trino-tls"
      hosts:
        - "trino.example.com"
```

The Helm chart creates a single Ingress pointing at the coordinator Service (workers are never exposed externally). The annotation selects the Ingress controller. For AWS ALB replace with:

```yaml
annotations:
  kubernetes.io/ingress.class: "alb"
  alb.ingress.kubernetes.io/scheme: "internet-facing"   # or "internal"
  alb.ingress.kubernetes.io/target-type: "ip"
  alb.ingress.kubernetes.io/certificate-arn: "<acm-arn>"
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
```

### Rolling update strategy

```yaml
coordinator:
  deployment:
    strategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 25%
        maxUnavailable: 25%
```

The coordinator is a single replica, so `maxUnavailable: 25%` rounds down to 0 — meaning Kubernetes always brings the new coordinator up before terminating the old one. This prevents downtime during upgrades but briefly doubles coordinator resource usage.

Workers use the same strategy. Combined with `gracefulShutdown`, rolling worker updates complete queries in flight before the old pod exits.

### Security context

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000

containerSecurityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

Trino's official Docker image runs as UID 1000 by default. Dropping all capabilities and disabling privilege escalation makes the pods pass most hardened Pod Security Standards policies (Restricted profile).

---

## Production: Terraform

The `terraform/` directory manages the full stack — Trino (via Helm) and OPA — with a single `terraform apply`.

### Files

| File | Purpose |
|---|---|
| `main.tf` | Kubernetes/Helm provider configuration, namespace resource |
| `variables.tf` | All tunable inputs — sizing, credentials, ingress, etc. |
| `trino.tf` | `helm_release` for Trino, wired to `helm-values.yml` |
| `helm-values.yml` | Helm values template, rendered with Terraform's `templatefile()` |
| `opa.tf` | OPA `ConfigMap`, `Deployment`, and `Service` |

### First deploy

**1. Add the Trino Helm repository**

```bash
helm repo add trino https://trinodb.github.io/charts
helm repo update
```

**2. Create a `terraform.tfvars` file**

```hcl
# terraform/terraform.tfvars

namespace = "trino"

# Generate: htpasswd -bnBC 10 '' mypassword | tr -d ':'
admin_password = "$2y$10$..."

# Add more users as "username:bcrypt-hash" strings
extra_users = [
  "alice:$2y$10$...",
  "bob:$2y$10$...",
]

# Generate: openssl rand -hex 32
internal_communication_shared_secret = "abc123..."

# Sizing (these defaults are suitable for a small cluster)
coordinator_workers = 2
coordinator_heap    = "8G"
coordinator_memory  = "10Gi"
coordinator_cpu     = "3"
worker_heap         = "8G"
worker_memory       = "10Gi"
worker_cpu          = "3"

# Expose Trino externally (optional)
ingress_enabled = true
trino_hostname  = "trino.example.com"
tls_secret_name = "trino-tls"   # name of an existing TLS Secret, or ""
```

**3. Initialize and apply**

```bash
cd terraform
terraform init
terraform apply
```

Terraform will:
1. Create the `trino` namespace.
2. Deploy OPA (ConfigMap + Deployment + Service).
3. Deploy Trino via Helm, waiting for OPA's Service to exist first.

### Connecting to a different cluster

The default provider uses `~/.kube/config`. To target a different cluster or context:

```hcl
# terraform.tfvars
kubeconfig_path    = "/path/to/kubeconfig"
kubeconfig_context = "my-cluster-context"
```

For **AWS EKS**, uncomment the `exec` provider block in `main.tf` and remove the `config_path` / `config_context` lines.

### Updating the policy (zero-restart)

Edit `opa/trino.rego`, then:

```bash
terraform apply
```

Terraform computes `sha256(jsonencode(...))` of the new ConfigMap and writes it as a pod annotation. Kubernetes detects the changed pod template and performs a rolling restart — new OPA pod up, old pod down, Trino never loses access to OPA.

### Memory sizing guide

The JVM heap should be about 75–80% of the pod memory limit. Leave the remainder as headroom for the JVM's off-heap buffers (native memory, code cache, etc.).

| Pod memory limit | Recommended heap | `heap-headroom-per-node` |
|---|---|---|
| 4 Gi | 3G | 512MB |
| 8 Gi | 6G | 1GB |
| 16 Gi | 12G | 2GB |

`query.max-memory-per-node` should be roughly (heap − headroom − 1 GB OS buffer).

### Multi-environment with Terraform workspaces

Use Terraform workspaces to manage `dev` and `prod` from a single state without duplicating code:

```bash
# Create workspaces
terraform workspace new dev
terraform workspace new prod

# Deploy to dev
terraform workspace select dev
terraform apply -var-file=envs/dev.tfvars

# Deploy to prod
terraform workspace select prod
terraform apply -var-file=envs/prod.tfvars
```

Create `terraform/envs/dev.tfvars` and `terraform/envs/prod.tfvars` with different sizing and namespace values for each environment.

---

## The Batch API

When Trino lists catalogs, schemas, or tables, it needs to filter the results to show only what the current user can access. Without batching, Trino would make one OPA call per resource — O(n) calls for n catalogs.

The batch endpoint collapses this into a single call. OPA receives an array of resources and returns the set of indices that are allowed:

**Request to `/v1/data/trino/batch`:**
```json
{
  "input": {
    "context": {"identity": {"user": "alice"}},
    "action": {
      "operation": "FilterCatalogs",
      "filterResources": [
        {"catalog": {"name": "bi_prod"}},
        {"catalog": {"name": "analytics_prod"}},
        {"catalog": {"name": "internal_secrets"}}
      ]
    }
  }
}
```

**Response:**
```json
{"result": [0, 1]}
```

Indices 0 and 1 (`bi_prod`, `analytics_prod`) are allowed; index 2 (`internal_secrets`) is not.

The `batch` rules in `opa/trino.rego` implement this pattern. Always define both `allow` and `batch` rules — `allow` covers single-resource decisions (e.g., `SELECT`) and `batch` covers filtering (e.g., `SHOW TABLES`).

---

## CI: GitHub Actions & GitLab CI

Both pipelines follow the same two-stage pattern using **Alpine Linux** with manually installed tools (OPA, OpenTofu, kubectl, Helm, AWS CLI) — no pre-built CI actions or special images required.

```
validate  →  deploy (main branch only)
```

| Stage | What runs | When |
|---|---|---|
| `validate` | OPA fmt + check + test, OpenTofu fmt + validate | Every push and pull/merge request |
| `deploy` | Full `tofu apply` to EKS | Push to `main` only, after validate passes |

### File layout

```
.github/
└── workflows/
    └── ci.yml        # GitHub Actions
.gitlab-ci.yml        # GitLab CI
opa/
└── trino_test.rego   # OPA unit tests (run in the validate stage)
```

### Validate stage

Runs inside an `alpine:latest` container. Installs OPA and OpenTofu from their official install scripts, then:

```
opa fmt --fail opa/             # fails if any .rego file is not canonical
opa check opa/                  # syntax + type-check without evaluating
opa test opa/ --verbose         # runs all *_test.rego files

tofu fmt -check -recursive terraform/    # fails if any .tf file is not canonical
tofu -chdir=terraform init -backend=false  # downloads providers, skips remote state
tofu -chdir=terraform validate           # HCL syntax + cross-reference check
```

`-backend=false` means the validate stage needs **no cloud credentials** — it works on any runner or GitHub-hosted machine.

### Deploy stage

Also runs in `alpine:latest`. Installs the full tool chain:

```
apk: bash curl unzip python3 py3-pip openssl
pip: awscli
curl: opentofu, kubectl v1.28.4, helm (get-helm-3 script)
```

Then:

```
helm repo add trino + helm pull trino/trino
aws configure  (credentials from CI secrets)
aws eks update-kubeconfig  →  kubectl cluster-info + get nodes
cd terraform && tofu init -upgrade && tofu apply -auto-approve
```

`tofu apply` deploys the full stack in one command: OPA (ConfigMap + Deployment + Service) and Trino (Helm release). The `configmap-hash` annotation in `opa.tf` ensures a rolling OPA restart whenever the policy changes.

### Required CI secrets / variables

Set these in **GitLab → Settings → CI/CD → Variables** or **GitHub → Settings → Secrets and variables → Actions**:

| Name | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM key with EKS describe + Kubernetes access |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret |
| `AWS_REGION` | AWS region of the EKS cluster (default: `us-east-1`) |
| `EKS_CLUSTER_NAME` | EKS cluster name (default: `my-cluster`) |

The Terraform `terraform.tfvars` secrets (`admin_password`, `internal_communication_shared_secret`, etc.) should be stored as a GitLab/GitHub file secret or injected via a secrets manager and written to `terraform/terraform.tfvars` as a deploy step.

### GitLab-specific: runner tag

The `deploy` job has `tags: [docker]`. Replace `docker` with the tag of your registered GitLab runner. The `validate` job has no tag and runs on any available runner.

### OPA test file (`opa/trino_test.rego`)

`opa test` auto-discovers `*_test.rego` files. The test file covers all three roles (admin, read-only, analyst) and both the single-request `allow` rules and the batch filtering rules. Run locally:

```bash
# No local OPA needed — use Docker
docker run --rm -v $(pwd)/opa:/policies openpolicyagent/opa:latest \
  test /policies --verbose
```

### Running the validate stage locally

```bash
# OPA (fix formatting with: opa fmt -w opa/)
opa fmt --fail opa/
opa check opa/
opa test opa/ --verbose

# OpenTofu (fix formatting with: tofu fmt -recursive terraform/)
tofu fmt -check -recursive terraform/
tofu -chdir=terraform init -backend=false
tofu -chdir=terraform validate
```

---

## Troubleshooting

### Trino exits with "Configuration property 'discovery-server.enabled' was not used"

This property was removed in Trino 434. Remove it from `config.properties`. The correct minimal coordinator config is:

```properties
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery.uri=http://localhost:8080
```

### OPA returns 404 for `/v1/data/trino/allow`

The package declaration must match the URL path. If your file starts with `package trino`, the endpoint is `/v1/data/trino/allow`. Check:
- The `package` line in your `.rego` file.
- The `opa.policy.uri` in `access-control.properties`.

### All queries are denied even for admin

1. Verify OPA loaded the policy: `curl http://localhost:8181/v1/data/trino`
2. Check that `default allow := false` is followed by at least one `allow` rule.
3. Test the rule directly with `curl` (see the example in [Writing Policies](#writing-policies-in-rego)).

### Duplicate package errors in OPA logs

If OPA logs `rego_compile_error: package 'trino' declared multiple times`, you have a `subPath` / symlink issue. Ensure the volume mount uses `subPath: trino.rego` so Kubernetes does not mount the whole ConfigMap directory (which includes `..data/` symlinks).

### Policy change is not picked up

- **Local (Docker Compose):** OPA must be started with `--watch`. Check the `command:` in `docker-compose.yml`.
- **Kubernetes:** After updating the ConfigMap, run `kubectl rollout restart deployment/trino-opa -n trino`. If using Terraform, `terraform apply` handles this automatically via the `configmap-hash` annotation.

### `access-control.name=opa` causes Trino startup failure

The OPA access control plugin is built into Trino since version **435**. If you are running an older version, you will need to add the OPA plugin JAR manually. Check your Trino version: `SELECT version()`.

### Trino says "Access Denied" but OPA says `true`

Trino caches some authorization decisions. If you're testing policy changes and seeing stale behavior, wait a few seconds or restart the Trino session. For high-frequency policy changes during development, set `opa.policy.uri` to include `?decision_id=$(uuid)` to bypass any caching — though this is not recommended in production.
