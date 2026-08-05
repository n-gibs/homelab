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
    source secrets/.secrets.generated
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
    echo "  Lidarr:  run 'just tune-lidarr-quality' to apply recommended FLAC quality/custom-format tuning"

# Configure the seedbox qBittorrent as a second download client in Radarr/Sonarr,
# with a remote path mapping, and create the Prowlarr tag that routes to it.
wire-seedbox:
    #!/usr/bin/env bash
    set -euo pipefail
    source secrets/.secrets
    source secrets/.secrets.generated
    PF_PIDS=()
    cleanup() { for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
    trap cleanup EXIT

    # Split SEEDBOX_QBT_URL into the host / urlBase / ssl fields the *arr expect.
    # Shared seedbox slots serve qBittorrent on a subfolder behind HTTPS, so
    # urlBase is required — leaving it empty is the usual "looks right, won't
    # connect" failure.
    QBT_HOST=$(echo "$SEEDBOX_QBT_URL" | sed -E 's#^https?://##; s#/.*$##')
    QBT_BASE=$(echo "$SEEDBOX_QBT_URL" | sed -E 's#^https?://[^/]+##; s#/$##')
    case "$SEEDBOX_QBT_URL" in
      https://*) QBT_SSL=true;  QBT_PORT=443 ;;
      http://*)  QBT_SSL=false; QBT_PORT=80  ;;
      *) echo "SEEDBOX_QBT_URL must start with http:// or https://" >&2; exit 1 ;;
    esac
    echo "Seedbox qBittorrent: host=$QBT_HOST port=$QBT_PORT ssl=$QBT_SSL urlBase='$QBT_BASE'"

    echo "Waiting for Sonarr, Radarr, Lidarr, Prowlarr pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sonarr   -n sonarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=radarr   -n radarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=lidarr   -n lidarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prowlarr -n prowlarr --timeout=60s

    echo "Port-forwarding Sonarr, Radarr, Lidarr, Prowlarr..."
    kubectl port-forward -n sonarr   svc/sonarr   8989:8989 &
    PF_PIDS+=($!)
    kubectl port-forward -n radarr   svc/radarr   7878:7878 &
    PF_PIDS+=($!)
    kubectl port-forward -n lidarr   svc/lidarr   8686:8686 &
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

    REMOTE_PATH="/home/seedit4me/torrents/qbittorrent/media"
    LOCAL_PATH="/data/downloads/seedbox"

    ensure_tag() {
      local url="$1" api_key="$2" api_ver="$3" label="$4"
      local id
      id=$(curl -sf -H "X-Api-Key: $api_key" "$url/api/$api_ver/tag" \
        | jq -r --arg l "$label" '(.[] | select(.label == $l) | .id) // empty')
      if [ -z "$id" ]; then
        id=$(curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
          "$url/api/$api_ver/tag" -d "$(jq -n --arg l "$label" '{label:$l}')" | jq -r '.id')
        echo "tag created: $label (id=$id)" >&2
      else
        echo "tag exists: $label (id=$id)" >&2
      fi
      echo "$id"
    }

    ensure_download_client() {
      local url="$1" api_key="$2" api_ver="$3" label="$4" tag_id="$5" category_field="$6"
      if curl -sf -H "X-Api-Key: $api_key" "$url/api/$api_ver/downloadClient" \
          | jq -e --arg n "Seedbox" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
        echo "$label download client: already configured"
        return
      fi
      # seedCriteria intentionally omitted: qBittorrent's global seeding limit
      # governs deletion. Setting it here would override that per-torrent and
      # risk deleting before TorrentLeech's 10-day class minimum.
      curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
        "$url/api/$api_ver/downloadClient" -d "$(jq -n \
          --arg host "$QBT_HOST" --arg base "$QBT_BASE" \
          --arg user "$SEEDBOX_QBT_USER" --arg pass "$SEEDBOX_QBT_PASS" \
          --argjson port "$QBT_PORT" --argjson ssl "$QBT_SSL" --argjson tag "$tag_id" \
          --arg catfield "$category_field" \
          '{
            name: "Seedbox",
            implementation: "QBittorrent",
            configContract: "QBittorrentSettings",
            protocol: "torrent",
            enable: true,
            priority: 1,
            removeCompletedDownloads: false,
            removeFailedDownloads: true,
            tags: [$tag],
            fields: [
              {name:"host",     value:$host},
              {name:"port",     value:$port},
              {name:"useSsl",   value:$ssl},
              {name:"urlBase",  value:$base},
              {name:"username", value:$user},
              {name:"password", value:$pass},
              {name:$catfield,  value:"media"}
            ]
          }')" > /dev/null
      echo "$label download client: created"
    }

    ensure_path_mapping() {
      local url="$1" api_key="$2" api_ver="$3" label="$4"
      if curl -sf -H "X-Api-Key: $api_key" "$url/api/$api_ver/remotePathMapping" \
          | jq -e --arg h "$QBT_HOST" --arg r "$REMOTE_PATH/" \
            'any(.[]; .host == $h and .remotePath == $r)' >/dev/null 2>&1; then
        echo "$label remote path mapping: already configured"
        return
      fi
      curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
        "$url/api/$api_ver/remotePathMapping" -d "$(jq -n \
          --arg h "$QBT_HOST" --arg r "$REMOTE_PATH/" --arg l "$LOCAL_PATH/" \
          '{host:$h, remotePath:$r, localPath:$l}')" > /dev/null
      echo "$label remote path mapping: created"
    }

    # Pin the Seedbox client per indexer, because TAG-BASED ROUTING DOES NOT WORK.
    # Prowlarr tags do NOT propagate into the *arr — verified live: after a forced
    # ApplicationIndexerSync every Prowlarr-synced indexer still had tags: [] in
    # Radarr/Sonarr/Lidarr. Prowlarr tags only scope which indexers sync to which
    # application. A download client that carries a tag is therefore eligible for
    # NOTHING, and every grab silently falls through to the local gluetun client.
    # `downloadClientId` on the indexer is the mechanism that actually routes, and
    # it was confirmed to survive a Prowlarr full sync.
    pin_indexer_client() {
      local url="$1" api_key="$2" api_ver="$3" label="$4" cid idx id name
      cid=$(curl -sf -H "X-Api-Key: $api_key" "$url/api/$api_ver/downloadClient" \
        | jq -r '(.[] | select(.name == "Seedbox") | .id) // empty')
      if [ -z "$cid" ]; then
        echo "$label: no Seedbox download client found, skipping indexer pin" >&2
        return
      fi
      curl -sf -H "X-Api-Key: $api_key" "$url/api/$api_ver/indexer" \
        | jq -c --argjson cid "$cid" '.[]
            | select(.name | test("TorrentLeech|IPTorrents"; "i"))
            | select(.downloadClientId != $cid)
            | .downloadClientId = $cid' \
        | while read -r idx; do
            id=$(printf '%s' "$idx" | jq -r '.id')
            name=$(printf '%s' "$idx" | jq -r '.name')
            curl -sf -X PUT -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
              "$url/api/$api_ver/indexer/$id" -d "$idx" > /dev/null
            echo "$label indexer pinned to Seedbox: $name"
          done
    }

    PROWLARR_TAG=$(ensure_tag "$PROWLARR" "$PROWLARR_API_KEY" v1 seedbox)
    RADARR_TAG=$(ensure_tag "$RADARR" "$RADARR_API_KEY" v3 seedbox)
    SONARR_TAG=$(ensure_tag "$SONARR" "$SONARR_API_KEY" v3 seedbox)
    LIDARR_TAG=$(ensure_tag "$LIDARR" "$LIDARR_API_KEY" v1 seedbox)

    # Category field name is *arr-specific and was verified against each *arr's
    # live qBittorrent download client field list — "category" is NOT a valid
    # field on any of them and is silently ignored if used, leaving grabs
    # uncategorized. Do not "correct" these back to "category".
    ensure_download_client "$RADARR" "$RADARR_API_KEY" v3 Radarr "$RADARR_TAG" "movieCategory"
    ensure_download_client "$SONARR" "$SONARR_API_KEY" v3 Sonarr "$SONARR_TAG" "tvCategory"
    ensure_download_client "$LIDARR" "$LIDARR_API_KEY" v1 Lidarr "$LIDARR_TAG" "musicCategory"

    ensure_path_mapping "$RADARR" "$RADARR_API_KEY" v3 Radarr
    ensure_path_mapping "$SONARR" "$SONARR_API_KEY" v3 Sonarr
    ensure_path_mapping "$LIDARR" "$LIDARR_API_KEY" v1 Lidarr

    # Run AFTER the clients exist — this looks the Seedbox client up by name.
    pin_indexer_client "$RADARR" "$RADARR_API_KEY" v3 Radarr
    pin_indexer_client "$SONARR" "$SONARR_API_KEY" v3 Sonarr
    pin_indexer_client "$LIDARR" "$LIDARR_API_KEY" v1 Lidarr

    echo ""
    echo "Routing is by indexer downloadClientId, NOT by tag — the Prowlarr 'seedbox'"
    echo "tag (id=$PROWLARR_TAG) is organisational only and does not reach the *arr."
    echo "Releases from TorrentLeech and IPTorrents go to the Seedbox client; every"
    echo "other indexer keeps using the local qBittorrent behind gluetun."
    echo ""
    echo "Adding a new private-tracker indexer later? Re-run this recipe — the pin"
    echo "matches on the indexer NAME (TorrentLeech|IPTorrents), so a differently"
    echo "named tracker needs that pattern extended."

# Tunes Lidarr's FLAC quality thresholds and custom formats (run once, after wire-media).
# Recommendations from https://wiki.servarr.com/lidarr/tips-and-tricks#custom-formats
tune-lidarr-quality:
    #!/usr/bin/env bash
    source secrets/.secrets
    source secrets/.secrets.generated
    PF_PIDS=()
    cleanup() { for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
    trap cleanup EXIT

    echo "Waiting for Lidarr pod to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=lidarr -n lidarr --timeout=60s

    echo "Port-forwarding Lidarr..."
    kubectl port-forward -n lidarr svc/lidarr 8686:8686 &
    PF_PIDS+=($!)
    for i in $(seq 1 20); do
      nc -z localhost 8686 && break
      sleep 0.2
    done

    LIDARR="http://localhost:8686"

    # Tightens the FLAC quality definition to reject single-file CUE+FLAC rips.
    ensure_quality_definition() {
      local url="$1" api_key="$2" title="$3" min="$4" preferred="$5" max="$6"
      local current id
      current="$(curl -sf -H "X-Api-Key: $api_key" "$url/api/v1/qualitydefinition" \
        | jq -e --arg t "$title" '.[] | select(.title == $t)')"
      if echo "$current" | jq -e --argjson min "$min" --argjson pref "$preferred" --argjson max "$max" \
          '.minSize == $min and .preferredSize == $pref and .maxSize == $max' >/dev/null 2>&1; then
        echo "$title quality definition: already set"
      else
        id="$(echo "$current" | jq -r '.id')"
        echo "$current" | jq --argjson min "$min" --argjson pref "$preferred" --argjson max "$max" \
            '.minSize = $min | .preferredSize = $pref | .maxSize = $max' \
          | curl -sf -X PUT -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
              "$url/api/v1/qualitydefinition/$id" -d @- > /dev/null
        echo "$title quality definition: set min=$min preferred=$preferred max=$max"
      fi
    }

    # Creates a custom format if missing. Note: the API's `fields` is an array of
    # {name,value} pairs, not the {value: ...} shorthand shown on the wiki's import UI.
    ensure_custom_format() {
      local url="$1" api_key="$2" name="$3" specs="$4"
      if curl -sf -H "X-Api-Key: $api_key" "$url/api/v1/customformat" \
          | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
        echo "Custom format $name: already exists"
      else
        jq -n --arg name "$name" --argjson specs "$specs" \
            '{name:$name, includeCustomFormatWhenRenaming:false, specifications:$specs}' \
          | curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
              "$url/api/v1/customformat" -d @- > /dev/null
        echo "Custom format $name: created"
      fi
    }

    # Scores custom formats in a quality profile and sets minFormatScore so releases
    # matching none of them are skipped entirely.
    ensure_format_scores() {
      local url="$1" api_key="$2" profile_name="$3" min_format_score="$4"; shift 4
      local profile id updated pair fname score
      profile="$(curl -sf -H "X-Api-Key: $api_key" "$url/api/v1/qualityprofile" \
        | jq -e --arg p "$profile_name" '.[] | select(.name == $p)')"
      id="$(echo "$profile" | jq -r '.id')"
      updated="$profile"
      for pair in "$@"; do
        fname="${pair%%=*}"
        score="${pair#*=}"
        updated="$(echo "$updated" | jq --arg n "$fname" --argjson s "$score" \
          '.formatItems = (.formatItems | map(if .name == $n then .score = $s else . end))')"
      done
      updated="$(echo "$updated" | jq --argjson m "$min_format_score" '.minFormatScore = $m')"
      if [[ "$(echo "$profile" | jq -S .)" == "$(echo "$updated" | jq -S .)" ]]; then
        echo "Lidarr '$profile_name' profile format scores: already set"
      else
        echo "$updated" | curl -sf -X PUT -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
          "$url/api/v1/qualityprofile/$id" -d @- > /dev/null
        echo "Lidarr '$profile_name' profile format scores: updated"
      fi
    }

    ensure_quality_definition "$LIDARR" "$LIDARR_API_KEY" "FLAC" 0 895 1400
    ensure_quality_definition "$LIDARR" "$LIDARR_API_KEY" "FLAC 24bit" 0 895 1495

    ensure_custom_format "$LIDARR" "$LIDARR_API_KEY" "Preferred Groups" \
      '[{"name":"DeVOiD","implementation":"ReleaseGroupSpecification","negate":false,"required":false,"fields":[{"name":"value","value":"\\bDeVOiD\\b"}]},
        {"name":"PERFECT","implementation":"ReleaseGroupSpecification","negate":false,"required":false,"fields":[{"name":"value","value":"\\bPERFECT\\b"}]},
        {"name":"ENRiCH","implementation":"ReleaseGroupSpecification","negate":false,"required":false,"fields":[{"name":"value","value":"\\bENRiCH\\b"}]}]'
    ensure_custom_format "$LIDARR" "$LIDARR_API_KEY" "CD" \
      '[{"name":"CD","implementation":"ReleaseTitleSpecification","negate":false,"required":false,"fields":[{"name":"value","value":"\\bCD\\b"}]}]'
    ensure_custom_format "$LIDARR" "$LIDARR_API_KEY" "WEB" \
      '[{"name":"WEB","implementation":"ReleaseTitleSpecification","negate":false,"required":false,"fields":[{"name":"value","value":"\\bWEB\\b"}]}]'
    ensure_custom_format "$LIDARR" "$LIDARR_API_KEY" "Lossless" \
      '[{"name":"Lossless","implementation":"ReleaseTitleSpecification","negate":false,"required":false,"fields":[{"name":"value","value":"\\blossless\\b"}]}]'
    ensure_custom_format "$LIDARR" "$LIDARR_API_KEY" "Vinyl" \
      '[{"name":"Vinyl","implementation":"ReleaseTitleSpecification","negate":false,"required":false,"fields":[{"name":"value","value":"\\bVinyl\\b"}]}]'

    ensure_format_scores "$LIDARR" "$LIDARR_API_KEY" "Any" 1 \
      "Preferred Groups=100" "CD=10" "Lossless=10" "WEB=5" "Vinyl=-10000"

    echo ""
    echo "Done."

# ── Misc ─────────────────────────────────────────────────────────────────────

# Show TODOs remaining
todos:
    @grep -rn "TODO" ansible/ autoinstall/ bootstrap/ platform/ apps/ system/
