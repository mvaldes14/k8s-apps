# k8s-apps

Kubernetes manifests for a k3s homelab cluster (`eva01`–`eva04`), deployed via GitOps with FluxCD.

## Layout

```
bases/            # shared kustomize bases (external-secret, traefik-route, nfs-pvc)
crds/             # raw CRD bundles + cluster-scoped extras, applied out of band
overlays/         # one directory per app — the unit Flux reconciles
  fluxcd/         # Flux itself: sources, Kustomizations, notifications, image automation
  arrs/           # base + per-app overlays (sonarr, radarr, ... ) — the reference pattern
  redpanda/       # split into operator/ and cluster/
  cert-manager/   # chart install + config/ subdir applied after it
archive/          # decommissioned apps, kept for reference — not reconciled
docs/             # design notes (see kustomize-layout.md)
```

Every app under `overlays/` is a kustomization: `namespace:` is set once in
`kustomization.yaml` and the individual manifests carry no `namespace:` field.

## How Flux is wired

`overlays/fluxcd/kustomization.yaml` aggregates four directories, in order:

| Directory | Contents |
| --- | --- |
| `sources/` | `GitRepository` (homelab, bot, td), OCI/Helm sources, the GitHub auth secret |
| `kustomizations/` | one Flux `Kustomization` per app, all pointing at `./overlays/<app>` |
| `notifications/` | Gotify provider (generic webhook) + alert on reconciliation failures |
| `images/` | `ImageRepository` / `ImagePolicy` / `ImageUpdateAutomation` |

Apply it with:

```bash
kubectl apply -k overlays/fluxcd
```

There is no self-managing Kustomization pointing at `./overlays/fluxcd` today —
changes to Flux's own wiring are applied with the command above; everything else
reconciles itself from git.

App Kustomizations follow one shape: `interval: 30m`, `prune: true`,
`sourceRef: homelab-repository`, and a per-app `timeout` (1m–30m). Three use
`dependsOn`: `cert-manager-config-flux` → `cert-manager-flux`,
`redpanda-cluster-flux` → `redpanda-operator-flux`, `event-bus-flux` → `argo-flux`.

### Image automation

`bots`, `blog`, and `td` are updated automatically: an `ImagePolicy` picks the
newest tag and `ImageUpdateAutomation` commits the new digest back to `main`
under `./overlays/<app>` as `fluxcdbot`.

### CRDs

`crds/` is deliberately **not** reconciled by Flux — bundles are a one-time
`kubectl apply` so Flux never fights a chart over CRD ownership, and a 1.4 MB
bundle stays off the reconcile loop:

```bash
kubectl apply -f crds/external-secrets/crds.yaml
```

The `cert-manager`, `cilium`, `clickhouse-operator`, and `opentelemetry-operator`
directories are empty placeholders — those charts install their own CRDs.

Only CRD *definitions* live here. Cilium's `CiliumLoadBalancerIPPool` and
`CiliumL2AnnouncementPolicy` are custom resource *instances*, so they sit in
`overlays/cilium/lb-pool.yaml` and are reconciled by Flux like anything else.

## Applications

### Platform
- **cert-manager** — TLS certificates (+ `config/` for issuers)
- **cilium** — CNI, plus the LB IP pool (`10.14.0.230-240`) and L2 announcement policy
- **external-secrets** — controller + the `vault-store-apps` / `vault-store-core` `ClusterSecretStore`s
- **vault** — secret storage backing every `ExternalSecret`
- **cloudflared** — Cloudflare tunnel ingress
- **fluxcd** — GitOps controllers' own config

### Data & Messaging
- **db** — CloudNativePG cluster, databases, scheduled backups
- **redis** — cache
- **clickhouse** — ClickHouse cluster for SigNoz
- **redpanda** — operator + cluster
- **event-bus** — Argo `Application` pointing at the eventbus repo
- **garage** — S3-compatible object storage

### Observability
- **signoz** — full-stack observability (traces, metrics, logs) + MCP server
- **grafana** — dashboards

### Media
- **arrs** — sonarr, radarr, readarr, bazarr, prowlarr, transmission, flaresolverr, shared ingress
- **paperless** — document management

### Apps & Tools
- **argo** — Argo CD (projects, repositories)
- **atlantis** — Terraform PR automation
- **atuin** — shell history sync
- **authentik** — SSO / identity provider
- **blog** — personal blog
- **bots** — twitch bot
- **cronjobs** — scheduled tasks (meal notifier)
- **excalidraw** — whiteboarding
- **forgejo** — git hosting
- **gotify** — push notifications (also Flux's alert sink)
- **home-assistant** — home automation (`hoa-flux`)
- **n8n** — workflow automation
- **nocodb** — no-code database
- **searxng** — metasearch
- **td** — task manager
- **umami** — web analytics

## Conventions

- **Secrets** come from Vault via `ExternalSecret` — never committed. Most use
  the key `apps/<namespace>` against `vault-store-apps`; `db` uses `core/db`
  against `vault-store-core`.
- **Ingress** is Traefik `IngressRoute` on the `websecure` entrypoint with
  `tls: {}`, hosts under `*.int.mvaldes.dev`.
- **Ingress from the internet** is the cloudflared tunnel (HTTP only — the
  Cloudflare edge will not carry raw TCP). Anything needing a real port, like
  forgejo's SSH, takes a `LoadBalancer` on the cilium pool and is reached over
  the LAN or the tailnet.
- **Storage** is NFS (`nfs-k8s`, `nfs-k8s-keep` for retained data). PVCs stay as
  local per-app manifests — the fields a shared base would centralize are
  immutable on a bound PVC. See `docs/kustomize-layout.md` §3.6.
- **Commits** follow conventional commits.

## Notes

- `bases/` is scaffolding for the refactor described in
  `docs/kustomize-layout.md`; no overlay references it yet. The StorageClass
  definitions in `bases/nfs-pvc/storageclass.yaml` are live in the cluster but
  applied by nothing — they still need a home.
- `overlays/db` and `overlays/redis` have no Flux `Kustomization`; they are
  applied manually.
- `overlays/fluxcd/kustomizations/kustomizations.yaml` is entirely commented-out
  leftovers.

## Validate before pushing

```bash
fd -g 'kustomization.yaml' -x sh -c 'kustomize build "$(dirname {})" >/dev/null || echo "FAIL {}"'
kustomize build overlays/<app> | kubectl diff -f -
```
