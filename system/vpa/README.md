# vpa

## Dashboards

`dashboard.yaml` is fed by the recommender and updater podMonitors enabled in `values.yaml`.
Before those, nothing on it was scraped.

It lives in the `vpa` namespace rather than `monitoring-system` because the Grafana sidecar runs
`LABEL=grafana_dashboard`, `LABEL_VALUE=1`, `NAMESPACE=ALL` and finds it either way. Keeping it
beside the podMonitor toggle that feeds it matches how envoy-gateway and longhorn-system hold
their own monitoring; `monitoring-system` is for subjects with no directory of their own
(cilium, etcd, argocd) or ones spanning several.

The question it answers is whether `InPlaceOrRecreate` is resizing pods or quietly falling back
to eviction. The updater exposes no failure or eviction counter, so the tell is the
eligible-vs-resized panel: candidates staying above zero while the resize rate stays flat means
every attempt is ending in a restart instead.

All queries use metric labels verified against the live 1.7.1 endpoints. The updater buckets
everything by `vpa_size_log2`, so sums must aggregate that label away.
