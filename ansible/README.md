# Ansible

Provisions a 3-node k3s cluster on HP ProDesk Mini PCs using [k3s-ansible](https://github.com/k3s-io/k3s-ansible).

## Nodes

| Role | Host | IP |
|------|------|----|
| Control plane | worker-00 (G4) | 192.168.1.TODO |
| Worker 1 | worker-01 (G9) | 192.168.1.28 |
| Worker 2 | worker-02 (G6) | 192.168.1.TODO |

SSH user: `homelab`

## Prerequisites

Install tools:

```bash
brew install just ansible ansible-lint
pip3 install passlib --break-system-packages
```

Deploy SSH key to all nodes:

```bash
ssh-copy-id homelab@192.168.1.28
ssh-copy-id homelab@<control-plane-ip>
ssh-copy-id homelab@<worker-02-ip>
```

## First-time setup

### 1. Install Ansible dependencies

```bash
just deps
```

### 2. Fill in TODO IPs

```bash
just todos
```

Edit `ansible/inventory.yml` with real IPs for worker-00 and worker-02.

### 3. Set up vault

Generate a token:
```bash
openssl rand -hex 32
```

Create vault password file (gitignored):
```bash
echo 'your-vault-password' > .vault_pass
chmod 600 .vault_pass
```

Edit vault with token:
```bash
just vault-edit
# set: vault_k3s_token: "your-token"
```

### 4. Run

```bash
just provision
```

## Common commands

```bash
just               # list all commands
just deps          # install galaxy dependencies
just ping          # test all nodes
just provision     # full provisioning run
just dry-run       # check mode, no changes
just lint          # run ansible-lint
just vault-view    # inspect vault contents
just todos         # show remaining TODOs
```

## Structure

```
ansible/
├── inventory.yml          # Node inventory (server/agent groups)
├── site.yml               # Main playbook
├── requirements.yml       # k3s-ansible galaxy role
├── vault.yml              # Encrypted secrets (committed)
├── vault.yml.example      # Example vault structure
├── group_vars/
│   └── k3s_cluster.yml    # k3s version, flags, token ref
└── roles/
    ├── common/            # SSH hardening, UFW, unattended-upgrades
    ├── nfs_server/        # NFS export of 12TB drive on worker-01
    └── nfs_client/        # NFS mount on worker-02
```

## k3s Configuration

- CNI: Cilium (flannel disabled)
- Ingress: Envoy Gateway (traefik + servicelb disabled)
- Control plane tainted: no workloads scheduled on it
- k3s version: v1.36.2+k3s1 (Kubernetes v1.36.2)
