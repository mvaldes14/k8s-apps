# Proposed Kustomize Layout

A proposal for restructuring `k8s-apps` so that shared functionality is defined
once in a **`base/`** folder and each app becomes a thin **overlay**, instead of
copy-pasting the same manifests across ~35 app directories.

> **Status:** proposal / design doc. No manifests are changed by this document.
> Migration is meant to happen incrementally, app by app (see
> [Migration path](#7-migration-path)).
>
> **Revised** after a first migration attempt. The `replacements` rule in 3.4 and
> the overlay in section 4 were verified with `kustomize build` — the overlay
> renders byte-identical to the current flat manifests. A proposed `nfs-pvc` base
> was rejected on review; 3.1 records the criteria that killed it and 3.6 the
> reasoning, so the same case doesn't get re-litigated later.

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
| Traefik `IngressRoute` | 7 | the `Host()` match, target service, and port |
| `PersistentVolumeClaim` | 15 | name, size, and sometimes class/access mode |

Every `ExternalSecret` uses the same `ClusterSecretStore/vault-store-apps`,
`refreshPolicy: Periodic`, `refreshInterval: 10m`, and
`creationPolicy: Owner`. Every `IngressRoute` uses `websecure` + `tls: {}`.

Not all duplication is worth extracting, though — see
[What belongs in a base](#3-what-belongs-in-a-base) before assuming a repeated
pattern should become one. PVCs look like an obvious candidate and turn out not
to be.

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
  storage/                  #   cluster StorageClasses (nfs-k8s, nfs-k8s-keep)
  secretstores/             #   ClusterSecretStores (vault-store-apps, vault-store-core)

base/                       # shared, reusable APP resources
  external-secret/          #   reusable Vault-backed ExternalSecret base
    kustomization.yaml
    externalsecret.yaml
  traefik-route/            #   reusable websecure IngressRoute base
    kustomization.yaml
    ingressroute.yaml

apps/
  <app>/                    # overlay: references the bases it needs + its own workload
    kustomization.yaml      #   namespace: <app>; resources: [base refs + own manifests]; patches
    deployment.yaml
    service.yaml
    pvc.yaml                #   stays local — see section 3.4
    # no per-file namespace; no standalone external-secret/ingress boilerplate

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

## 3. What belongs in a base

### 3.1 The four tests

Repetition alone does not justify a base. A base pays for itself only when the
fields it centralizes are ones you will actually edit later, in one place, and
have applied. Run a candidate through all four:

1. **Is the shared config actually shared?** Count how many consumers deviate. If
   a meaningful fraction override the "defaults", the base becomes a base plus a
   pile of patches undoing it.
2. **Are the centralized fields mutable in place?** This is the test that gets
   skipped. If a field is immutable on a live object, "edit one file instead of
   fifteen" is not a thing you can do — the only path is delete and recreate,
   which a base does not help with and may make more tempting than it should be.
3. **Is the patch smaller than the file it replaces?** A base that saves four
   lines of YAML and costs eight lines of `patches:` is a net loss in both size
   and readability.
4. **Does each app need exactly one?** Two copies of the same base in one overlay
   is a duplicate-resource-ID error. Resources that legitimately appear more than
   once per app need a local manifest or a per-instance base directory.

One hard rule on top of the four: **cluster-scoped resources never go in an app
base.** `StorageClass`, `ClusterSecretStore`, and CRDs pulled into a per-app
overlay would be emitted once per app, and with `prune: true` on every app's Flux
`Kustomization` those N copies fight over ownership of one cluster object. They
belong in the platform layer (section 5), applied exactly once.

### 3.2 Scorecard for this repo

| Candidate | Shared? | Mutable? | Patch < file? | One per app? | Verdict |
| --- | --- | --- | --- | --- | --- |
| `ExternalSecret` | yes (19/19 same store + policies) | yes | yes (18-line file → ~4-line patch) | yes | **base** |
| Traefik `IngressRoute` | mostly (`websecure` + `tls: {}` universal) | yes | yes | mostly | **base**, with an escape hatch |
| `PersistentVolumeClaim` | no (3/11 deviate) | **no** | no | no (paperless has 2) | **keep local** — see 3.5 |
| `Namespace` | n/a | n/a | n/a | yes | use the `namespace:` field, not a base |
| `Deployment` / `Service` | nothing meaningful in common | — | — | — | app-specific, stays local |
| Flux `Kustomization` | yes (29 identical but `name`/`path`) | yes | no — nothing left to patch | yes | **generate**, not a base (section 6) |

That last row is worth internalizing: when the *only* differing fields are
identity fields, a base leaves you patching name and path for every consumer,
which is the same edit you were trying to avoid. Templating/generation is the
right tool there, not kustomize inheritance.

### 3.3 Per-app namespace (biggest, cheapest win)

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

### 3.4 `base/external-secret`

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

The only per-app variable is the Vault key. For most apps the key is exactly
`apps/<namespace>`, and since the overlay already sets `namespace: <app>` it can
be derived automatically with a `replacements` rule (no hand-editing at all):

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

**The rule does not cover every app.** Four apps use a key that is not
`apps/<namespace>`, and one also uses a different store. These take an explicit
patch instead of the `replacements` rule:

| App | Vault key | Note |
| --- | --- | --- |
| `db` | `core/db` | also needs `secretStoreRef.name: vault-store-core` |
| `garage` | `apps/s3` | |
| `signoz` | `apps/signoz-mcp` | |
| `fluxcd` | `apps/gotify` | notification token, lives in `flux-system` |

> **Keep the existing secret names.** The current names vary (`atuin-secrets`,
> `td-secret`, `n8n-secret`, `paperless-secret`). It is tempting to standardize
> on the base's `app-secret`, but renaming buys nothing and forces a matching
> edit to every Deployment's `secretKeyRef.name` — churn with a real chance of
> missing one. Patch `metadata.name` and `spec.target.name` back to the existing
> value in each overlay; the rendered output then matches the cluster exactly.

### 3.5 `base/traefik-route`

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

Per app, patch the name, the `Host()`, and the target service + port. Target the
patch by the base's resource name, not by `kind` alone, so it cannot accidentally
match a second IngressRoute in the same overlay:

```yaml
# apps/atuin/kustomization.yaml (excerpt)
resources:
  - ../../base/traefik-route
patches:
  - target: { kind: IngressRoute, name: app-ingressroute }
    patch: |-
      - op: replace
        path: /metadata/name
        value: atuin-ingressroute
      - op: replace
        path: /spec/routes/0/match
        value: Host(`atuin.int.mvaldes.dev`)
      - op: replace
        path: /spec/routes/0/services/0/name
        value: atuin-svc
      - op: replace
        path: /spec/routes/0/services/0/port
        value: 80
```

**Don't drop the port op**, even though the base already says `80`. Ports vary
across the repo — 80, 3900, 3909, 4318, 8000 — so the base's value is a default
that happens to be common, not a shared convention. Making the patch explicit for
every app means the overlay is the single place you look for a route's target.

**Escape hatch:** `garage` and `signoz` each expose multiple routes/IngressRoutes.
Referencing this base twice in one overlay is a duplicate-resource-ID error, so
those apps keep a local `ingress.yaml` — the same treatment PVCs get in 3.6. Test
4 in 3.1 is the reason.

### 3.6 Why PVCs stay local (a rejected base)

An `nfs-pvc` base looks like the most obvious win in the repo — 15 PVCs, and only
name and size appear to differ. It fails three of the four tests in 3.1, and it is
worth writing down why, because the same reasoning applies to any storage-shaped
resource added later.

**Test 2 is the fatal one: every field the base would centralize is immutable on
a bound PVC.**

| Field | Editable in place? |
| --- | --- |
| `storageClassName` | no — immutable |
| `accessModes` | no — immutable |
| `resources.requests.storage` | only with `allowVolumeExpansion`, which neither `nfs-k8s` nor `nfs-k8s-keep` sets — so no |

The entire pitch for a base is "change the storage class in one file instead of
fifteen." You cannot change it at all on existing PVCs. The only route is delete
and recreate, and because both storage classes provision with
`subDir: ${pvc.metadata.namespace}-${pvc.metadata.name}`, a recreated PVC lands on
a *different* NFS subdirectory and the app comes up with an empty volume —
`reclaimPolicy: Retain` preserves the old data but nothing points at it any more.
A base centralizes three fields you can never edit, while making a destructive
operation look like a config change.

**Test 1: the defaults aren't shared.** Three of eleven deviate.

```
redis-pvc            nfs-k8s        ReadWriteOnce   1Gi    ← different class
postgres-pvc         nfs-k8s-keep   ReadWriteMany   5Gi    ← different access mode
paperless-media-pvc  nfs-k8s-keep   ReadWriteOnce   5Gi
paperless-data-pvc   nfs-k8s-keep   ReadWriteOnce   5Gi    ← two PVCs, one app
```

All eleven sizes differ, so size is per-app no matter what the base says.

**Test 3: the patch is bigger than the file.** A local PVC manifest is ~13 lines.
Base plus a name/size patch is ~8 lines of `patches:` in `kustomization.yaml`
*plus* the base files, and it splits one resource across two directories.

**Test 4: `paperless` needs two.**

So each app keeps its own `pvc.yaml` as a plain local resource:

```yaml
# apps/atuin/kustomization.yaml (excerpt)
resources:
  - pvc.yaml        # local, unchanged, no patch
```

The only change during migration is deleting the `namespace:` line from
`pvc.yaml` and letting the overlay's `namespace:` field set it.

The two `StorageClass` definitions are still shared cluster config — they just
belong in the platform layer (`infrastructure/storage/`, section 5), applied once,
not pulled into per-app overlays. Same for the two `ClusterSecretStore`s. See the
cluster-scoped rule in 3.1.

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

**After** — app-specific manifests, plus the two bases pulled in as `resources:`:

```
apps/atuin/
  kustomization.yaml
  namespace.yaml          # the Namespace object
  deployment.yaml         # just the Deployment (no Namespace, no namespace: field)
  service.yaml            # just the Service
  pvc.yaml                # stays local (3.6), only the namespace: line removed
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
  - pvc.yaml
  - ../../base/external-secret
  - ../../base/traefik-route
replacements:
  - source: { kind: ExternalSecret, fieldPath: metadata.namespace }
    targets:
      - select: { kind: ExternalSecret }
        fieldPaths: [ spec.dataFrom.0.extract.key ]
        options: { delimiter: /, index: 1 }
patches:
  - target: { kind: ExternalSecret, name: app-secret }
    patch: |-
      - op: replace
        path: /metadata/name
        value: atuin-secrets
      - op: replace
        path: /spec/target/name          # note: /spec/target, not /target
        value: atuin-secrets
  - target: { kind: IngressRoute, name: app-ingressroute }
    patch: |-
      - op: replace
        path: /metadata/name
        value: atuin-ingressroute
      - op: replace
        path: /spec/routes/0/match
        value: Host(`atuin.int.mvaldes.dev`)
      - op: replace
        path: /spec/routes/0/services/0/name
        value: atuin-svc
      - op: replace
        path: /spec/routes/0/services/0/port
        value: 80
```

Two cross-cutting resources are now defined once under `base/`. When you need to
change the Vault store, the refresh policy, or the Traefik entrypoint, you edit
one file instead of ~19 / ~7.

Two things to get right, both of which the first migration attempt got wrong:

- **Patch by the base's resource name** (`name: app-secret`), not by `kind:`
  alone. A bare `kind:` target silently widens if the overlay ever gains a second
  resource of that kind — which is exactly what happens with a local `pvc.yaml`
  alongside a base PVC.
- **A patch is not a manifest.** Dropping the old `external-secrets.yaml` into
  `patches:` unchanged does not work: strategic-merge matches on GVK **and name**,
  so a patch named `atuin-secrets` finds no target in a base that emits
  `app-secret`, and the build fails with `failed to find unique target for patch`.
  Either patch by the base name and rename inside the patch (as above), or delete
  the old file.

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

> **An empty diff is the requirement, not a nice-to-have.** "No-op" only holds if
> every resource keeps its current name. Renaming anything under `prune: true`
> means Flux deletes the old object and creates the new one — harmless for an
> ExternalSecret, destructive for a PVC (see 3.6). If `kubectl diff` shows a
> resource being added *and* another removed, you renamed something; patch the
> name back rather than accepting the churn.

Add a CI check that this holds for the whole repo, not just the app you are
converting:

```bash
# fail the build if any kustomization stops rendering
fd -g 'kustomization.yaml' -x sh -c 'kustomize build "$(dirname {})" >/dev/null || echo "FAIL {}"'
```

---

## 5. CRDs & operators (the platform layer)

### What's there today

Operators are **already in GitOps** — they're Flux `HelmRelease`s — but the
manifests are scattered inside the flat app directories and mix concerns.
`external-secrets/`, `cert-manager/`, `cilium/`, `vault/`, `grafana/`,
`signoz/`, `atlantis/`, and `argo/` each bundle their own `HelmRepository` +
`HelmRelease` (+ `Namespace`) alongside no clear ordering.

CRDs are the weak spot:

- A large **raw CRD bundle** sits at `crds/external-secrets.yaml` (~1.4 MB), with
  an elastic bundle (~0.5 MB) in the same shape.
- `crds-flux` points at `path: "./crds"`. That directory exists now, and since
  Flux generates a `kustomization.yaml` when one is absent it will apply — but
  `timeout: 1m` is tight for a bundle this size, and if the external-secrets chart
  is set to install its own CRDs you end up with two owners for the same objects.
  This path was dangling for a long time, which is why CRDs ended up installed by
  hand in the first place.
- Traefik's CRDs (`IngressRoute`, used by 7 apps) aren't in the repo at all —
  they came in with the cluster/Traefik install, so they're not reproducible
  either.

Cluster-scoped config is in the same shape. These are live in the cluster but are
currently applied by nothing — they need a home in this layer:

| Resource | Where it sits now |
| --- | --- |
| `StorageClass` `nfs-k8s`, `nfs-k8s-keep` | a file under `base/`, in no `kustomization.yaml` |
| `ClusterSecretStore` `vault-store-apps`, `vault-store-core` | same |
| external-secrets `HelmRepository` + `HelmRelease` | same — the controller install itself |

None of these can live in an app base (see the cluster-scoped rule in 3.1): a
per-app overlay would emit N copies of one cluster object, and with `prune: true`
on every app's Flux `Kustomization` those copies fight over ownership.

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
    external-secrets/       #   (moved from base/external-secret/external-secrets.yaml)
    cert-manager/
    cilium/
    vault/
    ...
  storage/                  # StorageClasses — cluster-scoped, applied once
    storageclass.yaml       #   (moved from base/nfs-pvc/storageclass.yaml)
  secretstores/             # ClusterSecretStores — cluster-scoped, applied once
    secretstore.yaml        #   (moved from base/external-secret/secretstore.yaml)
```

Guidelines:

- **Let charts own their CRDs where they can.** `cert-manager` (`crds:` in its
  values) and the `external-secrets` chart can both install their own CRDs. If
  you enable that, the giant `base/crds/external-secrets.yaml` bundle becomes
  redundant and can be deleted — only keep raw bundles under
  `infrastructure/crds/` for CRDs **no chart installs** (e.g. Traefik, ECK/
  elastic if nothing manages them).
- **One operator per directory**, moved out of the workload dirs. Per-app
  workloads that *use* an operator (the `ExternalSecret`s) stay in `apps/` /
  `base/`; the controller install *and* its cluster-scoped config (the
  `ClusterSecretStore`s, the `StorageClass`es) move to `infrastructure/`.

### Ordering with Flux `dependsOn`

Replace the dangling `crds-flux` with a proper dependency chain so a fresh
cluster converges in the right order without manual steps:

```yaml
# crds must exist before controllers reconcile
# infrastructure-crds (path ./infrastructure/crds)
#        ▼ dependsOn
# infrastructure-controllers (path ./infrastructure/controllers)
#        ▼ dependsOn
# infrastructure-config (./infrastructure/storage, ./infrastructure/secretstores)
#        ▼ dependsOn                 a ClusterSecretStore needs the ESO CRDs
# apps (the per-app Kustomizations)  an ExternalSecret needs the store
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

1. **Create `infrastructure/crds/`** and move the raw bundles into it
   (`external-secrets/`, `elastic/`), add `traefik/` CRDs, and give it an explicit
   `kustomization.yaml` rather than relying on Flux's generated one. Repoint
   `crds-flux` at `./infrastructure/crds`, rename it to `infrastructure-crds`, and
   raise `timeout` above `1m` for the large bundles.
2. **Create `infrastructure/controllers/`** and move each operator's
   `HelmRepository`+`HelmRelease` there (`external-secrets`, `cert-manager`,
   `cilium`, `vault`, …). Add `dependsOn: [infrastructure-crds]` and
   `dependsOn: [infrastructure-controllers]` on the app Kustomizations so a
   fresh cluster orders itself.
3. Where a chart can install its own CRDs (cert-manager, external-secrets),
   enable that and delete the corresponding raw bundle — in the same commit, so
   you never have both.
4. **Move the orphaned cluster-scoped config** into
   `infrastructure/storage/` and `infrastructure/secretstores/`, with Flux
   Kustomizations for each. Until this lands, the StorageClasses and
   ClusterSecretStores are live but unmanaged.

**Then the app refactor:**

5. **Add the bases** under `base/` (`external-secret`, `traefik-route` — that's
   all of them, see 3.2) and a top-level `apps/` directory. Nothing references
   them yet, so this is inert.
6. **Pilot 2–3 apps** that exercise both bases and the escape hatches:
   - `atuin` — namespace + deployment + service + local PVC + ExternalSecret + IngressRoute (full house)
   - `td` — ExternalSecret + IngressRoute, no PVC
   - `db` — ExternalSecret with a non-derivable key *and* a different store
     (`core/db` / `vault-store-core`), which proves the explicit-patch path in 3.4
7. For each app: move its manifests into `apps/<app>/`, add the overlay
   `kustomization.yaml` referencing the bases, delete the boilerplate resources
   that the bases now provide, and point the app's Flux `Kustomization` `path` at
   `./apps/<app>`. Run `kustomize build apps/<app> | kubectl diff -f -` and
   confirm an empty diff.
8. **Standardize as you go:** `.yml` → `.yaml`, namespace via the `namespace:`
   field. Do *not* standardize resource names — see the empty-diff note in
   section 4.
9. Repeat for the remaining apps. Leave `arrs/` as-is (it already follows the
   pattern) and revisit the Flux consolidation (section 6) at the end.

> **Moving a directory and repointing its Flux `Kustomization` must be the same
> commit.** All 29 paths in `fluxcd/kustomizations/` are relative to the repo root
> (`path: "./atuin"`), so a move without the path edit leaves every affected
> reconciler failing its build. Nothing gets pruned — a failed build produces no
> inventory — but the apps freeze, unreconciled, until it's fixed. The same
> applies to `fluxcd/` itself: whatever Kustomization points at
> `./fluxcd/kustomizations` is created by `flux bootstrap` and lives outside this
> repo, so check it *before* moving that directory, or you lose the ability to fix
> the other 29 via GitOps.

### Per-app conversion checklist

- [ ] `apps/<app>/kustomization.yaml` with `namespace: <app>`
- [ ] Own manifests moved in; per-resource `namespace:` fields removed
- [ ] ExternalSecret replaced by `../../base/external-secret`, with:
  - [ ] Vault key via the `replacements` rule — or an explicit patch if the app is one of the four exceptions in 3.4
  - [ ] `metadata.name` and `spec.target.name` patched back to the existing secret name
- [ ] IngressRoute replaced by `../../base/traefik-route` (+ name, Host, service, **port** patch), if the app has exactly one
- [ ] PVCs left as local manifests — no base, no rename (3.6)
- [ ] Every patch targets `{ kind: X, name: <base name> }`, not `kind:` alone
- [ ] Old boilerplate files deleted, not repurposed as patches
- [ ] Flux `Kustomization` `path` updated to `./apps/<app>` **in the same commit as the move**
- [ ] `kustomize build apps/<app>` exits 0
- [ ] `kustomize build apps/<app> | kubectl diff -f -` is empty — no adds paired with removes
