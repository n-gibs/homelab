# Headlamp

Deploy Headlamp, a Kubernetes web UI, as a read-only cluster dashboard at
`headlamp.nik-homelab.dev`. No login, no state, no secrets.

## Why

The cluster has no visual way to inspect itself. ArgoCD shows application sync state and
Grafana shows metrics, but neither answers "what does this pod's spec actually say" or
"which node is this thing on" without dropping to `kubectl`. Headlamp fills that gap.

## Placement: `apps/headlamp/`

Nothing in the cluster depends on Headlamp, and its only consumer is a browser. That is the
`apps/` signature. Everything currently in `platform/` (cloudnative-pg, sealed-secrets,
tailscale, renovate) is something other workloads depend on and that runs whether or not a
human is looking.

Homepage sets the precedent: also a dashboard, also operator-facing, also in the
Infrastructure group, and it lives in `apps/`.

Placement only sets the ArgoCD sync wave (platform 2, apps 3). Since nothing depends on
Headlamp, the wave is cosmetic. Move it to `platform/` only if something later gains a
dependency on it.

## Authentication: none, guarded by the network

`config.unsafeUseServiceAccountToken: true`. Headlamp authenticates every browser as its own
ServiceAccount, so there is no login prompt.

The security boundary is the network, not the application. The Gateway VIP is
`192.168.30.200`, an RFC1918 address. The Cloudflare records under `*.nik-homelab.dev` are
public names pointing at an unroutable address, so reaching Headlamp requires being on the
LAN or on the tailnet.

State this plainly because it is the one real risk in this design: **anyone who reaches the
LAN or the tailnet gets read access to the cluster with no credential.** That is acceptable
here and it is a deliberate choice, not an oversight. Revisit it if the trust level of
devices on VLAN 10 ever changes.

Switching to token authentication later is a one-value change: set
`unsafeUseServiceAccountToken: false` and paste a ServiceAccount token at the login screen.
No other part of this design moves.

OIDC was considered and rejected. The cluster runs no identity provider, so it would mean
deploying Dex or Authentik first. That is its own project.

## RBAC: `view` plus a non-core read role

Read-only, but built-in `view` alone is not enough.

`view` was queried against this cluster rather than assumed. Within the core group it covers
namespaced objects only: configmaps, endpoints, pods, pods/log, services, serviceaccounts,
persistentvolumeclaims, replicationcontrollers, resourcequotas, limitranges, bindings,
namespaces and events. It also covers `apps`, `batch`, and `cert-manager.io`, which labels its
CRDs for aggregation. It covers nothing else.
Denied under `view`: `argoproj.io`, `longhorn.io`, `postgresql.cnpg.io`,
`gateway.networking.k8s.io`, `monitoring.coreos.com`, `autoscaling.k8s.io`, `cilium.io`, plus
`storageclasses`, `customresourcedefinitions`, and the cluster-scoped core resources `nodes`,
`persistentvolumes` and `componentstatuses`. The core group is not fully covered by `view`, and
`headlamp-read` grants those three cluster-scoped core resources explicitly.

That is every CRD-backed object in this cluster. Headlamp on plain `view` would render a
generic Kubernetes dashboard with the homelab-specific half missing: no Applications, no
Longhorn volumes, no Postgres clusters, no HTTPRoutes, no VPAs, and an empty Storage section.

So bind two roles:

1. **Built-in `view`**, through the chart's own ClusterRoleBinding
   (`clusterRoleBinding.clusterRoleName: view`). This covers the namespaced core group and
   withholds Secrets. The cluster-scoped core resources listed above are not covered by
   `view`; `headlamp-read` grants them separately.
2. **A custom `headlamp-read` ClusterRole**, in `apps/headlamp/rbac.yaml`, granting
   `get`/`list`/`watch` on `*` across the 40 non-core API groups present in the cluster, plus a
   second rule adding `nodes`, `persistentvolumes` and `componentstatuses` from the core group.

The split works because **Secrets exist only in the core group**. Wildcarding every non-core
group therefore exposes no Secret, while making every CRD visible.

Two group names look alarming and are not. `bitnami.com` is SealedSecrets, whose contents are
encrypted at rest. `secrets.infisical.com` is the InfisicalSecret CR, which holds a path
reference rather than a value.

What stays withheld: Secrets, and every write verb. No edit, no delete, no scale, no exec, no
port-forward. Every change to this cluster continues to go through git and ArgoCD, which is
the premise the repo is built on.

Two consequences worth knowing before the first time they surprise someone:

- Reading pod logs works. Opening a shell in a container does not.
- ConfigMaps are readable. Anything sensitive parked in a ConfigMap rather than a Secret is
  visible to anyone who loads the page. Every live ConfigMap was scanned before this shipped:
  19 keys look credential-shaped, and each one holds a variable name or a health-check script
  rather than a value. That was true at deploy time and nothing enforces it afterwards.

**Maintenance cost, stated plainly:** a new operator's CRDs stay invisible in Headlamp until
its API group is added to `headlamp-read`. The failure is silent. It looks like an empty
section, not an error. Add the group when you add the operator.

If Headlamp later needs to serve incident work rather than inspection, add a narrow custom
ClusterRole for pod deletion and rollout restart. Do not widen to `edit`, which carries
Secret read.

## Chart

Upstream `headlamp/headlamp`, not bjw-s `app-template`. The chart has native `httpRoute`
support, so the Gateway API route and its Homepage annotations are configured through the
chart's own values. `ingress` stays disabled, per the repo rule.

```yaml
# apps/headlamp/app.yaml
chartName: headlamp
chartRepo: https://kubernetes-sigs.github.io/headlamp/
chartVersion: 0.45.0
```

Chart version and app version move in lockstep (0.45.0 for both), and the chart resolves an
empty `image.tag` to its `appVersion`. Leave the tag unset. Renovate bumps `chartVersion` in
`app.yaml` and the image follows. This deviates from the `/add-app` checklist item that says
to pin an image tag.

The chart README makes the deviation the safer call. Helm preserves an explicitly set
`image.tag` across upgrades, so a pinned tag lets the release report a new chart version
while still running the old container. Leaving the tag empty removes that failure mode.

## Rendered object names

ArgoCD sets no `releaseName`, so the Helm release takes the Application name, which the
ApplicationSet derives from the directory basename. The release is `headlamp` in namespace
`headlamp`.

| Object | Name |
|--------|------|
| Deployment | `headlamp` |
| Service | `headlamp` |
| ServiceAccount | `headlamp` |
| ClusterRoleBinding | `headlamp-admin` |

The ClusterRoleBinding keeps the name `headlamp-admin` whatever role it binds. It will point
at `view`. The name is the chart's, not a description of the grant.

## Files

`apps/headlamp/` holds `app.yaml`, `values.yaml`, `rbac.yaml` and `vpa.yaml`. One line changes
outside it, in `system/blackbox-exporter/probes.yaml`.

### `apps/headlamp/values.yaml`

Key settings, with the reasoning that belongs in the file kept to the non-obvious items:

```yaml
clusterRoleBinding:
  clusterRoleName: view

config:
  unsafeUseServiceAccountToken: true
  oidc:
    secret:
      create: false

# The chart ships resources: {}. A requestless container is invisible to the
# scheduler, which is what overloaded worker-00.
resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    memory: 256Mi

ingress:
  enabled: false

httpRoute:
  enabled: true
  hostnames:
    - headlamp.nik-homelab.dev
  parentRefs:
    - name: homelab
      namespace: envoy-gateway-system
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "Headlamp"
    gethomepage.dev/description: "Kubernetes cluster UI"
    gethomepage.dev/group: "Infrastructure"
    gethomepage.dev/icon: "headlamp.png"
    gethomepage.dev/href: "https://headlamp.nik-homelab.dev"
```

`config.oidc.secret.create` defaults to true and produces an empty `oidc` Secret in the
namespace even when OIDC is unused. Set it false.

### `apps/headlamp/rbac.yaml`

A `ClusterRole` named `headlamp-read` and a `ClusterRoleBinding` tying it to the
`headlamp` ServiceAccount in namespace `headlamp`. The chart's own binding covers `view`
separately, so this file carries only the non-core half.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: headlamp-read
# Secrets live only in the core group, which `view` covers and this role omits.
# Wildcarding every non-core group is therefore read-everything-but-Secrets.
rules:
  - apiGroups:
      - acme.cert-manager.io
      - admissionregistration.k8s.io
      - apiextensions.k8s.io
      - apiregistration.k8s.io
      - apps
      - argoproj.io
      - authentication.k8s.io
      - authorization.k8s.io
      - autoscaling
      - autoscaling.k8s.io
      - batch
      - bitnami.com
      - cert-manager.io
      - certificates.k8s.io
      - cilium.io
      - coordination.k8s.io
      - discovery.k8s.io
      - events.k8s.io
      - externaldns.k8s.io
      - flowcontrol.apiserver.k8s.io
      - gateway.envoyproxy.io
      - gateway.networking.k8s.io
      - gateway.networking.x-k8s.io
      - helm.cattle.io
      - k3s.cattle.io
      - longhorn.io
      - metrics.k8s.io
      - monitoring.coreos.com
      - monitoring.grafana.com
      - networking.k8s.io
      - nfd.k8s-sigs.io
      - node.k8s.io
      - policy
      - postgresql.cnpg.io
      - rbac.authorization.k8s.io
      - resource.k8s.io
      - scheduling.k8s.io
      - secrets.infisical.com
      - storage.k8s.io
      - tailscale.com
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["nodes", "persistentvolumes", "componentstatuses"]
    verbs: ["get", "list", "watch"]
```

The core-group gaps `view` leaves behind are cluster-scoped: `nodes` (needed for the
`metrics.k8s.io` node metrics the non-core rule already grants), `persistentvolumes` (needed
for the Storage section), and `componentstatuses` (deprecated but still a live API resource on
this cluster). Add them as a second rule against `apiGroups: [""]` with
`resources: ["nodes", "persistentvolumes", "componentstatuses"]`.

### `apps/headlamp/vpa.yaml`

Standard pattern, `updateMode: InPlaceOrRecreate`, `targetRef` Deployment `headlamp`.

### `system/blackbox-exporter/probes.yaml`

Add `https://headlamp.nik-homelab.dev` to the `apps` Probe target list. Headlamp serves 200
unauthenticated, so it belongs in the `http_2xx` module rather than `http_2xx_auth`.

Accepted tradeoff: the target lives outside the app directory and will not prune when the app
is removed. That is the shared-probe pattern this repo already chose, and adding a per-app
Probe would fragment it.

## What this design does not include

- **No PVC.** Plugins stay off, so Headlamp holds no state. Nothing to size, nothing to back
  up, no storage class decision.
- **No Infisical secret.** Nothing to store.
- **No backup CronJob.** There is no state to back up. Deleting the namespace and resyncing
  restores the app completely.
- **No ServiceMonitor.** Headlamp exposes no Prometheus metrics. The blackbox probe is the
  whole monitoring story, which puts it on rung 2 of the `/add-app` monitoring ladder.

## Verification

Before merge:

1. `helm template headlamp headlamp/headlamp -f apps/headlamp/values.yaml` renders, and the
   ClusterRoleBinding names `view`.
2. The rendered output contains an HTTPRoute and no Ingress.
3. No `oidc` Secret in the rendered output.
4. The container carries resource requests rather than `resources: {}`.

After merge, with the Application synced:

5. `kubectl get application headlamp -n argocd` reports Synced and Healthy.
6. `https://headlamp.nik-homelab.dev` loads and lists namespaces. Whether it presents a login
   screen is genuinely unknown: the chart passes `-unsafe-use-service-account-token` and the
   values doc says the flag "disables per-user authentication," but no upstream doc confirms
   the UI skips the sign-in view outright. This step settles it.

   Also check, via browser devtools or page source, whether the ServiceAccount token itself is
   retrievable from the page. `-unsafe-use-service-account-token` likely exposes it to the
   browser, and a token lifted from the page would work from outside the RFC1918 network
   boundary this design otherwise relies on as the only access control. The blast radius stays
   read-only either way, so this is not a privilege-escalation risk, but it is a second, wider
   access path worth recording as a known answer rather than an unstated assumption.
7. Opening a Secret returns a permission error. This proves `view` took effect rather than
   the chart's `cluster-admin` default.
8. An ArgoCD Application and a Longhorn volume both render. This proves `headlamp-read`
   bound, and it is the check that plain `view` would fail.
9. The blackbox probe reports `probe_success 1` for the new target.

## Rollback

Delete `apps/headlamp/` and revert the `probes.yaml` line. ArgoCD prunes the namespace and
the ClusterRoleBinding. No data survives because none exists.
