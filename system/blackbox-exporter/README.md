# blackbox-exporter

## Dashboards

`dashboard.yaml` is fed by the two Probes in `probes.yaml`. Every other dashboard in this
cluster shows Prometheus scraping something inside the cluster; this is the only one where the
check leaves the cluster and comes back in through the gateway, the HTTPRoute, and the served
certificate, the same path a browser takes.

Panel 2 (failing endpoints) is a `probe_success == 0` table, so an empty table is the healthy
state, not a broken query. There is nothing to render when every probe passes.

Panel 4's thresholds are pinned to the one window cert-manager actually alerts on
(`system/cert-manager/prometheusrule.yaml`: `CertExpiringSoon` fires under 21 days, with no
second tier below that) rather than inventing a red step the rule file does not back.
