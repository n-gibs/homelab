# Testing kernel updates

Unattended-upgrades installs new kernels, but a node only runs one after a reboot. These nodes rarely reboot, so a staged kernel can wait weeks and then go live on all three at once. That happened on 2026-11-16, when a power cut booted every node into 7.0.0-43 and wedged every Postgres cluster. Test each new kernel on one node, then roll it out.

`kernel_pin` in `ansible/roles/common/defaults/main.yml` sets the kernel GRUB boots by default. Newer kernels still install under the pin, so you can test them with a one-time boot.

## Test a kernel on one node

Start with worker-02. Its pods restart elsewhere, and it is neither the media node nor the kubeconfig's API endpoint.

```bash
NEW=7.0.0-44-generic   # from: ls /boot/vmlinuz-*
kubectl cordon worker-02
ssh homelab@192.168.30.136 "sudo grub-reboot 'Advanced options for Ubuntu>Ubuntu, with Linux $NEW' && sudo systemctl reboot"
kubectl wait node/worker-02 --for=jsonpath='{.status.nodeInfo.kernelVersion}'=$NEW --timeout=10m
kubectl wait node/worker-02 --for=condition=Ready --timeout=2m
```

`grub-reboot` applies to the next boot only, so another reboot returns the node to the pinned kernel.

## Check it

Give the node ten minutes with its pods running, then check:

```bash
ssh homelab@192.168.30.136 'journalctl -k -b 0 | grep -c "apparmor=\"DENIED\" operation=\"signal\""'
kubectl get clusters.postgresql.cnpg.io -A
```

A healthy kernel shows 0 or close to it; 7.0.0-43 logged thousands within the hour. Every CNPG cluster should report `Cluster in healthy state`. The `AppArmorSignalDenials` alert runs the same denial check on every node.

If it fails, reboot the node once more. It comes back on the pinned kernel.

## Roll it out

1. `kubectl uncordon worker-02`.
2. Repeat on worker-00, then worker-01, one node at a time. kubectl points at worker-00 (`192.168.30.129`), so pass `--server https://192.168.30.194:6443` while worker-00 is down.
3. Set `kernel_pin` to the new kernel, or empty it to follow the newest installed kernel, then run `just provision-common`.
4. Check that every node boots it: `sudo grep 'set default=' /boot/grub/grub.cfg | grep -v next_entry`.
