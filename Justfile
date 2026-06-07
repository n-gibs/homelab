inventory := "ansible/inventory.yml"
vault_pass := ".vault_pass"
playbook := "ansible/site.yml"

# List available commands
default:
    @just --list

# Install Ansible Galaxy dependencies
deps:
    ansible-galaxy install -r ansible/requirements.yml

# Test connectivity to all nodes
ping:
    ansible -i {{inventory}} all -m ping --vault-password-file {{vault_pass}}

# Test connectivity to a single host: just ping-host worker-01
ping-host host:
    ansible -i {{inventory}} {{host}} -m ping

# Run full provisioning playbook
provision:
    ansible-playbook -i {{inventory}} {{playbook}} --vault-password-file {{vault_pass}}

# Run only the common role (base hardening)
provision-common:
    ansible-playbook -i {{inventory}} {{playbook}} --vault-password-file {{vault_pass}} --tags common

# Run only NFS roles
provision-nfs:
    ansible-playbook -i {{inventory}} {{playbook}} --vault-password-file {{vault_pass}} --tags nfs

# Dry-run (check mode)
dry-run:
    ansible-playbook -i {{inventory}} {{playbook}} --vault-password-file {{vault_pass}} --check

# View encrypted vault contents
vault-view:
    ansible-vault view ansible/vault.yml --vault-password-file {{vault_pass}}

# Edit encrypted vault
vault-edit:
    ansible-vault edit ansible/vault.yml --vault-password-file {{vault_pass}}

# Build autoinstall user-data from template + secrets
build-usb:
    bash autoinstall/build.sh

# Run ansible-lint
lint:
    ansible-lint ansible/site.yml

# Show TODOs remaining (IPs to fill in)
todos:
    @grep -rn "TODO" ansible/ autoinstall/
