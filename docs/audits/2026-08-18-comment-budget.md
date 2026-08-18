# Comment budget audit

Scope: every tracked file the `comment-budget` hook checks (`.md`, `.json`, `.lock` excluded;
`bootstrap/charts/gateway-api-crds/` excluded as vendored upstream with an Apache licence header).

Rule: max 4 consecutive comment lines per block.

## Totals

| Metric | Value |
|---|---|
| Blocks over the cap | 157 |
| Excess comment lines | 853 |
| Comment share of all YAML | 18% (2,135 of 12,182 non-blank lines) |

| Directory | Excess lines | Blocks |
|---|---|---|
| `apps/` | 397 | 56 |
| `system/` | 328 | 70 |
| `ansible/` | 69 | 16 |
| `platform/` | 24 | 5 |
| `bootstrap/` | 21 | 7 |
| `Justfile` | 14 | 3 |

## Where the debt actually is

Three patterns account for roughly 500 of the 853 excess lines. Everything else is a long tail
of 1–3 line overruns that a single pass over the file fixes.

### 1. `apps/*/config-pvc.yaml` — 237 excess lines across 8 files

`bazarr, cleanuparr, jellyfin, lidarr, navidrome, prowlarr, radarr, sonarr`, plus
`apps/nextcloud/html-pvc.yaml` and `apps/vaultwarden/data-pvc.yaml` in the same shape.

Each file carries two PVCs (the retired `-local` one and the Longhorn one), and each PVC repeats
the same four arguments: why not NFS, why not `local-path`, where the backup lives, how to
restore. CLAUDE.md's Storage section already states all four as repo policy. The per-app fact is
the app's own backup path and restore UI — one or two lines.

This is the largest single win and the least risky: the prose is duplicated, not lost.
Note the `-local` PVCs are scheduled for removal on 2026-08-27, which deletes half of it anyway.

### 2. `apps/*/limitrange.yaml` — 8 files, byte-identical 6-line block

The "no default CPU limit because VPA preserves the request:limit ratio" paragraph is copy-pasted
verbatim into 8 namespaces, with `bazarr`'s 2026-08-11 throttling measurement carried along each
time. `apps/homepage/limitrange.yaml` has its own longer 13-line variant.

The measurement belongs in one place. Every copy can be one line pointing at the rule in CLAUDE.md.

### 3. Grafana dashboard ConfigMaps — 5 files, ~70 excess lines

`platform/cloudnative-pg/dashboard.yaml` (22 lines), `system/monitoring-system/dashboard-media-stack.yaml`
(21), `dashboard-backups.yaml` (20), `dashboard-cronjobs.yaml` (17), `system/vpa/dashboard.yaml` (16),
plus smaller ones under `longhorn-system`, `envoy-gateway`, `blackbox-exporter`.

These are design documents at the top of a file: why the upstream dashboard was rejected, which
metrics carry which labels, what each panel is for. Real content, wrong location. A `README.md`
beside them holds it without a cap, and the file keeps a one-line pointer.

## Worst single files

| Excess | Blocks | File |
|---|---|---|
| 61 | 12 | `ansible/roles/common/tasks/main.yml` |
| 43 | 2 | `apps/jellyfin/config-pvc.yaml` |
| 31 | 2 | `apps/sonarr/config-pvc.yaml` |
| 31 | 2 | `apps/navidrome/config-pvc.yaml` |
| 28 | 2 | `apps/prowlarr/config-pvc.yaml` |
| 27 | 2 | `apps/radarr/config-pvc.yaml` |
| 26 | 2 | `apps/cleanuparr/config-pvc.yaml` |
| 26 | 2 | `apps/bazarr/config-pvc.yaml` |
| 25 | 2 | `apps/lidarr/config-pvc.yaml` |
| 24 | 9 | `system/monitoring-system/values.yaml` |
| 19 | 6 | `apps/cleanuparr/backup-cronjob.yaml` |
| 19 | 2 | `system/monitoring-system/prometheusrule-backups.yaml` |
| 18 | 1 | `platform/cloudnative-pg/dashboard.yaml` |
| 18 | 1 | `apps/vaultwarden/data-pvc.yaml` |
| 17 | 4 | `system/monitoring-system/prometheusrule-temperature.yaml` |

`ansible/roles/common/tasks/main.yml` is different from the rest: 12 separate blocks spread over a
600-line task file, mostly node-workaround narration (NVMe APST, containerd, boot ordering). Each
overrun is small; there is no single paragraph to move.

## Suggested order

1. `apps/*/limitrange.yaml` — mechanical, 8 identical edits, zero judgement.
2. `apps/*/config-pvc.yaml` — biggest win; defer to after the 2026-08-27 `-local` PVC prune if
   you would rather not edit lines you are about to delete.
3. Dashboard ConfigMaps → `README.md` per directory.
4. `ansible/roles/common/tasks/main.yml` — one pass, 12 small trims.
5. The tail: 60-odd files with a 1–3 line overrun each.

## Reproducing this

```bash
git ls-files | grep -Ev '\.(md|markdown|json|lock|png|jpg|pem|tsv)$' | grep -v '^bootstrap/charts/' |
while read -r f; do
  awk -v max=4 -v file="$f" '
    function flush() { if (run > max) printf "%d\t%s:%d\n", run, file, start; run = 0 }
    { line=$0; sub(/^[ \t]+/,"",line)
      is_comment = (line ~ /^#/ && line !~ /^#!/) || line ~ /^\/\//
      if (is_comment) { if (run==0) start=NR; run++ } else flush() }
    END { flush() }' "$f"
done | sort -rn
```

Same rule as the `comment-budget` PostToolUse hook, which only sees files Claude edits. This sweep
covers the whole tree.
