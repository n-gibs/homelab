#!/usr/bin/env bash
# Renders each stack directory the way stack.yaml's ApplicationSet does (chart +
# values.yaml, plus the directory's other manifests), then schema-checks it.
# Usage: render-apps.sh <base-ref>   only directories changed since <base-ref>
#        render-apps.sh --all        every directory
set -euo pipefail

CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

list_dirs() {
  if [[ "$1" == "--all" ]]; then
    find apps platform system -mindepth 1 -maxdepth 1 -type d
  else
    git diff --name-only "$1...HEAD" | awk -F/ '$1 ~ /^(apps|platform|system)$/ && NF >= 3 { print $1 "/" $2 }'
  fi | sort -u
}

field() { sed -n "s/^$1: *//p" "$2/app.yaml"; }

render() {
  local dir="$1" name repo version chart
  name="$(field chartName "$dir")"
  repo="$(field chartRepo "$dir")"
  version="$(field chartVersion "$dir")"
  if [[ "$repo" == https://* ]]; then
    chart=("$name" --repo "$repo")
  else
    chart=("oci://$repo/$name")
  fi
  helm template "$(basename "$dir")" "${chart[@]}" --version "$version" \
    --namespace "$(basename "$dir")" --values "$dir/values.yaml"
}

main() {
  [[ $# -eq 1 ]] || { echo "usage: $0 <base-ref>|--all" >&2; exit 2; }
  local out dir f failed=0
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT

  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    echo "::group::$dir"
    if [[ -f "$dir/app.yaml" ]] && ! render "$dir" > "$out/${dir//\//_}.yaml"; then
      echo "::error::helm template failed for $dir"
      failed=1
    fi
    for f in "$dir"/*.yaml; do
      [[ -e "$f" && "$f" != */app.yaml && "$f" != */values.yaml ]] || continue
      cp "$f" "$out/${dir//\//_}_$(basename "$f")"
    done
    echo "::endgroup::"
  done < <(list_dirs "$1")

  if compgen -G "$out/*.yaml" > /dev/null; then
    kubeconform -summary -ignore-missing-schemas \
      -schema-location default -schema-location "$CRD_SCHEMAS" "$out" || failed=1
  else
    echo "No stack directories changed."
  fi
  exit "$failed"
}

main "$@"
