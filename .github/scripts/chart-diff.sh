#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in single quotes are Markdown

# Prints a Markdown report of how a PR changes each chart directory: the rendered
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
  local dir="$1" ours old new
  # Captured rather than fed through <(...), whose failures nothing would see.
  ours="$(key_paths < "$dir/values.yaml")" &&
    old="$(cd "$BASE_ROOT" && helm_chart "$dir" show values | key_paths)" &&
    new="$(helm_chart "$dir" show values | key_paths)" || return 1
  comm -12 <(printf '%s\n' "$ours") <(printf '%s\n' "$old") \
    | comm -23 - <(printf '%s\n' "$new") | sed '/^$/d'
}

report() {
  local dir="$1" old new diff dropped keys
  printf '#### `%s`\n\n' "$dir"
  if [[ ! -f "$BASE_ROOT/$dir/app.yaml" ]]; then
    printf 'New chart directory, so there is nothing to compare against.\n\n'
    return
  fi

  if ! cmp -s "$dir/app.yaml" "$BASE_ROOT/$dir/app.yaml"; then
    if ! dropped="$(dropped_keys "$dir")"; then
      printf 'Could not compare values keys; see the job log.\n\n'
    elif [[ -n "$dropped" ]]; then
      printf '**Values keys the new chart no longer defines**, so Helm now ignores them:\n\n'
      mapfile -t keys <<< "$dropped"
      printf -- '- `%s`\n' "${keys[@]}"
      printf '\n'
    fi
  fi

  if ! old="$(cd "$BASE_ROOT" && render_dir "$dir" | strip_noise)" ||
    ! new="$(render_dir "$dir" | strip_noise)"; then
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
  local dir dirs=()
  while IFS= read -r dir; do
    [[ ! -f "$dir/app.yaml" ]] || dirs+=("$dir")
  done < <(list_dirs "$1")
  ((${#dirs[@]})) || return 0

  # Global, not local: the EXIT trap runs after main has returned.
  BASE_ROOT="$(mktemp -d)"
  trap 'rm -rf "$BASE_ROOT"' EXIT
  git archive "$1" | tar -x -C "$BASE_ROOT"

  printf '### Rendered chart changes\n\n'
  for dir in "${dirs[@]}"; do
    report "$dir"
  done
}

main "$@"
