#cloud-config
autoinstall:
  version: 1

  locale: en_US.UTF-8
  timezone: America/Los_Angeles
  keyboard:
    layout: us

  identity:
    hostname: homelab-node
    username: homelab
    password: "PASSWORD_HASH"

  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOUfG0kPgLGCrd2YHwp0/eV+KbZ2H/oXnZ9JoLfrYWWE"

  storage:
    layout:
      name: lvm
      sizing-policy: all  # use entire disk

  packages:
    - curl
    - git
    - vim
    - openssh-server

  user-data:
    disable_root: true

  late-commands:
    # ensure SSH starts on boot
    - curtin in-target --target=/target -- systemctl enable ssh
