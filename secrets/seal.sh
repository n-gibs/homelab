#!/usr/bin/env bash
# Seals secrets from secrets/registry.tsv. Run via `just seal [name]`, not directly
# (assumes cwd = repo root, for pub-cert.pem / secrets/.secrets / secrets/registry.tsv).
set -euo pipefail

name="${1:-}"
source secrets/.secrets
touch secrets/.secrets.generated
source secrets/.secrets.generated

while read -r sec ns outfile keys; do
  [[ -z "$sec" || "$sec" == \#* ]] && continue
  [[ -n "$name" && "$sec" != "$name" ]] && continue
  args=(--namespace "$ns")
  IFS=',' read -ra pairs <<< "$keys"
  for kv in "${pairs[@]}"; do
    k="${kv%%=*}"; envname="${kv#*=}"
    if [[ "$envname" == generate:* ]]; then
      envname="${envname#generate:}"
      if [[ -z "${!envname:-}" ]]; then
        val="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
        printf -v "$envname" '%s' "$val"
        echo "$envname=$val" >> secrets/.secrets.generated
        echo "Generated: $envname"
      fi
    fi
    args+=(--from-literal="$k=${!envname}")
  done
  mkdir -p "$(dirname "$outfile")"
  kubectl create secret generic "$sec" "${args[@]}" --dry-run=client -o yaml | \
    kubeseal --cert pub-cert.pem -o yaml > "$outfile"
  echo "Sealed: $outfile"
done < secrets/registry.tsv
