# Langfuse evaluation

Deployment is gated by a suspended Flux `Kustomization`. Complete prerequisites, then set `spec.suspend: false` in `overlays/fluxcd/kustomizations/langfuse.yaml`.

## External dependencies

Langfuse reuses existing homelab services:

- PostgreSQL: `homelab-db-rw.db.svc.cluster.local:5432`
- ClickHouse: `ck-cluster-clickhouse-headless.clickhouse.svc.cluster.local:8123/9000`
- Redis: `redis-svc.db.svc.cluster.local:6379`, database `1`
- Garage S3: `garage-svc.garage.svc.cluster.local:3900`

## Preparation checklist

### PostgreSQL

Create a `langfuse` role and database in the CloudNativePG cluster. Store its password in Vault as `postgres-password`.

The role must own the database and be allowed to run Langfuse migrations.

### ClickHouse

Create a `langfuse` database and user with permissions to run migrations against cluster `default`. Store its password in Vault as `clickhouse-password`.

Current external ClickHouse is a one-shard, one-replica cluster. `clickhouse.cluster.enabled` remains enabled because `system.clusters` exposes cluster `default`.

### Garage

Create bucket `langfuse` and a dedicated key with read/write/owner access to that bucket. Store credentials in Vault as:

- `s3-access-key-id`
- `s3-secret-access-key`

Event ingestion and batch exports use the internal endpoint. Do not test browser-based media uploads yet: presigned Garage URLs resolve to the internal service. Add an externally reachable Garage S3 endpoint and CORS policy first.

### Vault and ESO

Create KV v2 secret `apps/langfuse` with:

- `postgres-password`
- `clickhouse-password`
- `s3-access-key-id`
- `s3-secret-access-key`
- `salt` — generate with `openssl rand -base64 32`
- `encryption-key` — generate with `openssl rand -hex 32`
- `nextauth-secret` — generate with `openssl rand -base64 32`

`ExternalSecret/langfuse-secrets` copies these values into namespace `langfuse` through `vault-store-apps`.

## Enable deployment

1. Complete dependency setup above.
2. Set `spec.suspend: false` in `overlays/fluxcd/kustomizations/langfuse.yaml`.
3. Merge and reconcile Flux.
4. Watch rollout:

```bash
kubectl get kustomization,helmrelease -n flux-system
kubectl get pods -n langfuse -w
```

5. Access UI without exposing ingress:

```bash
kubectl port-forward -n langfuse svc/langfuse-web 3000:3000
```

Open <http://localhost:3000> and create first account.
