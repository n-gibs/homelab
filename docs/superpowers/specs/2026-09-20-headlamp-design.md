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

## RBAC: built-in `view`

`clusterRoleBinding.clusterRoleName: view` instead of the chart default `cluster-admin`.

What `view` grants: read on pods, deployments, nodes, events, ConfigMaps, and pod logs.

What it withholds: Secrets, and every write verb. No edit, no delete, no scale, no exec, no
port-forward. Every change to this cluster continues to go through git and ArgoCD, which is
the premise the repo is built on.

Two consequences worth knowing before the first time they surprise someone:

- Reading pod logs works. Opening a shell in a container does not.
- ConfigMaps are readable. Anything sensitive parked in a ConfigMap rather than a Secret is
  visible to anyone who loads the page.

If Headlamp later needs to serve incident work rather than inspection, add a narrow custom
ClusterRole for pod deletion and rollout restart on top of `view`. Do not widen to `edit`,
which carries Secret read.

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
to pin an image tag; pinning one here would create a second thing to bump that can drift out
of step with the chart.

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

After merge, with the Application synced:

4. `kubectl get application headlamp -n argocd` reports Synced and Healthy.
5. `https://headlamp.nik-homelab.dev` loads without a login prompt and lists namespaces.
6. Opening a Secret in the UI returns a permission error. This is the check that proves
   `view` took effect rather than the chart default.
7. The blackbox probe reports `probe_success 1` for the new target.

## Rollback

Delete `apps/headlamp/` and revert the `probes.yaml` line. ArgoCD prunes the namespace and
the ClusterRoleBinding. No data survives because none exists.
