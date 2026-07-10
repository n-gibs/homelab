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
    source secrets/.secrets
    mkdir -p config/cert-manager
    envsubst < system/cert-manager/cluster-issuer.yaml > config/cert-manager/cluster-issuer.yaml
    echo "Built: config/cert-manager/cluster-issuer.yaml"

# ── ArgoCD Repo Credential ───────────────────────────────────────────────────

# Register private GitHub repo with ArgoCD (run after bootstrap-argocd, before bootstrap-root)
register-repo:
    #!/usr/bin/env bash
    source secrets/.secrets
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

# Seal one secret by name from secrets/registry.tsv, or all of them if omitted:
# just seal | just seal vaultwarden-admin-token  (run after bootstrap + kubeseal-fetch-cert)
seal name="":
    ./secrets/seal.sh {{name}}

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

# Wire Prowlarr → Sonarr/Radarr/Lidarr + set root folders via API (run after apps are healthy)
# Note: Bazarr → Sonarr/Radarr has no REST API; configure manually at bazarr.nik-homelab.dev → Settings
wire-media:
    #!/usr/bin/env bash
    source secrets/.secrets
    PF_PIDS=()
    cleanup() { for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
    trap cleanup EXIT

    echo "Waiting for Sonarr, Radarr, Lidarr, Prowlarr pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sonarr   -n sonarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=radarr   -n radarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=lidarr   -n lidarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prowlarr -n prowlarr --timeout=60s

    echo "Port-forwarding Sonarr, Radarr, Lidarr, Prowlarr..."
    kubectl port-forward -n sonarr svc/sonarr 8989:8989 &
    PF_PIDS+=($!)
    kubectl port-forward -n radarr svc/radarr 7878:7878 &
    PF_PIDS+=($!)
    kubectl port-forward -n lidarr svc/lidarr 8686:8686 &
    PF_PIDS+=($!)
    kubectl port-forward -n prowlarr svc/prowlarr 9696:9696 &
    PF_PIDS+=($!)
    for i in $(seq 1 20); do
      nc -z localhost 8989 && nc -z localhost 7878 && nc -z localhost 8686 && nc -z localhost 9696 && break
      sleep 0.2
    done

    SONARR="http://localhost:8989"
    RADARR="http://localhost:7878"
    LIDARR="http://localhost:8686"
    PROWLARR="http://localhost:9696"

    ensure_root_folder() {
      local url="$1" api_key="$2" path="$3" label="$4"
      if curl -sf -H "X-Api-Key: $api_key" "$url/api/v3/rootFolder" \
          | jq -e --arg p "$path" 'any(.[]; .path == $p)' >/dev/null 2>&1; then
        echo "$label root folder: already set"
      else
        curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
          "$url/api/v3/rootFolder" -d "$(jq -n --arg p "$path" '{path:$p}')" > /dev/null
        echo "$label root folder: $path"
      fi
    }

    ensure_prowlarr_app() {
      local name="$1" impl="$2" contract="$3" base_url="$4" api_key="$5" categories="$6"
      if curl -sf -H "X-Api-Key: $PROWLARR_API_KEY" "$PROWLARR/api/v1/applications" \
          | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
        echo "Prowlarr → $name: already configured"
      else
        curl -sf -X POST -H "X-Api-Key: $PROWLARR_API_KEY" -H "Content-Type: application/json" \
          "$PROWLARR/api/v1/applications" \
          -d "$(jq -n --arg name "$name" --arg impl "$impl" --arg contract "$contract" \
                 --arg purl "http://prowlarr.prowlarr.svc.cluster.local:9696" --arg burl "$base_url" \
                 --arg key "$api_key" --argjson cats "$categories" \
                 '{name:$name, syncLevel:"fullSync", implementation:$impl, configContract:$contract,
                   fields:[{name:"prowlarrUrl",value:$purl},{name:"baseUrl",value:$burl},
                           {name:"apiKey",value:$key},{name:"syncCategories",value:$cats}]}')" > /dev/null
        echo "Prowlarr → $name: wired"
      fi
    }

    ensure_root_folder "$SONARR" "$SONARR_API_KEY" "/data/media/tv" "Sonarr"
    ensure_root_folder "$RADARR" "$RADARR_API_KEY" "/data/media/movies" "Radarr"
    ensure_root_folder "$LIDARR" "$LIDARR_API_KEY" "/data/media/music" "Lidarr"
    ensure_prowlarr_app "Sonarr" "Sonarr" "SonarrSettings" \
      "http://sonarr.sonarr.svc.cluster.local:8989" "$SONARR_API_KEY" '[5000,5030,5040]'
    ensure_prowlarr_app "Radarr" "Radarr" "RadarrSettings" \
      "http://radarr.radarr.svc.cluster.local:7878" "$RADARR_API_KEY" '[2000,2010,2020,2030,2040,2045,2050,2060,2070]'
    ensure_prowlarr_app "Lidarr" "Lidarr" "LidarrSettings" \
      "http://lidarr.lidarr.svc.cluster.local:8686" "$LIDARR_API_KEY" '[3000,3010,3020,3030,3040]'

    echo ""
    echo "Done. Manual steps remaining:"
    echo "  Jellyfin: jellyfin.nik-homelab.dev → Dashboard → Libraries → Add Media Library"
    echo "    TV:     /data/media/tv"
    echo "    Movies: /data/media/movies"
    echo "    Music:  /data/media/music"
    echo "  Bazarr:  bazarr.nik-homelab.dev → Settings → Sonarr → host: sonarr.sonarr.svc.cluster.local:8989"
    echo "                                              → Radarr → host: radarr.radarr.svc.cluster.local:7878"

# ── Misc ─────────────────────────────────────────────────────────────────────

# Show TODOs remaining
todos:
    @grep -rn "TODO" ansible/ autoinstall/ bootstrap/ platform/ apps/ system/
