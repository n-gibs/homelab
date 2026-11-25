#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in single quotes are Markdown

# Prints a Markdown report of how a PR changes each rendered chart: the manifest
# diff against <base-ref>, and values keys we set that the new chart dropped.
# Helm ignores unknown keys, so a renamed key silently stops applying our setting.
# Usage: chart-diff.sh <base-ref>   prints nothing when no chart directory changed
set -euo pipefail

# shellcheck source=SCRIPTDIR/render-apps.sh
source "$(dirname "$0")/render-apps.sh"

# Every key path in the YAML on stdin, one per line.
key_paths() { yq -o=json '.' | jq -r 'paths | map(tostring) | join(".")' | sort -u; }

# The chart-version label changes on every resource with every bump.
strip_noise() { sed '/helm\.sh\/chart:/d'; }

# Keys our values.yaml sets that the base chart defined and the new chart doesn't.
dropped_keys() {
  local dir="$1" base_root="$2" ours old new
  # Captured rather than fed through <(...), whose failures nothing would see.
  ours="$(key_paths < "$dir/values.yaml")" &&
    old="$(cd "$base_root" && helm_chart "$dir" show values | key_paths)" &&
    new="$(helm_chart "$dir" show values | key_paths)" || return 1
  comm -12 <(printf '%s\n' "$ours") <(printf '%s\n' "$old") \
    | comm -23 - <(printf '%s\n' "$new") | sed '/^$/d'
}

report() {
  local dir="$1" base_root="$2" old new diff dropped keys
  printf '#### `%s`\n\n' "$dir"
  if [[ ! -f "$base_root/$dir/app.yaml" ]]; then
    printf 'New chart directory, so there is nothing to compare against.\n\n'
    return
  fi

  if ! cmp -s "$dir/app.yaml" "$base_root/$dir/app.yaml"; then
    if ! dropped="$(dropped_keys "$dir" "$base_root")"; then
      printf 'Could not compare values keys; see the job log.\n\n'
    elif [[ -n "$dropped" ]]; then
      printf '**Values keys the new chart no longer defines**, so Helm now ignores them:\n\n'
      mapfile -t keys <<< "$dropped"
      printf -- '- `%s`\n' "${keys[@]}"
      printf '\n'
    fi
  fi

  if ! old="$(cd "$base_root" && render "$dir" | strip_noise)" ||
    ! new="$(render "$dir" | strip_noise)"; then
    printf 'Could not render this directory; see the job log.\n\n'
    return
  fi

  diff="$(diff -u --label base --label pr <(printf '%s\n' "$old") <(printf '%s\n' "$new"))" || true
  if [[ -z "$diff" ]]; then
    printf 'No change to the rendered manifests.\n\n'
  else
    printf '<details><summary>Rendered manifest diff</summary>\n\n```diff\n%s\n```\n\n</details>\n\n' "$diff"
  fi
}

main() {
  [[ $# -eq 1 ]] || { echo "usage: $0 <base-ref>" >&2; exit 2; }
  local dir header=0
  # Global, not local: the EXIT trap runs after main has returned.
  BASE_ROOT="$(mktemp -d)"
  trap 'rm -rf "$BASE_ROOT"' EXIT
  git archive "$1" | tar -x -C "$BASE_ROOT"

  while IFS= read -r dir; do
    [[ -f "$dir/app.yaml" ]] || continue
    if ((header == 0)); then
      printf '### Rendered chart changes\n\n'
      header=1
    fi
    report "$dir" "$BASE_ROOT"
  done < <(list_dirs "$1")
}

main "$@"
