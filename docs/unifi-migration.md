# UniFi Migration

Replacing the OPNsense firewall with a UniFi Cloud Gateway, adding Wi-Fi 7 and a PoE switch.

The drivers are physical, not functional. OPNsense works. The current box is aging, does not
fit the 10" rack, and there is no Wi-Fi 7 or PoE behind it. Everything below follows from
that: the goal is fewer boxes that fit the rack, not better routing.

## Hardware

| Item | Model | Why |
|------|-------|-----|
| Gateway | UCG-Max + M.2 tray + NVMe | 4x 2.5G LAN, and the M.2 slot runs Protect for cameras |
| Switch | USW-Lite-8-PoE | 52W across 4 PoE+ ports, fanless, L2 |
| AP | One U7 Pro | Wi-Fi 7 |
| Cameras | Two, later | Replaces Ring |

**UCG-Max over UCG-Fiber.** The Fiber adds 10G SFP+, a 10G WAN port and 5 Gbps of IDS/IPS
throughput for $80 more. Nodes are 1G on the i219-LM and the NAS is 2.5G, so there is nothing
to plug into 10G. Revisit only if the WAN goes above ~2 Gbps.

**Not UCG-Ultra.** It cannot run Protect at all, which fails the camera goal on day one.

**Not USW-Pro-8-PoE.** Its argument is a 120W PoE budget and a true 1U 7.9" chassis. At two
cameras the Lite's 52W is not close to a limit, and a switch swap is cheap to defer: UniFi
re-adopts and you re-tag ports. Its L3 routing would sit unused, since the gateway routes
VLAN 10 to VLAN 30 and cluster storage traffic never leaves VLAN 30.

Ports are tighter than watts. Uplink, three nodes, the AP and two cameras fill seven of eight.
The gateway's two spare 2.5G LAN ports are the overflow, and they are faster anyway.

## Wiring

WAN into the gateway's 2.5G WAN port. NAS straight into a 2.5G LAN port, since the CWWK board
has 2x i226-V and the nodes do not. Switch into a second 2.5G LAN port. Nodes, AP and cameras
on the switch.

## The DNS override goes away

Unbound on OPNsense overrides `nik-homelab.dev` to `192.168.30.200`. external-dns publishes
the same Gateway address to Cloudflare with `proxied: false`, so the public zone already hands
out that private IP. Both resolvers return `192.168.30.200`, verified against `@1.1.1.1`.

The split horizon splits nothing. Delete it with the old box rather than rebuilding it, and do
not stand up blocky or CoreDNS to replace it.

UniFi cannot host either one regardless. OPNsense is FreeBSD with a package system; a UniFi
gateway is a closed appliance whose DNS surface is a policy table of A, AAAA, CNAME, MX, TXT,
SRV and Forward Domain records. No wildcards.

**What this costs.** With no local zone, internal names stop resolving once cached TTLs expire
during a WAN outage, even though every service is still running. If that matters, add a few A
records in the UniFi policy table pointing at `.200`. Native, no wildcard needed.

**Leave `dns01RecursiveNameserversOnly` in `system/cert-manager/values.yaml`.** It pins the
DNS-01 self-check to public resolvers regardless of what the gateway does. Once OPNsense is
gone it is inert rather than wrong.

## What breaks if the swap is done carelessly

**Reservations are identity.** Nodes are DHCP-only with their addresses hardcoded across the
repo. Transcribe every lease before cutover. `192.168.30.129` is in the kubeconfig,
`192.168.30.194` is the NFS server, and `192.168.30.200` must stay outside the DHCP pool.

**Keep `192.168.30.1` as the VLAN 30 gateway.** Node `resolv.conf` points at it, and CoreDNS
forwards upstream through it.

**Leave client isolation, ARP inspection and DHCP snooping off on VLAN 30.** Cilium claims
`192.168.30.200` by gratuitous ARP. Anything that filters or inspects ARP on that VLAN stops
the announcement from being believed, and the failure looks like ingress hanging rather than
like a switch setting.

**Move the Tailscale subnet router off any node you are about to touch.** It advertises
`192.168.30.0/24`, so rebooting its host cuts your own control path. `ssh -b 192.168.10.105`
takes the direct VLAN 10 to VLAN 30 route instead.

## Rollback

Every step is reversible. The gateway swap rolls back by plugging OPNsense in, which is why
the Unbound override is deleted after the swap succeeds rather than before it.

## Aside

The zone is public and unproxied, so anyone can enumerate `nik-homelab.dev` and get the full
app list plus `192.168.30.200`. True today and unchanged by this migration. The IP is not
routable from outside, so this is a reconnaissance surface rather than an exposure.
