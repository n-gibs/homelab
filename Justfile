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

# ── Misc ─────────────────────────────────────────────────────────────────────

# Show TODOs remaining
todos:
    @grep -rn "TODO" ansible/ autoinstall/ bootstrap/ platform/ apps/ system/
