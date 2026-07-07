# Homelab

k3s homelab on HP ProDesk Mini G4 nodes. Ansible provisioning, ArgoCD GitOps.

## Nodes

| Hostname | Role | Tailscale IP |
|----------|------|--------------|
| worker-01 | k3s worker | 100.107.51.48 |
| worker-00 | k3s server | TBD |

## Prerequisites

On your Mac:

```bash
brew install ansible
```

Add your SSH key to each node (skip if using password auth):

```bash
ssh-copy-id homelab@<tailscale-ip>
```

---

## 1. Provision a New Node

After installing Ubuntu Server 26.04 (minimal) and Tailscale:

1. Add node to `ansible/inventory/hosts.yml` under the correct group
2. Run base provisioning:

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/provision-node.yml --limit <hostname>
```

This installs: system updates, curl/git/htop, Tailscale.

> Tailscale `up` must still be run manually on the node to authenticate.

---

## 2. Install k3s Control Plane

```bash
ansible-playbook -i inventory/hosts.yml playbooks/k3s-server.yml
```

After completion, grab the node token and kubeconfig from the server:

```bash
ssh homelab@<server-tailscale-ip>
sudo cat /var/lib/rancher/k3s/server/node-token
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy `k3s.yaml` to `~/.kube/config` on your Mac. Replace `127.0.0.1` with the server's Tailscale IP.

---

## 3. Join Worker Nodes

Set vars in `ansible/inventory/hosts.yml` or pass on CLI:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/k3s-agents.yml \
  -e "k3s_server_url=https://100.x.x.x:6443" \
  -e "k3s_node_token=<token-from-step-2>"
```

Verify nodes joined:

```bash
kubectl get nodes
```

---

## 4. Bootstrap ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f gitops/bootstrap/argocd/install.yaml
```

Wait for ArgoCD to be ready:

```bash
kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd
```

Get initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

---

## OS Install

Ubuntu 26.04 LTS — installed manually from USB.

1. Download Ubuntu 26.04 LTS Server minimal ISO
2. Flash to USB: `sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/rdiskN bs=1m status=progress`
3. Boot node from USB (HP ProDesk: **F10** → select USB)
4. Follow installer: set hostname, enable OpenSSH, skip snaps
5. Reboot, remove USB

---

## Adding a New Node (Repeatable)

1. Install Ubuntu per above
2. Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
3. Add Tailscale IP to `ansible/inventory/hosts.yml`
4. Run `provision-node.yml` then appropriate k3s playbook

---

## Repo Structure

```
ansible/
  inventory/hosts.yml        # all nodes
  playbooks/
    provision-node.yml       # base setup
    k3s-server.yml           # control plane install
    k3s-agents.yml           # worker join
  roles/
    common/                  # apt update + base packages
    tailscale/               # Tailscale install
    k3s-server/              # k3s server install + token fetch
    k3s-agent/               # k3s agent join
gitops/
  bootstrap/argocd/          # ArgoCD install manifests
  apps/                      # ArgoCD Application definitions
```
