# kured

kured reboots nodes after unattended-upgrades installs something that needs a reboot, a new kernel included. The `unattended-upgrades` hook in `/etc/kernel/postinst.d/` writes `/var/run/reboot-required`, and kured acts on that file.

## How a rollout runs

- **Window:** 03:00–06:00 Pacific, Monday to Thursday, so you're around the morning after a reboot.
- **One node at a time:** a node takes a cluster-wide lock (an annotation on the `kured` DaemonSet), drains, reboots and uncordons. The lock stays held for 30 minutes after the node returns, then the next node may start.
- **Alerts gate it:** kured won't start a reboot while any alert other than `Watchdog` or `InfoInhibitor` is firing. A kernel that breaks the first node stops the rollout there.
- **Drains give up:** a drain stuck on a PodDisruptionBudget gives up after 30 minutes, and kured tries again next check. It never forces the reboot.

GRUB boots the newest installed kernel, so the reboot after an install is the new kernel's first run on that node.

## When a rollout stops

Check what's firing first. A kernel problem usually shows as `AppArmorSignalDenials` or CNPG alerts on the node that just rebooted.

To take that node back to its previous kernel for one boot:

```bash
ssh homelab@<node-ip> "sudo grub-reboot 'Advanced options for Ubuntu>Ubuntu, with Linux <old-version>-generic' && sudo systemctl reboot"
```

To keep every node on the old kernel until there's a fix, set `kernel_pin` in `ansible/roles/common/defaults/main.yml` and run `just provision-common`.

Don't cordon the node and then wait for its Postgres pods. CNPG volumes are `local-path`, so their pods can only run on that node and stay `Pending` until you uncordon it.

## Pause, resume, reboot on demand

```bash
# Pause: take the lock yourself
kubectl -n kured annotate ds kured weave.works/kured-node-lock='{"nodeID":"manual"}'
# Resume, or clear a lock left by a node that died mid-reboot
kubectl -n kured annotate ds kured weave.works/kured-node-lock-
# Have kured reboot a node in the next window
ssh homelab@<node-ip> 'sudo touch /var/run/reboot-required'
```
