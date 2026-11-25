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

# Runs helm with the given arguments followed by the chart that <dir>/app.yaml names.
helm_chart() {
  local dir="$1" name repo chart
  shift
  name="$(field chartName "$dir")"
  repo="$(field chartRepo "$dir")"
  if [[ "$repo" == https://* ]]; then
    chart=("$name" --repo "$repo")
  else
    chart=("oci://$repo/$name")
  fi
  helm "$@" "${chart[@]}" --version "$(field chartVersion "$dir")"
}

render() {
  helm_chart "$1" template "$(basename "$1")" \
    --namespace "$(basename "$1")" --values "$1/values.yaml"
}

# Everything ArgoCD deploys from <dir>: the chart, if any, then its other manifests.
render_dir() {
  local f
  if [[ -f "$1/app.yaml" ]]; then render "$1" || return 1; fi
  for f in "$1"/*.yaml; do
    [[ "$f" != */app.yaml && "$f" != */values.yaml ]] || continue
    printf -- '\n---\n# Source: %s\n' "$(basename "$f")"
    cat "$f"
  done
}

main() {
  [[ $# -eq 1 ]] || { echo "usage: $0 <base-ref>|--all" >&2; exit 2; }
  local out dir failed=0
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
  shopt -s nullglob

  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    echo "::group::$dir"
    if ! render_dir "$dir" > "$out/${dir//\//_}.yaml"; then
      echo "::error::helm template failed for $dir"
      failed=1
    fi
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

# Sourced by chart-diff.sh for its helpers.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
