# envoy-gateway

## Dashboards

`dashboard.yaml` is fed by the envoy-proxy PodMonitor in `podmonitor.yaml`. The question it
answers is whether routed traffic is healthy, not whether Envoy is up, after this cluster's
worst incident: the `Gateway Programmed=False` outage and the VPA-shrunk CPU limit that turned
into 504s.

It deliberately avoids `envoy_http_downstream_rq_xx`. That metric only ever carries
`envoy_http_conn_manager_prefix` values `admin` and `eg-ready-http`, Envoy's own admin and
readiness listeners, never a routed request. It looks like the obvious per-route request counter
and shows nothing that matters. Real per-route traffic is `envoy_cluster_upstream_rq`, labelled
by `envoy_cluster_name` (`httproute/<namespace>/<name>/rule/0`) and `envoy_response_code`.
