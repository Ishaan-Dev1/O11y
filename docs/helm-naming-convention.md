# Helm Naming Conventions

How Kubernetes resource names are derived from a Helm chart — and why the
"field is immutable" / "updates to statefulset spec ... are forbidden" errors
happen (and how to avoid them on a fresh deployment).

---

## 1. Where names come from — 3 inputs

| Input | What it is | Where it comes from |
|---|---|---|
| **Release name** | `helm install <name> .` | CLI → `.Release.Name` |
| **Chart name** | `.Chart.Name` | `name:` in `Chart.yaml` |
| **Overrides** | `nameOverride`, `fullnameOverride` | `values.yaml` |

Every resource name is derived from these through the **helpers** in
`_helpers.tpl`.

---

## 2. The core formulas

Every standard Helm chart has two helpers:

```yaml
# 1) name helper → ConfigMap, ServiceAccount, app.kubernetes.io/name label
name = nameOverride ? nameOverride : .Chart.Name

# 2) fullname helper → Service, Deployment, StatefulSet
fullname = fullnameOverride ? fullnameOverride : "<release>-<name>"
```

**The `contains` twist** — the fullname helper checks whether the release name
already contains the chart name:

```yaml
fullname =
  .Release.Name              # if release name already contains <name>
  <release>-<name>           # otherwise
```

Example: chart name `tempo`, release `tempo` → `tempo` (contains check passes).
Release `demo` → `demo-tempo`.

**Label mapping:**

```yaml
app.kubernetes.io/name      -> name helper
app.kubernetes.io/instance  -> .Release.Name
app.kubernetes.io/component -> the component (ingester, querier, ...)
```

---

## 3. What `alias` does — the usual culprit

```yaml
dependencies:
  - name: loki
    alias: logging    # <-- this
```

**`alias` replaces the subchart's `.Chart.Name`** — the subchart renders as if
its chart name were `logging`.

Since `name = nameOverride ? nameOverride : .Chart.Name`, and `name` feeds
`app.kubernetes.io/name`, the alias leaks into **every selector and label**:

```
alias: logging  ->  .Chart.Name = logging  ->  selectors/labels = logging
no alias        ->  .Chart.Name = loki     ->  selectors/labels = loki
```

---

## 4. Why the Loki upgrade error happened

```
Cluster (running v6.28.0): loki.name = coalesce nameOverride "loki"
                                        ^ hardcoded, alias ignored
                        -> labels/selectors = "loki"      (what's in the cluster)

New chart (v18.7.1):     loki.name = .Chart.Name = "logging"   (alias leak)
                        -> labels/selectors = "logging"

Upgrade attempt:
  -> selector change required     -> "field is immutable"
  -> StatefulSet vct change       -> "updates to statefulset spec ... forbidden"
```

**Kubernetes rule:** once a resource exists, these fields are immutable:
- `spec.selector` on Deployments / StatefulSets
- `spec.serviceName` and `volumeClaimTemplates` on StatefulSets

Any upgrade that changes them fails hard (and Helm rolls back).

---

## 5. When to set what — decision table

| Situation | `nameOverride` | `fullnameOverride` | Why |
|---|---|---|---|
| **Fresh chart, clean deploy** | ❌ | ❌ | Names flow from the release name |
| **Fresh chart, fixed labels needed** (ServiceMonitors / external selectors) | ✅ | ❌ | Pin the label |
| **Upgrading an existing chart** | ✅ **required** — match the old label | ✅ required — match old names | Selectors must match |
| **Changing `nameOverride` after first install** | ❌ never | — | Selector mismatch again |

---

## 6. Rules so the error never happens again

**Rule 1 — Fresh deploy:** no overrides, just pick a good release name.
```bash
helm install tempo . -n observability
# names derive from release -> tempo-*
```

**Rule 2 — Before any upgrade, freeze the naming.** Render the current chart and
compare labels before upgrading:
```bash
helm template <release> . -n <ns> | grep "app.kubernetes.io/name"
```
Then pin both, identical to what exists:
```yaml
nameOverride: loki           # label stays what it was
fullnameOverride: logging-loki   # names stay what they were
```

**Rule 3 — Never change selector-affecting things on upgrade:**
- `nameOverride` (changes the `app.kubernetes.io/name` label)
- release name (changes the `instance` label)
- resource names (rename = delete + recreate → possible PVC data loss)

**Rule 4 — Big chart version jumps are risky** (e.g. 6.x → 18.x): helpers and
rendering change underneath. Render-compare both versions first, then deploy.

**Rule 5 — Avoid aliases** unless you specifically need a different values key.
Example: Tempo wrapper chart had `alias: tracing` removed and values key renamed
to `tempo:` — clean, no leakage.

---

## 7. Second bug class: list overrides drop defaults

When overriding values, **Helm replaces lists wholesale** — it does NOT merge
them (maps merge, lists replace).

```yaml
# chart default:
claims:
  - name: data
    accessModes: [ReadWriteOnce]   # default
    size: 10Gi

# your override:
claims:
  - name: data
    size: 1Gi                      # accessModes not written -> GONE
```

Result: `volumeClaimTemplates[].accessModes` renders empty → immutable error on
upgrade.

**Rule 6:** whenever you override a list (`claims`, `extraArgs`, etc.), write
**every required field** of every item. Nothing is merged back from the default.

---

## 8. Quick reference

```
name      = nameOverride ? nameOverride : .Chart.Name
fullname  = fullnameOverride ? fullnameOverride : <release>-<name>   (contains check)
label     = name, instance, component
alias     = replaces subchart .Chart.Name -> leaks into name + labels
immutable = Deployment/STS selector, STS serviceName, STS volumeClaimTemplates
lists     = replaced on override, never merged
```
