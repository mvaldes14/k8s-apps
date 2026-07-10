# Proposed Kustomize Layout

A proposal for restructuring `k8s-apps` so that shared functionality is defined
once and reused, instead of being copy-pasted across ~35 app directories.

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
- Only `arrs/` and `cert-manager/` use kustomize today. `arrs/` is actually a
  good base/overlay example (`arrs/base` + per-app overlays with `namePrefix`
  and patches) — the rest of the repo should look more like it.

---

## 2. Target layout

```
components/                 # reusable kustomize Components (cross-cutting concerns)
  external-secret/          #   Vault-backed ExternalSecret template
    kustomization.yaml
    externalsecret.yaml
  traefik-route/            #   websecure IngressRoute template
    kustomization.yaml
    ingressroute.yaml
  nfs-pvc/                  #   nfs-k8s-keep PVC defaults
    kustomization.yaml
    pvc.yaml

base/                       # shared CLUSTER resources (unchanged): storageclass, crds

apps/
  <app>/
    kustomization.yaml      # namespace: <app>; lists resources + components + patches
    deployment.yaml
    service.yaml
    # no per-file namespace, no standalone external-secrets/ingress/pvc boilerplate

arrs/                       # already base/overlay; keep as the reference implementation
fluxcd/                     # unchanged in this proposal (see section 5)
```

Two reuse mechanisms, used for two different situations:

- **Base + overlay** — for *families of near-identical apps*. `arrs/` is the
  model: one `arrs/base` Deployment/Service, and each app (`sonarr`, `radarr`,
  …) is a thin overlay that patches the image, ports, and volumes. Use this
  when the apps themselves are variations on one another.

- **Components** — for a *cross-cutting concern mixed into otherwise unrelated
  apps*. An `ExternalSecret`, a Traefik route, and an NFS PVC show up in
  `atuin`, `paperless`, `n8n`, `garage`, … which are not variations of each
  other. A [kustomize Component](https://kubectl.docs.kubernetes.io/guides/config_management/components/)
  is the right tool: each app opts in with one line and supplies only the bits
  that differ.

---

## 3. The reusable pieces

### 3.1 Per-app namespace (biggest, cheapest win)

Set the namespace **once** in the app's `kustomization.yaml` and delete it from
every individual resource:

```yaml
# apps/atuin/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: atuin           # <-- rewrites metadata.namespace on every resource below
resources:
  - namespace.yaml         # or generate via a shared component
  - deployment.yaml
  - service.yaml
```

This alone removes the repeated `namespace:` line from ~5 files per app and
ends the inline-vs-separate-vs-missing inconsistency.

### 3.2 `components/external-secret`

The canonical ExternalSecret, with everything that never changes baked in:

```yaml
# components/external-secret/externalsecret.yaml
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
# components/external-secret/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - externalsecret.yaml
```

The only per-app variable is the Vault key `apps/<app>`. Because the app already
sets `namespace: <app>` and the key is always `apps/<namespace>`, an app can
derive it automatically with a `replacements` rule (no hand-editing at all):

```yaml
# apps/atuin/kustomization.yaml (excerpt)
namespace: atuin
components:
  - ../../components/external-secret
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

### 3.3 `components/traefik-route`

```yaml
# components/traefik-route/ingressroute.yaml
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

Per app, patch only the `Host()` and the target service name:

```yaml
# apps/atuin/kustomization.yaml (excerpt)
components:
  - ../../components/traefik-route
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

### 3.4 `components/nfs-pvc`

```yaml
# components/nfs-pvc/pvc.yaml
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

Apps override only name + size via a small patch. Apps with multiple volumes
(e.g. `paperless` has `-media` and `-data`) still declare those PVCs locally —
the component covers the common single-volume case, which is the majority.

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

**After** — app-specific manifests plus opt-in components:

```
apps/atuin/
  kustomization.yaml
  deployment.yaml         # just the Deployment (no Namespace, no namespace: field)
  service.yaml            # just the Service
```

```yaml
# apps/atuin/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: atuin
resources:
  - deployment.yaml
  - service.yaml
components:
  - ../../components/external-secret
  - ../../components/traefik-route
  - ../../components/nfs-pvc
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

The three cross-cutting resources are now defined once in `components/`. When
you need to change the Vault store, the Traefik entrypoint, or the storage
class, you edit one file instead of ~19 / ~7 / ~15.

### Verifying equivalence

The migration is safe to do incrementally because you can prove the rendered
output matches what is deployed today before you merge:

```bash
# render the new layout and diff against the live cluster
kustomize build apps/atuin | kubectl diff -f -

# or compare two renders offline (old dir vs new dir)
kustomize build apps/atuin > /tmp/new.yaml
# (hand-render / kubectl apply --dry-run=client the old atuin/ for comparison)
```

Flux keeps pointing at the same path, so once the diff is empty the switch is a
no-op to the cluster.

---

## 5. The 29 Flux `Kustomization` files (recommendation only)

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
| **Generate per-app Kustomizations** from a shared template | Keeps per-app granularity *and* removes copy-paste | Adds a generation step / component to the repo |

**Recommendation:** the generated-per-app approach is the best long-term
middle ground — it preserves the per-app pruning/health you have now while
killing the duplication. Treat it as a follow-up once the app-manifest refactor
above has landed.

---

## 6. Migration path

Incremental and low-risk — do one app at a time, on a branch, and verify each
with `kustomize build` before merging.

1. **Add `components/`** (`external-secret`, `traefik-route`, `nfs-pvc`) and a
   top-level `apps/` directory. Nothing references them yet, so this is inert.
2. **Pilot 2–3 apps** that exercise all three components. Good candidates:
   - `atuin` — namespace + deployment + service + PVC + ExternalSecret + IngressRoute (full house)
   - `td` — ExternalSecret + IngressRoute, no PVC
   - `paperless` — ExternalSecret + multi-PVC (proves the "local PVC" escape hatch)
3. For each app: move its Deployment/Service into `apps/<app>/`, add the
   `kustomization.yaml`, delete the boilerplate resources, and point the app's
   Flux `Kustomization` `path` at `./apps/<app>`. Run
   `kustomize build apps/<app> | kubectl diff -f -` and confirm an empty diff.
4. **Standardize as you go:** `.yml` → `.yaml`, secret names → `app-secret`,
   namespace via the `namespace:` field.
5. Repeat for the remaining apps. Leave `arrs/` as-is (it already follows the
   pattern) and revisit the Flux consolidation (section 5) at the end.

### Per-app conversion checklist

- [ ] `apps/<app>/kustomization.yaml` with `namespace: <app>`
- [ ] Deployment + Service moved in; `namespace:` fields removed
- [ ] ExternalSecret replaced by the component (+ Vault key via `replacements`)
- [ ] IngressRoute replaced by the component (+ Host/service patch), if any
- [ ] Single PVC replaced by the component (+ size patch); multi-PVC kept local
- [ ] Deployment `secretKeyRef.name` updated to `app-secret`
- [ ] Flux `Kustomization` `path` updated to `./apps/<app>`
- [ ] `kustomize build apps/<app> | kubectl diff -f -` is empty
