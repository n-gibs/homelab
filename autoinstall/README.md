# Autoinstall USB

Unattended Ubuntu Server install for homelab nodes.

## 1. Create secrets file

```bash
cp autoinstall/.secrets.example autoinstall/.secrets
```

Generate a SHA-512 password hash:
```bash
python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.hash('yourpassword'))"
```

Edit `autoinstall/.secrets` and set `PASSWORD_HASH` to the output:
```bash
PASSWORD_HASH='$6$rounds=656000$...'
```

This file is gitignored — never committed.

## 2. Build user-data

```bash
bash autoinstall/build.sh
```

Generates `autoinstall/user-data` (also gitignored) with the hash injected.

## 3. Write ISO to USB

```bash
# Find your USB disk
diskutil list

# Write ISO (replace diskN — NOT a partition like disk2s1)
sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/rdiskN bs=1m status=progress
```

## 4. Copy autoinstall files to USB

After `dd`, a partition appears in Finder:
```bash
cp autoinstall/user-data /Volumes/UBUNTU-SERVER/
cp autoinstall/meta-data /Volumes/UBUNTU-SERVER/
```

## 5. Boot node from USB

- Plug USB into node
- Power on, press **F10** (HP ProDesk) to enter boot menu
- Select USB boot device
- Installation runs unattended, node reboots when done

## 6. Run Ansible

```bash
ansible-playbook -i ansible/inventory.yml ansible/site.yml -e vault_k3s_token=<token>
```

Ansible will set the correct hostname per inventory.

## Files

| File | Description |
|------|-------------|
| `user-data.tpl` | Autoinstall template (committed) |
| `user-data` | Generated file with real hash (gitignored) |
| `.secrets` | Password hash (gitignored) |
| `.secrets.example` | Example secrets file (committed) |
| `build.sh` | Injects hash from `.secrets` into template |
| `meta-data` | Required cloud-init stub |
