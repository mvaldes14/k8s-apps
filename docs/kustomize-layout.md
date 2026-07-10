# Proposed Kustomize Layout

A proposal for restructuring `k8s-apps` so that shared functionality is defined
once in a **`base/`** folder and each app becomes a thin **overlay**, instead of
copy-pasting the same manifests across ~35 app directories.

> **Status:** proposal / design doc. No manifests are changed by this document.
> Migration is meant to happen incrementally, app by app (see
> [Migration path](#migration-path)).

---

## 1. Why change anything?

The repo works, but it has grown by copy-paste. Almost every app is a flat
directory of raw manifests that Flux globs and applies. The same handful of
patterns is repeated verbatim, so a change to any shared convention (the Vault
store name, the Traefik entrypoint, the storage class) means editing dozens of
files by hand.

Concrete duplication in the repo today:

| Pattern | Count | What actually differs between copies |
| --- | ---: | --- |
| `fluxcd/kustomizations/*.yaml` (Flux `Kustomization`) | 29 | `name` and `path` only |
| `ExternalSecret` | 19 | `name`/`namespace` and `key: apps/<app>` only |
| Traefik `IngressRoute` | 7 | the `Host()` match and target service only |
| `PersistentVolumeClaim` | 15 | name and requested size only |

Every `ExternalSecret` uses the same `ClusterSecretStore/vault-store-apps`,
`refreshPolicy: Periodic`, `refreshInterval: 10m`, and
`creationPolicy: Owner`. Every `IngressRoute` uses `websecure` + `tls: {}` +
a single route. Every PVC uses `storageClassName: nfs-k8s-keep` +
`ReadWriteOnce`.

There is also **inconsistency** that a shared layout would fix:

- Namespaces are declared three different ways — inline in `deployment.yaml`
  (`atuin`, `td`, `home-assistant`), in a dedicated file
  (`authentik/namespace.yaml`), or not at all.
- File extensions are mixed: `garage/` and `gotify/` use `.yml`, everything
  else uses `.yaml`.
- Only `arrs/` and `cert-manager/` use kustomize today. `arrs/` is already a
  good **base + overlay** example (`arrs/base` + per-app overlays that reference
  it via `resources:` and patch it) — the rest of the repo should look like it.

---

## 2. Target layout

The repo splits into three layers, applied in order by Flux: a **platform
layer** (`infrastructure/`) for CRDs and operators, shared **bases** (`base/`)
for reusable app resources, and the **apps** themselves (`apps/`) as overlays.
Each app pulls the bases it needs in via `resources:` and patches the few fields
that differ — the same mechanism `arrs/` already uses.

```
infrastructure/             # PLATFORM layer — CRDs + operators (see section 5)
  crds/                     #   raw CRD bundles not owned by a chart
    external-secrets/
    elastic/
    traefik/
    kustomization.yaml
  controllers/              #   operators/controllers, installed via Flux HelmReleases
    external-secrets/       #     (moved out of the flat ./external-secrets dir)
    cert-manager/
    cilium/
    vault/
    ...

base/                       # shared, reusable APP resources
  storageclass.yaml         #   (existing) cluster StorageClass
  external-secret/          #   reusable Vault-backed ExternalSecret base
    kustomization.yaml
    externalsecret.yaml
  traefik-route/            #   reusable websecure IngressRoute base
    kustomization.yaml
    ingressroute.yaml
  nfs-pvc/                  #   reusable nfs-k8s-keep PVC base
    kustomization.yaml
    pvc.yaml

apps/
  <app>/                    # overlay: references the bases it needs + its own workload
    kustomization.yaml      #   namespace: <app>; resources: [base refs + deployment/service]; patches
    deployment.yaml
    service.yaml
    # no per-file namespace; no standalone external-secret/ingress/pvc boilerplate

arrs/                       # already base/overlay; keep as the reference implementation
fluxcd/                     # Flux Kustomizations + sources (see section 6)
```

**One mechanism everywhere: base + overlay.**

- A **base** is a self-contained, buildable kustomization — a directory with its
  own `kustomization.yaml` listing one canonical resource with all the
  never-changes fields baked in. You can `kustomize build base/external-secret`
  on its own.
- An **overlay** (each app) lists those bases under `resources:` alongside its
  own `deployment.yaml`/`service.yaml`, sets `namespace: <app>` once, and patches
  only the handful of fields that vary. Each overlay gets its own independent
  copy of the base, so there are no cross-app collisions.

This keeps the repo on a single, familiar pattern (the one `arrs/` already
demonstrates) rather than mixing bases and components.

---

## 3. The reusable bases

### 3.1 Per-app namespace (biggest, cheapest win)

Set the namespace **once** in the app overlay and delete it from every
individual resource — it also propagates to the resources pulled in from the
bases:

```yaml
# apps/atuin/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: atuin           # <-- rewrites metadata.namespace on every resource, base refs included
resources:
  - namespace.yaml         # the Namespace object itself
  - deployment.yaml
  - service.yaml
```

This alone removes the repeated `namespace:` line from ~5 files per app and
ends the inline-vs-separate-vs-missing inconsistency.

### 3.2 `base/external-secret`

The canonical ExternalSecret, with everything that never changes baked in:

```yaml
# base/external-secret/externalsecret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-store-apps
  refreshPolicy: Periodic
  refreshInterval: 10m
  dataFrom:
    - extract:
        key: apps/PLACEHOLDER      # overridden per app
  target:
    name: app-secret
    creationPolicy: Owner
    deletionPolicy: Delete
```

```yaml
# base/external-secret/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - externalsecret.yaml
```

The only per-app variable is the Vault key `apps/<app>`. Because the overlay
already sets `namespace: <app>` and the key is always `apps/<namespace>`, an app
can derive it automatically with a `replacements` rule (no hand-editing at all):

```yaml
# apps/atuin/kustomization.yaml (excerpt)
namespace: atuin
resources:
  - ../../base/external-secret
replacements:
  - source: { kind: ExternalSecret, fieldPath: metadata.namespace }
    targets:
      - select: { kind: ExternalSecret }
        fieldPaths: [ spec.dataFrom.0.extract.key ]
        options: { delimiter: /, index: 1 }   # apps/<namespace>
```

If the `replacements` indirection feels like too much magic, the plain
alternative is a 4-line patch per app setting the key — still far less than the
18-line standalone file it replaces.

> Note: the current secret **names** vary (`atuin-secrets`, `td-secret`,
> `n8n-secret`, `paperless-secret`). Standardizing on `app-secret` is part of
> the migration; each app's Deployment `secretKeyRef.name` is updated to match
> when it is converted. See the migration checklist.

### 3.3 `base/traefik-route`

```yaml
# base/traefik-route/ingressroute.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-ingressroute
spec:
  entryPoints: [ websecure ]
  tls: {}
  routes:
    - kind: Rule
      match: Host(`PLACEHOLDER`)
      services:
        - name: app-svc
          port: 80
```

```yaml
# base/traefik-route/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ingressroute.yaml
```

Per app, patch only the `Host()` and the target service name:

```yaml
# apps/atuin/kustomization.yaml (excerpt)
resources:
  - ../../base/traefik-route
patches:
  - target: { kind: IngressRoute }
    patch: |-
      - op: replace
        path: /spec/routes/0/match
        value: Host(`atuin.int.mvaldes.dev`)
      - op: replace
        path: /spec/routes/0/services/0/name
        value: atuin-svc
```

### 3.4 `base/nfs-pvc`

```yaml
# base/nfs-pvc/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-pvc
spec:
  storageClassName: nfs-k8s-keep
  accessModes: [ ReadWriteOnce ]
  resources:
    requests:
      storage: 1Gi        # overridden per app
```

```yaml
# base/nfs-pvc/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
```

Apps override only name + size via a small patch. Apps with multiple volumes
(e.g. `paperless` has `-media` and `-data`) still declare those PVCs locally —
the base covers the common single-volume case, which is the majority.

---

## 4. Worked example: `atuin` before / after

**Before** — six standalone files, namespace repeated in each, ~110 lines total:

```
atuin/
  deployment.yaml         # Namespace + Deployment, namespace: atuin inline
  service.yaml            # namespace: atuin
  pvc.yaml                # namespace: atuin, nfs-k8s-keep, ReadWriteOnce
  external-secrets.yaml   # 18 lines, only "apps/atuin" is app-specific
  ingress.yaml            # websecure + tls + one host route
```

**After** — app-specific manifests plus the shared bases pulled in as
`resources:`:

```
apps/atuin/
  kustomization.yaml
  namespace.yaml          # the Namespace object
  deployment.yaml         # just the Deployment (no Namespace, no namespace: field)
  service.yaml            # just the Service
```

```yaml
# apps/atuin/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: atuin
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - ../../base/external-secret
  - ../../base/traefik-route
  - ../../base/nfs-pvc
replacements:
  - source: { kind: ExternalSecret, fieldPath: metadata.namespace }
    targets:
      - select: { kind: ExternalSecret }
        fieldPaths: [ spec.dataFrom.0.extract.key ]
        options: { delimiter: /, index: 1 }
patches:
  - target: { kind: IngressRoute }
    patch: |-
      - op: replace
        path: /spec/routes/0/match
        value: Host(`atuin.int.mvaldes.dev`)
      - op: replace
        path: /spec/routes/0/services/0/name
        value: atuin-svc
  - target: { kind: PersistentVolumeClaim }
    patch: |-
      - op: replace
        path: /spec/resources/requests/storage
        value: 100Mi
```

The three cross-cutting resources are now defined once under `base/`. When you
need to change the Vault store, the Traefik entrypoint, or the storage class,
you edit one file instead of ~19 / ~7 / ~15.

### Verifying equivalence

The migration is safe to do incrementally because you can prove the rendered
output matches what is deployed today before you merge:

```bash
# render the new overlay and diff against the live cluster
kustomize build apps/atuin | kubectl diff -f -

# or render offline to eyeball the output
kustomize build apps/atuin
```

Flux keeps pointing at the same path, so once the diff is empty the switch is a
no-op to the cluster.

---

## 5. CRDs & operators (the platform layer)

### What's there today

Operators are **already in GitOps** — they're Flux `HelmRelease`s — but the
manifests are scattered inside the flat app directories and mix concerns.
`external-secrets/`, `cert-manager/`, `cilium/`, `vault/`, `grafana/`,
`signoz/`, `atlantis/`, and `argo/` each bundle their own `HelmRepository` +
`HelmRelease` (+ `Namespace`) alongside no clear ordering.

CRDs are the weak spot:

- `base/crds/` holds two large **raw CRD bundles** (`external-secrets.yaml`
  ~1.4 MB, `elastic-crds.yaml` ~0.5 MB).
- The Flux `Kustomization` `crds-flux` points at **`path: "./crds"` — a
  directory that does not exist** (the bundles live in `base/crds/`). So that
  reconciler applies nothing, which is why CRDs ended up installed by hand.
- Traefik's CRDs (`IngressRoute`, used by 7 apps) aren't in the repo at all —
  they came in with the cluster/Traefik install, so they're not reproducible
  either.

### Proposed platform layer

Give CRDs and operators a dedicated home, separate from workloads, applied
**before** anything that depends on them:

```
infrastructure/
  crds/                     # raw CRD bundles that no chart installs for us
    external-secrets/       #   (moved from base/crds/external-secrets.yaml)
    elastic/                #   (moved from base/crds/elastic-crds.yaml)
    traefik/                #   ADD Traefik CRDs so IngressRoute is reproducible
    kustomization.yaml      #   lists the three bundles
  controllers/              # operators, each its own HelmRepository + HelmRelease
    external-secrets/
    cert-manager/
    cilium/
    vault/
    ...
```

Guidelines:

- **Let charts own their CRDs where they can.** `cert-manager` (`crds:` in its
  values) and the `external-secrets` chart can both install their own CRDs. If
  you enable that, the giant `base/crds/external-secrets.yaml` bundle becomes
  redundant and can be deleted — only keep raw bundles under
  `infrastructure/crds/` for CRDs **no chart installs** (e.g. Traefik, ECK/
  elastic if nothing manages them).
- **One operator per directory**, moved out of the workload dirs. The workload
  that *uses* an operator (e.g. the `ExternalSecret`s, the `ClusterSecretStore`)
  stays in `apps/` / `base/`; only the controller install moves to
  `infrastructure/controllers/`.

### Ordering with Flux `dependsOn`

Replace the dangling `crds-flux` with a proper dependency chain so a fresh
cluster converges in the right order without manual steps:

```yaml
# crds must exist before controllers reconcile
# infrastructure-crds (path ./infrastructure/crds)
#        ▼ dependsOn
# infrastructure-controllers (path ./infrastructure/controllers)
#        ▼ dependsOn
# apps (the per-app Kustomizations)
```

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-controllers
  namespace: flux-system
spec:
  dependsOn:
    - name: infrastructure-crds     # <-- wait for CRDs first
  interval: 10m
  sourceRef: { kind: GitRepository, name: homelab-repository }
  path: "./infrastructure/controllers"
  prune: true
  wait: true
```

App-level Kustomizations then `dependsOn: [{ name: infrastructure-controllers }]`.
This is what fixes "I installed most of those manually": the CRDs and operators
become an ordered, reproducible part of the GitOps flow.

---

## 6. The 29 Flux `Kustomization` files (recommendation only)

`fluxcd/kustomizations/` holds 29 files that are identical apart from `name`
and `path`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: atuin-flux
  namespace: flux-system
spec:
  interval: 10m
  sourceRef: { kind: GitRepository, name: homelab-repository }
  path: "./atuin"
  prune: true
  timeout: 5m
```

This is the single largest source of boilerplate, but consolidating it changes
reconciliation behavior, so it is **out of scope for this pass** — documented
here as options to decide separately:

| Option | Pros | Cons |
| --- | --- | --- |
| **Keep per-app** (status quo) | Max granularity: independent prune, health, and `dependsOn` per app; smallest blast radius | 29 files of copy-paste |
| **Group into a few Kustomizations** (`infra` / `apps` / `media`) | Far less boilerplate | Coarser pruning + a failure in one app can stall the group's reconcile |
| **Generate per-app Kustomizations** from a shared template | Keeps per-app granularity *and* removes copy-paste | Adds a generation step to the repo |

**Recommendation:** the generated-per-app approach is the best long-term
middle ground — it preserves the per-app pruning/health you have now while
killing the duplication. Treat it as a follow-up once the app-manifest refactor
above has landed.

---

## 7. Migration path

Incremental and low-risk — do one app at a time, on a branch, and verify each
with `kustomize build` before merging.

**Platform layer first (fixes the manual-install problem):**

1. **Create `infrastructure/crds/`** and move the `base/crds/` bundles into it
   (`external-secrets/`, `elastic/`), add `traefik/` CRDs, and give it a
   `kustomization.yaml`. Repoint the Flux `crds-flux` Kustomization at
   `./infrastructure/crds` (fixing the dangling `./crds` path) — or rename it to
   `infrastructure-crds`.
2. **Create `infrastructure/controllers/`** and move each operator's
   `HelmRepository`+`HelmRelease` there (`external-secrets`, `cert-manager`,
   `cilium`, `vault`, …). Add `dependsOn: [infrastructure-crds]` and
   `dependsOn: [infrastructure-controllers]` on the app Kustomizations so a
   fresh cluster orders itself.
3. Where a chart can install its own CRDs (cert-manager, external-secrets),
   enable that and delete the corresponding raw bundle.

**Then the app refactor:**

4. **Add the bases** under `base/` (`external-secret`, `traefik-route`,
   `nfs-pvc`) and a top-level `apps/` directory. Nothing references them yet, so
   this is inert.
5. **Pilot 2–3 apps** that exercise all three bases. Good candidates:
   - `atuin` — namespace + deployment + service + PVC + ExternalSecret + IngressRoute (full house)
   - `td` — ExternalSecret + IngressRoute, no PVC
   - `paperless` — ExternalSecret + multi-PVC (proves the "local PVC" escape hatch)
6. For each app: move its Deployment/Service into `apps/<app>/`, add the
   overlay `kustomization.yaml` referencing the bases, delete the boilerplate
   resources, and point the app's Flux `Kustomization` `path` at `./apps/<app>`.
   Run `kustomize build apps/<app> | kubectl diff -f -` and confirm an empty diff.
7. **Standardize as you go:** `.yml` → `.yaml`, secret names → `app-secret`,
   namespace via the `namespace:` field.
8. Repeat for the remaining apps. Leave `arrs/` as-is (it already follows the
   pattern) and revisit the Flux consolidation (section 6) at the end.

### Per-app conversion checklist

- [ ] `apps/<app>/kustomization.yaml` with `namespace: <app>`
- [ ] Deployment + Service moved in; `namespace:` fields removed
- [ ] ExternalSecret replaced by `../../base/external-secret` (+ Vault key via `replacements`)
- [ ] IngressRoute replaced by `../../base/traefik-route` (+ Host/service patch), if any
- [ ] Single PVC replaced by `../../base/nfs-pvc` (+ size patch); multi-PVC kept local
- [ ] Deployment `secretKeyRef.name` updated to `app-secret`
- [ ] Flux `Kustomization` `path` updated to `./apps/<app>`
- [ ] `kustomize build apps/<app> | kubectl diff -f -` is empty
