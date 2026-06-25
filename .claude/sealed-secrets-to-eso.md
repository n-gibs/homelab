# Migration: Sealed Secrets → ESO + Vaultwarden

Move all app secrets from `SealedSecret` to `ExternalSecret` backed by Vaultwarden.

ESO is already installed (`platform/external-secrets/`). Vaultwarden is already running.

## What Stays Sealed (Bootstrap Dependencies)

These cannot use ESO because they are required *before* Vaultwarden or cert-manager is reachable:

| Secret | Namespace | Why |
|--------|-----------|-----|
| `vaultwarden-admin-token` | vaultwarden | Bootstraps Vaultwarden itself |
| `cloudflare-api-token` | cert-manager | Needed before TLS is provisioned (before Vaultwarden HTTPS works) |
| `vaultwarden-eso-creds` | external-secrets | **New** — client_id + client_secret for ESO to auth to Vaultwarden API |

Everything else migrates.

## Secrets to Migrate

| Secret Name | Namespace | Keys |
|-------------|-----------|------|
| `arr-api-key` | sonarr | `SONARR__AUTH__APIKEY` |
| `arr-api-key` | radarr | `RADARR__AUTH__APIKEY` |
| `arr-api-key` | prowlarr | `PROWLARR__AUTH__APIKEY` |
| `recyclarr-api-keys` | recyclarr | `SONARR_API_KEY`, `RADARR_API_KEY` |
| `arr-api-keys` | homepage | `SONARR_API_KEY`, `RADARR_API_KEY` |
| `gluetun-vpn-creds` | qbittorrent | `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES` |
| `operator-oauth` | tailscale | `client_id`, `client_secret` |
| `cloudflare-api-token` | external-dns | `api-token` |

## Architecture

```
Vaultwarden (password manager, source of truth)
    ↑ REST API (Bearer token)
CronJob — refreshes access token every 45min → vaultwarden-eso-token (K8s secret)
    ↑ secretRef
ClusterSecretStore (webhook provider)
    ↑ ExternalSecret resources
K8s Secrets (created/synced by ESO)
    ↑
Apps
```

Vaultwarden access tokens expire after 1 hour. The CronJob keeps a fresh token in a K8s secret that the webhook provider reads.

## Step 1 — Get Vaultwarden Personal API Key

In Vaultwarden web UI:
1. Log in → Account Settings → Security → API Key
2. Note your `client_id` (format: `user.XXXXXXXX`) and `client_secret`
3. Add both to `.secrets`:
   ```
   VAULTWARDEN_ESO_CLIENT_ID=user.XXXXXXXX
   VAULTWARDEN_ESO_CLIENT_SECRET=<secret>
   ```

Add a seal target to `Justfile`:
```bash
seal-vaultwarden-eso-creds:
    #!/usr/bin/env bash
    source .secrets
    kubectl create secret generic vaultwarden-eso-creds \
      --namespace external-secrets \
      --from-literal=client_id="$VAULTWARDEN_ESO_CLIENT_ID" \
      --from-literal=client_secret="$VAULTWARDEN_ESO_CLIENT_SECRET" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > platform/external-secrets/eso-vaultwarden-creds.yaml
    echo "Sealed: platform/external-secrets/eso-vaultwarden-creds.yaml"
```

Run `just seal-vaultwarden-eso-creds`, commit the sealed secret.

## Step 2 — Add Secrets to Vaultwarden

Create a collection named **`homelab-k8s`** in Vaultwarden. Add one item per secret below.

Use **Login** type with custom fields for multi-value secrets. Use the `notes` field or custom fields — do not store sensitive values in the item Name.

Recommended item structure (one item per K8s secret):

| Vaultwarden Item Name | Type | Fields |
|-----------------------|------|--------|
| `sonarr-api-key` | Login | password: `<SONARR__AUTH__APIKEY>` |
| `radarr-api-key` | Login | password: `<RADARR__AUTH__APIKEY>` |
| `prowlarr-api-key` | Login | password: `<PROWLARR__AUTH__APIKEY>` |
| `arr-api-keys` | Login | custom: `SONARR_API_KEY`, `RADARR_API_KEY` |
| `gluetun-vpn-creds` | Secure Note | custom: `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES` |
| `tailscale-oauth` | Login | username: `client_id`, password: `client_secret` |
| `cloudflare-token-external-dns` | Login | password: `<api-token>` |

After creating each item, note its **UUID** from the URL (`/items/<uuid>`). You'll need these for the ExternalSecret manifests.

## Step 3 — Token Refresh CronJob

Create `platform/external-secrets/token-refresh-cronjob.yaml`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vaultwarden-token-refresh
  namespace: external-secrets
spec:
  schedule: "*/45 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: vaultwarden-token-refresher
          restartPolicy: OnFailure
          containers:
            - name: refresh
              image: curlimages/curl:8.10.1
              command:
                - /bin/sh
                - -c
                - |
                  TOKEN=$(curl -sf -X POST \
                    https://vaultwarden.nik-homelab.dev/identity/connect/token \
                    -H "Content-Type: application/x-www-form-urlencoded" \
                    -d "grant_type=client_credentials&scope=api&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" \
                    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
                  if [ -z "$TOKEN" ]; then echo "Token fetch failed"; exit 1; fi
                  kubectl create secret generic vaultwarden-eso-token \
                    --namespace external-secrets \
                    --from-literal=token="$TOKEN" \
                    --dry-run=client -o yaml | kubectl apply -f -
              env:
                - name: CLIENT_ID
                  valueFrom:
                    secretKeyRef:
                      name: vaultwarden-eso-creds
                      key: client_id
                - name: CLIENT_SECRET
                  valueFrom:
                    secretKeyRef:
                      name: vaultwarden-eso-creds
                      key: client_secret
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vaultwarden-token-refresher
  namespace: external-secrets
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vaultwarden-token-refresher
  namespace: external-secrets
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vaultwarden-token-refresher
  namespace: external-secrets
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: vaultwarden-token-refresher
subjects:
  - kind: ServiceAccount
    name: vaultwarden-token-refresher
    namespace: external-secrets
```

Run the initial token fetch manually before deploying ExternalSecrets:
```bash
kubectl create job --from=cronjob/vaultwarden-token-refresh initial-token-fetch -n external-secrets
kubectl wait --for=condition=complete job/initial-token-fetch -n external-secrets --timeout=60s
```

## Step 4 — ClusterSecretStore

Create `platform/external-secrets/cluster-secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vaultwarden
spec:
  provider:
    webhook:
      url: "https://vaultwarden.nik-homelab.dev/api/items/{{ .remoteRef.key }}"
      headers:
        Authorization: "Bearer {{ .auth.token }}"
      result:
        jsonPath: "{{ .remoteRef.property }}"
      secrets:
        - name: vaultwarden-eso-token
          secretRef:
            name: vaultwarden-eso-token
            namespace: external-secrets
            key: token
      auth:
        token:
          secretRef:
            name: vaultwarden-eso-token
            namespace: external-secrets
            key: token
```

## Step 5 — ExternalSecret Manifests

Replace each existing `*-api-key.yaml` / `*-creds.yaml` sealed secret file with an ExternalSecret. Fill in the actual Vaultwarden item UUIDs noted in Step 2.

### sonarr/arr-api-key.yaml
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: arr-api-key
  namespace: sonarr
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vaultwarden
    kind: ClusterSecretStore
  target:
    name: arr-api-key
  data:
    - secretKey: SONARR__AUTH__APIKEY
      remoteRef:
        key: "<sonarr-api-key-item-uuid>"
        property: "$.login.password"
```

### radarr/arr-api-key.yaml
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: arr-api-key
  namespace: radarr
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vaultwarden
    kind: ClusterSecretStore
  target:
    name: arr-api-key
  data:
    - secretKey: RADARR__AUTH__APIKEY
      remoteRef:
        key: "<radarr-api-key-item-uuid>"
        property: "$.login.password"
```

### prowlarr/arr-api-key.yaml
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: arr-api-key
  namespace: prowlarr
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vaultwarden
    kind: ClusterSecretStore
  target:
    name: arr-api-key
  data:
    - secretKey: PROWLARR__AUTH__APIKEY
      remoteRef:
        key: "<prowlarr-api-key-item-uuid>"
        property: "$.login.password"
```

### recyclarr/api-keys.yaml
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: recyclarr-api-keys
  namespace: recyclarr
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vaultwarden
    kind: ClusterSecretStore
  target:
    name: recyclarr-api-keys
  data:
    - secretKey: SONARR_API_KEY
      remoteRef:
        key: "<arr-api-keys-item-uuid>"
        property: "$.fields[?(@.name=='SONARR_API_KEY')].value"
    - secretKey: RADARR_API_KEY
      remoteRef:
        key: "<arr-api-keys-item-uuid>"
        property: "$.fields[?(@.name=='RADARR_API_KEY')].value"
```

### homepage/arr-api-keys.yaml
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: arr-api-keys
  namespace: homepage
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vaultwarden
    kind: ClusterSecretStore
  target:
    name: arr-api-keys
  data:
    - secretKey: SONARR_API_KEY
      remoteRef:
        key: "<arr-api-keys-item-uuid>"
        property: "$.fields[?(@.name=='SONARR_API_KEY')].value"
    - secretKey: RADARR_API_KEY
      remoteRef:
        key: "<arr-api-keys-item-uuid>"
        property: "$.fields[?(@.name=='RADARR_API_KEY')].value"
```

### qbittorrent/gluetun-vpn-creds.yaml
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gluetun-vpn-creds
  namespace: qbittorrent
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vaultwarden
    kind: ClusterSecretStore
  target:
    name: gluetun-vpn-creds
  data:
    - secretKey: WIREGUARD_PRIVATE_KEY
      remoteRef:
        key: "<gluetun-vpn-creds-item-uuid>"
        property: "$.fields[?(@.name=='WIREGUARD_PRIVATE_KEY')].value"
    - secretKey: WIREGUARD_ADDRESSES
      remoteRef:
        key: "<gluetun-vpn-creds-item-uuid>"
        property: "$.fields[?(@.name=='WIREGUARD_ADDRESSES')].value"
```

### platform/tailscale/operator-oauth.yaml
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: operator-oauth
  namespace: tailscale
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vaultwarden
    kind: ClusterSecretStore
  target:
    name: operator-oauth
  data:
    - secretKey: client_id
      remoteRef:
        key: "<tailscale-oauth-item-uuid>"
        property: "$.login.username"
    - secretKey: client_secret
      remoteRef:
        key: "<tailscale-oauth-item-uuid>"
        property: "$.login.password"
```

### system/external-dns/cloudflare-token.yaml
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: external-dns
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vaultwarden
    kind: ClusterSecretStore
  target:
    name: cloudflare-api-token
  data:
    - secretKey: api-token
      remoteRef:
        key: "<cloudflare-token-external-dns-item-uuid>"
        property: "$.login.password"
```

## Step 6 — Migration Order

1. Commit + push sealed secret for `vaultwarden-eso-creds` → ArgoCD syncs it
2. Add all secrets to Vaultwarden, note UUIDs
3. Deploy token-refresh CronJob → run initial job manually
4. Deploy ClusterSecretStore → verify with `kubectl get clustersecretstore vaultwarden`
5. For each secret: replace SealedSecret YAML with ExternalSecret YAML, commit, push, verify sync
6. Confirm each K8s secret was created by ESO: `kubectl get secret <name> -n <ns>`
7. Verify apps are functioning (check logs if any app restarts)

Migrate one namespace at a time. ArgoCD will delete the SealedSecret and create the ExternalSecret-managed secret in the same sync.

## Step 7 — Cleanup

Once all ExternalSecrets are synced and apps confirmed healthy:

```bash
# Remove sealed-secrets from platform
# Delete the sealed-secrets ArgoCD app by removing platform/sealed-secrets/ dir
# Remove kubeseal cert from repo root (pub-cert.pem is in .gitignore already)
# Remove just seal-* targets from Justfile (or keep for the 3 remaining sealed secrets)
# Update .secrets.example to remove keys that moved to Vaultwarden
```

Update `CLAUDE.md` to note sealed-secrets is no longer the primary mechanism.

## Rollback

If ESO sync fails after replacing a SealedSecret:
```bash
# Re-apply the old sealed secret manifest
kubectl apply -f - <<'EOF'
# paste original SealedSecret YAML here
EOF
```

The sealed-secrets controller will recreate the K8s secret immediately.

## Notes

- `refreshInterval: 1h` means ESO re-fetches from Vaultwarden every hour. If you rotate a secret in Vaultwarden, it propagates within 1 hour (or force refresh: `kubectl annotate es <name> -n <ns> force-sync=$(date +%s)`)
- The CronJob uses `curlimages/curl` — pin this to a specific digest in production
- Vaultwarden item UUIDs are stable — they don't change when you edit an item
- The `arr-api-keys` item (multi-value) is shared between `recyclarr` and `homepage` namespaces — same UUID, different ExternalSecrets
