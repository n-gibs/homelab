inventory := "ansible/inventory.yml"
vault_pass := ".vault_pass"
playbook := "ansible/site.yml"

# List available commands
default:
    @just --list

# ── Autoinstall USB ──────────────────────────────────────────────────────────

# Build autoinstall user-data from template + secrets
build-usb:
    bash autoinstall/build.sh

# ── Ansible ──────────────────────────────────────────────────────────────────

# Install Ansible Galaxy dependencies
deps:
    ansible-galaxy install -r ansible/requirements.yml

# Test connectivity to all nodes
ping:
    ansible -i {{inventory}} all -m ping --vault-password-file {{vault_pass}}

# Test connectivity to a single host: just ping-host worker-01
ping-host host:
    ansible -i {{inventory}} {{host}} -m ping

# Run full provisioning playbook
provision:
    ansible-playbook -i {{inventory}} {{playbook}} --vault-password-file {{vault_pass}}

# Run only the common role (base hardening)
provision-common:
    ansible-playbook -i {{inventory}} {{playbook}} --vault-password-file {{vault_pass}} --tags common

# Run only NFS roles
provision-nfs:
    ansible-playbook -i {{inventory}} {{playbook}} --vault-password-file {{vault_pass}} --tags nfs

# Dry-run (check mode)
dry-run:
    ansible-playbook -i {{inventory}} {{playbook}} --vault-password-file {{vault_pass}} --check

# Run ansible-lint
lint:
    ansible-lint ansible/site.yml

# ── Vault ────────────────────────────────────────────────────────────────────

# View encrypted vault contents
vault-view:
    ansible-vault view ansible/vault.yml --vault-password-file {{vault_pass}}

# Edit encrypted vault
vault-edit:
    ansible-vault edit ansible/vault.yml --vault-password-file {{vault_pass}}

# ── Cluster Bootstrap ────────────────────────────────────────────────────────

# Bootstrap cluster: install Cilium, ArgoCD, and root ApplicationSets
bootstrap:
    helmfile apply -f bootstrap/helmfile.yaml

# Bootstrap only Cilium
bootstrap-cilium:
    helmfile apply -f bootstrap/helmfile.yaml -l name=cilium

# Bootstrap Gateway API CRDs + ArgoCD + register private repo
bootstrap-argocd:
    helmfile apply -f bootstrap/helmfile.yaml -l name=gateway-api-crds
    helmfile apply -f bootstrap/helmfile.yaml -l name=argocd
    just register-repo

# Bootstrap only root chart (ApplicationSets)
bootstrap-root:
    helmfile apply -f bootstrap/helmfile.yaml -l name=root

# Diff bootstrap changes without applying
bootstrap-diff:
    helmfile diff -f bootstrap/helmfile.yaml

# ── Sealed Secrets ───────────────────────────────────────────────────────────

# Fetch the cluster's sealed-secrets public cert (run after bootstrap)
kubeseal-fetch-cert:
    kubeseal --fetch-cert --controller-name sealed-secrets-controller --controller-namespace sealed-secrets > pub-cert.pem

# Seal a secret file: just seal-secret path/to/secret.yaml
seal-secret file:
    kubeseal --cert pub-cert.pem -f {{file}} -w {{file}}.sealed.yaml

# ── Config Generation ────────────────────────────────────────────────────────

# Render templates with injected secrets into config/ (gitignored, apply from here)
build-config:
    #!/usr/bin/env bash
    source .secrets
    mkdir -p config/cert-manager
    envsubst < system/cert-manager/cluster-issuer.yaml > config/cert-manager/cluster-issuer.yaml
    echo "Built: config/cert-manager/cluster-issuer.yaml"

# ── ArgoCD Repo Credential ───────────────────────────────────────────────────

# Register private GitHub repo with ArgoCD (run after bootstrap-argocd, before bootstrap-root)
register-repo:
    #!/usr/bin/env bash
    source .secrets
    kubectl create secret generic homelab-repo \
      --namespace argocd \
      --from-literal=type=git \
      --from-literal=url=https://github.com/n-gibs/homelab \
      --from-literal=username=n-gibs \
      --from-literal=password="$GITHUB_REPO_PAT" \
      --dry-run=client -o yaml | \
    kubectl apply -f -
    kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository --overwrite
    echo "Registered: https://github.com/n-gibs/homelab"

# ── Post-Bootstrap Secrets ───────────────────────────────────────────────────

# Seal Cloudflare API token (run after bootstrap + kubeseal-fetch-cert)
seal-cloudflare-token:
    #!/usr/bin/env bash
    source .secrets
    kubectl create secret generic cloudflare-api-token \
      --namespace cert-manager \
      --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > config/cert-manager/cloudflare-api-token.yaml
    echo "Sealed: config/cert-manager/cloudflare-api-token.yaml"

# Seal Vaultwarden admin token (run after bootstrap + kubeseal-fetch-cert)
seal-vaultwarden-token:
    #!/usr/bin/env bash
    source .secrets
    kubectl create secret generic vaultwarden-admin-token \
      --namespace vaultwarden \
      --from-literal=token="$VAULTWARDEN_ADMIN_TOKEN" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > apps/vaultwarden/admin-token.yaml
    echo "Sealed: apps/vaultwarden/admin-token.yaml"

# Seal gluetun VPN credentials (run after bootstrap + kubeseal-fetch-cert)
seal-gluetun-creds:
    #!/usr/bin/env bash
    source .secrets
    kubectl create secret generic gluetun-vpn-creds \
      --namespace qbittorrent \
      --from-literal=WIREGUARD_PRIVATE_KEY="$WIREGUARD_PRIVATE_KEY" \
      --from-literal=WIREGUARD_ADDRESSES="$WIREGUARD_ADDRESSES" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > apps/qbittorrent/gluetun-vpn-creds.yaml
    echo "Sealed: apps/qbittorrent/gluetun-vpn-creds.yaml"

# Seal Tailscale operator OAuth credentials (run after bootstrap + kubeseal-fetch-cert)
# Get clientId/clientSecret from: https://login.tailscale.com/admin/settings/oauth
# Required scopes: devices:write (for operator to manage devices)
seal-tailscale-oauth:
    #!/usr/bin/env bash
    source .secrets
    kubectl create secret generic operator-oauth \
      --namespace tailscale \
      --from-literal=client_id="$TAILSCALE_CLIENT_ID" \
      --from-literal=client_secret="$TAILSCALE_CLIENT_SECRET" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > platform/tailscale/operator-oauth.yaml
    echo "Sealed: platform/tailscale/operator-oauth.yaml"

# Seal Cloudflare API token for external-dns (run after bootstrap + kubeseal-fetch-cert)
seal-cloudflare-token-external-dns:
    #!/usr/bin/env bash
    source .secrets
    kubectl create secret generic cloudflare-api-token \
      --namespace external-dns \
      --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > system/external-dns/cloudflare-token.yaml
    echo "Sealed: system/external-dns/cloudflare-token.yaml"

# Seal arr stack API keys (run after bootstrap + kubeseal-fetch-cert)
# Add to .secrets: SONARR_API_KEY, RADARR_API_KEY, PROWLARR_API_KEY (use `uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'`)
seal-arr-api-keys:
    #!/usr/bin/env bash
    source .secrets
    kubectl create secret generic arr-api-key \
      --namespace sonarr \
      --from-literal=SONARR__AUTH__APIKEY="$SONARR_API_KEY" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > apps/sonarr/arr-api-key.yaml
    echo "Sealed: apps/sonarr/arr-api-key.yaml"
    kubectl create secret generic arr-api-key \
      --namespace radarr \
      --from-literal=RADARR__AUTH__APIKEY="$RADARR_API_KEY" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > apps/radarr/arr-api-key.yaml
    echo "Sealed: apps/radarr/arr-api-key.yaml"
    kubectl create secret generic arr-api-key \
      --namespace prowlarr \
      --from-literal=PROWLARR__AUTH__APIKEY="$PROWLARR_API_KEY" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > apps/prowlarr/arr-api-key.yaml
    echo "Sealed: apps/prowlarr/arr-api-key.yaml"
    kubectl create secret generic recyclarr-api-keys \
      --namespace recyclarr \
      --from-literal=SONARR_API_KEY="$SONARR_API_KEY" \
      --from-literal=RADARR_API_KEY="$RADARR_API_KEY" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > apps/recyclarr/api-keys.yaml
    echo "Sealed: apps/recyclarr/api-keys.yaml"
    kubectl create secret generic arr-api-keys \
      --namespace homepage \
      --from-literal=SONARR_API_KEY="$SONARR_API_KEY" \
      --from-literal=RADARR_API_KEY="$RADARR_API_KEY" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > apps/homepage/arr-api-keys.yaml
    echo "Sealed: apps/homepage/arr-api-keys.yaml"

# Generate a fresh ArgoCD readonly API token for the Homepage widget and seal it
# (run after bootstrap-argocd has applied the `readonly` account/RBAC in bootstrap/values/argocd.yaml)
seal-argocd-token:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl port-forward svc/argocd-server -n argocd 8443:443 >/tmp/argocd-pf.log 2>&1 &
    PF_PID=$!
    trap 'kill $PF_PID 2>/dev/null || true' EXIT
    for i in $(seq 1 15); do
      nc -z localhost 8443 2>/dev/null && break
      sleep 1
    done
    ADMIN_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    argocd login localhost:8443 --username admin --password "$ADMIN_PW" --insecure --grpc-web >/dev/null
    TOKEN=$(argocd account generate-token --account readonly)
    argocd logout localhost:8443 >/dev/null 2>&1 || true
    kubectl create secret generic argocd-api-key \
      --namespace homepage \
      --from-literal=ARGOCD_API_KEY="$TOKEN" \
      --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > apps/homepage/argocd-api-key.yaml
    echo "Sealed: apps/homepage/argocd-api-key.yaml"

# Wire Prowlarr → Sonarr/Radarr + set root folders via API (run after apps are healthy)
# Note: Bazarr → Sonarr/Radarr has no REST API; configure manually at bazarr.nik-homelab.dev → Settings
wire-media:
    #!/usr/bin/env bash
    source .secrets
    PF_PIDS=()
    cleanup() { for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
    trap cleanup EXIT

    echo "Waiting for Sonarr, Radarr, Prowlarr pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sonarr   -n sonarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=radarr   -n radarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prowlarr -n prowlarr --timeout=60s

    echo "Port-forwarding Sonarr, Radarr, Prowlarr..."
    kubectl port-forward -n sonarr svc/sonarr 8989:8989 &
    PF_PIDS+=($!)
    kubectl port-forward -n radarr svc/radarr 7878:7878 &
    PF_PIDS+=($!)
    kubectl port-forward -n prowlarr svc/prowlarr 9696:9696 &
    PF_PIDS+=($!)
    for i in $(seq 1 20); do
      nc -z localhost 8989 && nc -z localhost 7878 && nc -z localhost 9696 && break
      sleep 0.2
    done

    SONARR="http://localhost:8989"
    RADARR="http://localhost:7878"
    PROWLARR="http://localhost:9696"

    # Sonarr root folder
    SONARR_RF=$(curl -sf -H "X-Api-Key: $SONARR_API_KEY" "$SONARR/api/v3/rootFolder" \
      | python3 -c "import sys,json; print(any(r['path']=='/data/media/tv' for r in json.load(sys.stdin)))" 2>/dev/null || echo False)
    if [ "$SONARR_RF" = "False" ]; then
      curl -sf -X POST \
        -H "X-Api-Key: $SONARR_API_KEY" -H "Content-Type: application/json" \
        "$SONARR/api/v3/rootFolder" -d '{"path":"/data/media/tv"}' > /dev/null
      echo "Sonarr root folder: /data/media/tv"
    else
      echo "Sonarr root folder: already set"
    fi

    # Radarr root folder
    RADARR_RF=$(curl -sf -H "X-Api-Key: $RADARR_API_KEY" "$RADARR/api/v3/rootFolder" \
      | python3 -c "import sys,json; print(any(r['path']=='/data/media/movies' for r in json.load(sys.stdin)))" 2>/dev/null || echo False)
    if [ "$RADARR_RF" = "False" ]; then
      curl -sf -X POST \
        -H "X-Api-Key: $RADARR_API_KEY" -H "Content-Type: application/json" \
        "$RADARR/api/v3/rootFolder" -d '{"path":"/data/media/movies"}' > /dev/null
      echo "Radarr root folder: /data/media/movies"
    else
      echo "Radarr root folder: already set"
    fi

    # Prowlarr → Sonarr
    SONARR_EXISTS=$(curl -sf -H "X-Api-Key: $PROWLARR_API_KEY" "$PROWLARR/api/v1/applications" \
      | python3 -c "import sys,json; print(any(a['name']=='Sonarr' for a in json.load(sys.stdin)))" 2>/dev/null || echo False)
    if [ "$SONARR_EXISTS" = "False" ]; then
      curl -sf -X POST \
        -H "X-Api-Key: $PROWLARR_API_KEY" -H "Content-Type: application/json" \
        "$PROWLARR/api/v1/applications" \
        -d "{\"name\":\"Sonarr\",\"syncLevel\":\"fullSync\",\"implementation\":\"Sonarr\",\"configContract\":\"SonarrSettings\",\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr.prowlarr.svc.cluster.local:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://sonarr.sonarr.svc.cluster.local:8989\"},{\"name\":\"apiKey\",\"value\":\"$SONARR_API_KEY\"},{\"name\":\"syncCategories\",\"value\":[5000,5030,5040]}]}" > /dev/null
      echo "Prowlarr → Sonarr: wired"
    else
      echo "Prowlarr → Sonarr: already configured"
    fi

    # Prowlarr → Radarr
    RADARR_EXISTS=$(curl -sf -H "X-Api-Key: $PROWLARR_API_KEY" "$PROWLARR/api/v1/applications" \
      | python3 -c "import sys,json; print(any(a['name']=='Radarr' for a in json.load(sys.stdin)))" 2>/dev/null || echo False)
    if [ "$RADARR_EXISTS" = "False" ]; then
      curl -sf -X POST \
        -H "X-Api-Key: $PROWLARR_API_KEY" -H "Content-Type: application/json" \
        "$PROWLARR/api/v1/applications" \
        -d "{\"name\":\"Radarr\",\"syncLevel\":\"fullSync\",\"implementation\":\"Radarr\",\"configContract\":\"RadarrSettings\",\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr.prowlarr.svc.cluster.local:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://radarr.radarr.svc.cluster.local:7878\"},{\"name\":\"apiKey\",\"value\":\"$RADARR_API_KEY\"},{\"name\":\"syncCategories\",\"value\":[2000,2010,2020,2030,2040,2045,2050,2060,2070]}]}" > /dev/null
      echo "Prowlarr → Radarr: wired"
    else
      echo "Prowlarr → Radarr: already configured"
    fi

    echo ""
    echo "Done. Manual steps remaining:"
    echo "  Jellyfin: jellyfin.nik-homelab.dev → Dashboard → Libraries → Add Media Library"
    echo "    TV:     /data/media/tv"
    echo "    Movies: /data/media/movies"
    echo "  Bazarr:  bazarr.nik-homelab.dev → Settings → Sonarr → host: sonarr.sonarr.svc.cluster.local:8989"
    echo "                                              → Radarr → host: radarr.radarr.svc.cluster.local:7878"

# ── Misc ─────────────────────────────────────────────────────────────────────

# Show TODOs remaining
todos:
    @grep -rn "TODO" ansible/ autoinstall/ bootstrap/ platform/ apps/ system/
