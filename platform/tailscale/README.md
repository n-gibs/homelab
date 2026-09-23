# tailscale

## Every peer relays through DERP

No client has ever held a direct connection to this tailnet. `tailscale status` on the subnet
router shows the same verdict for all of them:

```
100.109.219.21  ipad-pro-11-gen-3  iOS    active; relay "sfo", tx 251301528 rx 7971080
100.68.124.7    iphone183          iOS    active; relay "sfo", tx 2251320   rx 178784
100.73.36.91    macbook-pro        macOS  active; relay "sfo", tx 21386868  rx 2251116
```

`relay "sfo"` means the traffic never reaches WireGuard's fast path. It rides Tailscale's public
DERP relays, which exist to carry control messages and to keep unlucky peers connected at all.
They are not sized for sustained video.

The cost is measurable. Remote Jellyfin playback over this path sustains **6.8 Mbps median with
dips to 0.6**, against a stream that needed 4.3 Mbps. Segments arrived slower than real time and
playback stalled.

## Two things block NAT traversal

`tailscale netcheck` from inside the subnet router pod names both:

```
UDP: true
IPv4: yes, <wan-ip>:54451
MappingVariesByDestIP: true
PortMapping:
Nearest DERP: Los Angeles (17ms)
```

**Symmetric NAT.** `MappingVariesByDestIP: true` means the external source port changes per
destination, which defeats UDP hole punching. Part of this we inflict on ourselves: the Connector
runs as an ordinary pod with no `hostNetwork` and no `hostPort`, so Cilium SNATs its egress at the
node before OPNsense SNATs it again. Two layers of translation, and the mapping varies.

**No port mapping protocol.** `PortMapping:` comes back empty. OPNsense offers neither NAT-PMP nor
PCP, so Tailscale cannot fall back to requesting a stable external port.

Kernel WireGuard is already on (`TS_USERSPACE=false`), so userspace networking is not the
bottleneck here.

## Fixing it, in order of effort

**Enable NAT-PMP on OPNsense.** Services → UPnP & NAT-PMP, enable NAT-PMP, and scope the ACL to
`192.168.30.0/24` so only the cluster VLAN can request mappings. Tailscale then negotiates its own
external port and goes direct. No manifest change, reversible in one click, and the narrow ACL
keeps the usual UPnP objection off the table.

**Pin the port and forward it statically.** If NAT-PMP proves flaky, add `--port=41641` to the
Connector and a matching `hostPort: 41641/UDP`, then forward WAN UDP 41641 to `192.168.30.136`.
Deterministic, at the price of pinning the router to a node. The Connector is a StatefulSet, so
placement is already stable.

## Do not move the subnet router while away from home

Switching the Connector to `hostNetwork` would strip the node-level SNAT layer, and it needs no
firewall access, which makes it tempting to try remotely. Resist that.

The change restarts `ts-homelab-subnet-cnddn-0`, the only pod carrying remote access to this
cluster. If it comes back wrong, there is no path back in until someone stands in front of the
hardware. The same trap as draining the subnet router's node.

It is also a coin flip on the merits. Removing one NAT layer helps only if OPNsense's own outbound
NAT is endpoint-independent. If it is not, `MappingVariesByDestIP` stays true and the risk bought
nothing.

## Verifying a fix worked

Two commands, both from inside the pod:

```bash
kubectl -n tailscale exec ts-homelab-subnet-cnddn-0 -- tailscale status
kubectl -n tailscale exec ts-homelab-subnet-cnddn-0 -- tailscale netcheck
```

`status` should report `direct <ip>:<port>` in place of `relay "sfo"` for at least one active peer.
`netcheck` should list a mapping protocol under `PortMapping:` rather than nothing. A peer that
still says `relay` after a working port mapping is a client-side NAT problem, not a server one.

## Until then

Remote streams are capped server-side to fit the relay. Jellyfin's `RemoteClientBitrateLimit` sits
at 2500000, down from the stock 20000000, which holds negotiated video around 2 Mbps and leaves
roughly 3x headroom over the DERP path. That setting lives in Jellyfin's config volume, not in
git, so raising it after the tunnel goes direct is a UI change in Dashboard → Playback.
