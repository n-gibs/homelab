#!/usr/bin/env bash
# Fails when a PR moves a github-releases-tracked tag to an older release.
# Version order can't be trusted here: linuxserver resets its ls counter, so a
# stale ls329 sorts above a current ls4. Release dates don't lie about that.
# Usage: reject-downgrades.sh <base-ref> [head-ref]
set -euo pipefail

# Prints "depName tag" for each tag under a github-releases renovate comment.
tracked_tags() {
  awk '
    match($0, /# renovate: datasource=github-releases depName=[^ ]+/) {
      split(substr($0, RSTART, RLENGTH), parts, "depName="); dep = parts[2]; left = 4; next
    }
    dep != "" && $1 == "tag:" { print dep, $2; dep = "" }
    dep != "" && --left == 0 { dep = "" }
  '
}

published() {
  gh api "repos/$1/releases/tags/$2" --jq .published_at 2> /dev/null
}

main() {
  [[ $# -ge 1 ]] || { echo "usage: $0 <base-ref> [head-ref]" >&2; exit 2; }
  local base="$1" head="${2:-HEAD}" file dep old new old_at new_at failed=0

  while IFS= read -r file; do
    while read -r dep new; do
      old="$(git show "$base:$file" 2> /dev/null | tracked_tags | awk -v d="$dep" '$1 == d { print $2 }')"
      [[ -n "$old" && "$old" != "$new" ]] || continue
      old_at="$(published "$dep" "$old")" || old_at=""
      new_at="$(published "$dep" "$new")" || new_at=""
      if [[ -z "$old_at" || -z "$new_at" ]]; then
        echo "::warning file=$file::$dep: no GitHub release for $old or $new, skipping"
        continue
      fi
      if [[ "$new_at" < "$old_at" ]]; then
        echo "::error file=$file::$dep $old -> $new is a downgrade: $new was released $new_at, $old was released $old_at"
        failed=1
      else
        echo "$dep $old -> $new ok ($old_at -> $new_at)"
      fi
    done < <(git show "$head:$file" | tracked_tags)
  done < <(git diff --name-only --diff-filter=M "$base...$head" -- '*.yaml')

  exit "$failed"
}

main "$@"
