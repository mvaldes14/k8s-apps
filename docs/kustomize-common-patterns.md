# Kustomize common-pattern audit

This audit covers active manifests under `bases/` and `overlays/`. It excludes
`archive/` and CRD definition bundles. Counts describe rendered app resources:
a resource supplied by a base still counts as one overlay instance.

## Findings

| Pattern | Active instances | Finding |
| --- | ---: | --- |
| `ExternalSecret` | 28 | Strongest reuse candidate. All use `Periodic` refresh and `Owner`; 27 use `10m`, 27 use deletion policy `Delete`, and 25 use `vault-store-apps`. Four app areas define more than one secret, so they need local manifests or more careful splitting. |
| Traefik `IngressRoute` | 10 | Six routes, including Atuin, share one route, `websecure`, and `tls: {}`. Other routes have multiple rules/resources or intentionally omit `tls`, so one base does not fit all of them. |
| `PersistentVolumeClaim` | 16 | Fourteen use `nfs-k8s-keep` plus `ReadWriteOnce`, but sizes vary, three app areas need multiple claims, and storage class/access mode are immutable on bound claims. Keep PVCs local. |
| Flux `Kustomization` | 45 | All share interval, prune, and source defaults, but identity, path, timeout, and dependencies are the meaningful fields. Generation could help, but a Kustomize base would mostly replace YAML with patches. |

Deployments, Services, Helm releases, and custom resources were also reviewed.
Their shared fields are Kubernetes conventions rather than stable app-level
configuration; app-specific containers, ports, charts, and CR schemas dominate.
No base was added for them.

## Refactor completed

`overlays/atuin` now consumes both existing reusable bases:

- `bases/external-secret`
- `bases/traefik-route`

The overlay patches only Atuin identity and routing values. Its former local
`ExternalSecret` and `IngressRoute` manifests were removed. `kubectl kustomize`
output before and after this change is byte-for-byte identical, so resource
names, namespace, Vault key/store/policies, host, service, and port are
unchanged.

Atuin was selected as the pilot because it has exactly one conventional secret
and one conventional route, with no exceptional fields. This exercises both
clear bases without a layout migration or changes to app-specific workloads.

## Ranked follow-up candidates

1. **Single-instance `ExternalSecret` overlays.** Migrate incrementally where
   refresh and deletion policies match the base. Handle non-default Vault keys
   with explicit patches. Leave multi-secret areas (`argo`, `db`, `forgejo`,
   and `grafana`) local until each resource can be evaluated independently.
2. **Remaining simple Traefik routes.** `agentgateway`, `td`, `grafana`, and
   `decision-gateway/workload` directly match the base shape. SigNoz has one
   matching route alongside a more complex route and needs a file split first.
3. **Flux `Kustomization` generation.** Consider only with a documented
   generator and validation workflow; do not model these as a shared base.

Not candidates:

- **PVC base:** immutable live fields, varying sizes/classes, and multiple PVCs
  per app make indirection riskier than local manifests.
- **Complex ingress:** `arrs`, `garage`, `home-assistant`, and the SigNoz OTLP
  route intentionally differ in TLS or route structure.
- **Broad directory migration:** existing `overlays/` layout already builds as
  app-level kustomizations; moving files adds churn without deduplicating
  resources.
