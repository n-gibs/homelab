# Homelab

k3s homelab running on HP ProDesk Mini G4.

## Nodes

| Hostname | Role | Tailscale IP |
|----------|------|-------------|
| worker-01 | k3s worker | 100.107.51.48 |

## Setup

### 1. Ubuntu Server 26.04 (Minimal)

Flashed to USB via `dd` on macOS:

```bash
diskutil unmountDisk /dev/disk4
sudo dd if=/Users/nikgibson/Downloads/ubuntu-26.04-live-server-amd64.iso of=/dev/rdisk4 bs=1m
```

Installer options:
- Minimal install
- LVM disk layout (entire disk)
- OpenSSH enabled
- No featured snaps

### 2. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

### 3. System Update

```bash
sudo apt update && sudo apt upgrade -y
```

### SSH Access

```bash
ssh homelab@<tailscale-ip>
```

## Next Steps

- [ ] Set up control plane node
- [ ] Join worker node to k3s cluster
- [ ] DHCP reservation or static IP for each node
