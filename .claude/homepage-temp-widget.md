# Handoff: improve the Homepage temperature widget

Written 2026-07-31. Paste the section below into a new session.

---

Improve the temperature widget on the Homepage dashboard. It works, but it shows bare numbers
with no units and no sense of whether any of them is a problem. Everything below is measured —
don't re-derive it.

## Current state

`apps/homepage/values.yaml`, the `Temperatures` service (~line 193):

```yaml
- Temperatures:
    href: https://grafana.nik-homelab.dev
    description: CPU & drive temps
    icon: mdi-thermometer
    widget:
      type: customapi
      url: http://prometheus-operated.monitoring-system.svc.cluster.local:9090/api/v1/query?query=node:temperature_celsius:max
      refreshInterval: 60000
      display: dynamic-list
      mappings:
        items: data.result
        name: metric.sensor_name
        label: value.1
        format: number
```

Homepage `v1.13.2`, chart `homepage` `2.1.0` from `https://jameswynn.github.io/helm-charts`.

Live response from that URL right now — four rows, no NVMe, values are **strings**:

```json
{"status":"success","data":{"resultType":"vector","result":[
 {"metric":{"nodename":"worker-00","sensor_name":"worker-00 CPU"},"value":[1785526794.888,"48"]},
 {"metric":{"nodename":"worker-02","sensor_name":"worker-02 CPU"},"value":[1785526794.888,"46"]},
 {"metric":{"nodename":"worker-01","sensor_name":"worker-01 CPU"},"value":[1785526794.888,"55"]},
 {"metric":{"nodename":"worker-01","sensor_name":"worker-01 HDD"},"value":[1785526794.888,"57"]}]}}
```

So it renders four rows reading `48`, `46`, `55`, `57` — no units, no context.

Query it yourself before and after any change:

```bash
kubectl run -n homepage tempprobe --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet \
  -- -s 'http://prometheus-operated.monitoring-system.svc.cluster.local:9090/api/v1/query?query=node:temperature_celsius:max'
```

## Gaps worth fixing

Ordered by value-to-effort. **1 and 2 are certain; 3–5 need verification before you commit to
an approach.**

1. **`href` points at the Grafana root.** A dashboard for exactly this now exists — uid
   `homelab-temperatures`, defined in `system/monitoring-system/dashboard-temperatures.yaml`.
   Deep-link it: `https://grafana.nik-homelab.dev/d/homelab-temperatures`. Confirmed the uid is
   live; verify the URL form Grafana actually serves before committing.

2. **NVMe is missing entirely.** The recording rule only covers CPU and HDD, so the three NVMe
   drives — which have their own crit thresholds of 81.85, 81.85 and 87.85C — are invisible here.
   This is a genuine coverage hole, not cosmetic. See the caveat below about *where* to fix it.

3. **No units.** `format: number` renders `57`, not `57°C`. Homepage's `customapi` mappings may
   support a suffix or a different format for this — **check the Homepage v1.13.2 docs for the
   supported `mappings` keys rather than guessing.** Do not invent a field name; an unsupported
   key fails silently or breaks the widget.

4. **No sense of hot vs fine.** 57 means nothing without knowing the drive's limit is 65 while a
   coretemp crit is 82 on worker-00 and 100 on the other two. The hardware genuinely disagrees
   about what hot means, which is why the Grafana dashboard plots *headroom to each sensor's own
   limit* rather than raw temperature. Consider whether this widget should do the same — a row
   reading `8C to limit` is more actionable than `57`. Whether Homepage can colour rows
   conditionally is unverified; find out rather than assume.

5. **`display: dynamic-list` may not be the best fit.** Worth checking what other `customapi`
   display modes v1.13.2 offers before assuming this is the right one.

## Important caveat — the recording rule has three consumers

`node:temperature_celsius:max` lives in `system/monitoring-system/prometheusrule-temperature.yaml`
and is read by **this widget, the Grafana dashboard's panel 1, and nothing else** — but changing
its shape (labels, which series it emits) affects both consumers. If you extend it to include
NVMe, update the dashboard panel too or you will double-count: panel 1 currently gets NVMe from a
*separate* query precisely because the rule lacks it.

Two defensible approaches, pick one deliberately:
- **Extend the recording rule** to include NVMe, then simplify the dashboard's panel 1 to drop
  its second query. One source of truth, two files touched.
- **Leave the rule alone** and give the widget its own query. Less coupling, more duplication.

The rule exists partly to keep the widget URL short enough to review — a long inline PromQL
query in a YAML value is hard to read and easy to break. Weigh that.

## Constraints

- **Never invent Homepage config keys.** Verify against the v1.13.2 docs. An unsupported mapping
  key is a silently broken widget, and this is a dashboard nobody looks at closely until it
  matters.
- **Don't add a monitoring component.** Everything needed is already in Prometheus.
- **Don't lower alert thresholds** or change `prometheusrule-temperature.yaml`'s alerting rules
  to make anything look better. The disk genuinely runs 8C from its limit; that is real.
- Changes deploy through git → ArgoCD auto-sync from `main`. `apps/homepage/values.yaml` is Helm
  values; `system/monitoring-system/*.yaml` are raw manifests picked up by the ApplicationSet's
  third source.
- **Verify the rendered result**, don't assume the sync worked. Port-forward Homepage or load
  `https://homepage.nik-homelab.dev` and look at the widget. A `customapi` widget that fails to
  parse renders blank or errors rather than failing loudly.
- Repo rules apply: no `Ingress` (Gateway API `HTTPRoute` only), no `sleep`, server-side apply.

## Context you may want

- `.claude/hdd-running-hot.md` — why the 12TB drive runs at 56–57C against a 65C max, and why the
  disk row is the one with real meaning behind it.
- `system/monitoring-system/dashboard-temperatures.yaml` — the Grafana dashboard built the same
  day. Its panel descriptions explain the headroom reasoning and the per-sensor limit spread.
- Adjacent in `values.yaml` is a Grafana widget with `password: changeme` inline. Out of scope,
  but worth flagging to the user rather than silently fixing.

## Done looks like

The widget shows every thermal sensor that matters — including NVMe — with units, in a form where
a glance tells you whether anything needs attention, linking to the dashboard that has the
detail. Verified rendering in a browser, not just synced.
