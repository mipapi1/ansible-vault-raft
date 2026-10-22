# ansible-vault-raft

Ansible role for **HashiCorp Vault on a dedicated VM**, the simple way: the official
apt package, systemd, integrated storage (Raft). No containers, no Consul.

It's the role behind a homelab's Vault, which everything else depends on (External
Secrets in Kubernetes, Terraform, Ansible lookups). So it needs **no secrets and no
Vault login to run**: it has to work when Vault itself is down.

## What it does

- **Installs the official package, pinned and held.** `apt upgrade` and
  unattended-upgrades never touch Vault; a new version is installed by changing
  `vault_version`, and only runs after a restart you choose.
- **Never restarts a running Vault.** A restart seals it. Config and version changes
  are installed, then a handler reminds you to restart and unseal. The listener
  certificate is the exception: Vault picks a new one up on `SIGHUP` without sealing.
- **Raft storage**, single node, in `/opt/vault/data`.
- **TLS on the listener** with a self-signed certificate (the node's name and IP, the
  `vault_api_addr` host, 127.0.0.1). Put a proxy with a public certificate in front, or
  use it directly.
- **Hardening** from HashiCorp's
  [production hardening guide](https://developer.hashicorp.com/vault/docs/concepts/production-hardening):
  the package's sandboxed systemd unit (runs as `vault`, core dumps off), config and
  certificates root-owned and read-only to Vault, no swap (`disable_mlock = true` is the
  recommendation for Raft), ufw allowing only SSH and :8200 from your admin networks.
- **Audit log rotation** (logrotate, Vault reopens the file on reload).
- **Nightly Raft snapshots** by a systemd timer, with a periodic token that renews
  itself, old snapshots pruned. Snapshots are encrypted by Vault: useless without the
  unseal keys.

## Usage

```yaml
# requirements.yml
roles:
  - name: vault_raft
    src: https://github.com/mipapi1/ansible-vault-raft.git
    version: v1.0.0
collections:
  - name: community.general   # ufw
  - name: community.crypto    # certificate
```

```yaml
# site.yml
- hosts: vault
  become: true
  roles:
    - role: vault_raft
      vars:
        vault_api_addr: https://vault.example.com     # what clients use
        vault_proxy_addrs: ["192.168.20.1"]           # trust X-Forwarded-For from the proxy
        vault_admin_networks: ["192.168.30.0/24"]     # SSH + :8200; include where Ansible runs
```

```bash
ansible-galaxy install -r requirements.yml
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

Supported: Ubuntu 22.04/24.04, Debian 12/13. Ansible >= 2.17.

## Variables

| Variable | Default | |
|---|---|---|
| `vault_version` | `1.21.4` | Package version (without `-1`) |
| `vault_api_addr` | `https://<vault_ip>:8200` | Address clients use |
| `vault_cluster_addr` | `https://<vault_ip>:8201` | Required by Raft, even on one node |
| `vault_node_id` / `vault_ip` | hostname / default IPv4 | Raft node ID, certificate |
| `vault_proxy_addrs` | `[]` | Proxies whose `X-Forwarded-For` Vault trusts |
| `vault_firewall` | `true` | Manage ufw |
| `vault_admin_networks` | `[]` | **Required with the firewall:** networks allowed to SSH and reach :8200 |
| `vault_data_dir` / `vault_tls_dir` / `vault_log_dir` | `/opt/vault/data` / `/opt/vault/tls` / `/var/log/vault` | |
| `vault_audit_log_keep_days` | `14` | |
| `vault_service_enabled` | `true` | `false`: install and configure only (e.g. before moving data in) |
| `vault_snapshot_dir` | `/var/backups/vault` | |
| `vault_snapshot_on_calendar` | `*-*-* 20:30:00` | Before the VM's own backup |
| `vault_snapshot_keep_days` | `14` | |

## After the first deploy

Initialize and unseal (keep the keys and root token in a password manager):

```bash
export VAULT_ADDR=https://<node>:8200 VAULT_CACERT=<copy of /opt/vault/tls/vault.crt>
vault operator init          # 5 keys, threshold 3
vault operator unseal        # three times, three different keys
```

**Snapshots** need a token on the host. Created by an admin, it goes straight from
Vault to the host over SSH, never onto the screen:

```bash
vault policy write raft-snapshot - <<'EOF'
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
EOF
vault token create -orphan -period=768h -policy=raft-snapshot -field=token \
  | ssh <node> 'sudo sh -c "umask 077; cat > /etc/vault.d/snapshot.token"'
ssh <node> 'sudo systemctl start vault-snapshot && sudo journalctl -u vault-snapshot -n 3 --no-pager'
```

**Audit log** (stored in Vault, so it moves with the data):

```bash
vault audit enable file file_path=/var/log/vault/audit.log
```

If an enabled audit device can't write, Vault refuses requests: watch the disk.

## Upgrade

1. Read the upgrade notes for every version in between.
2. Take a snapshot: `sudo /usr/local/sbin/vault-snapshot`.
3. Set `vault_version`, run the playbook.
4. `sudo systemctl restart vault`, unseal, check `vault status` shows the new version.

## Restore

A restore needs a running, unsealed Vault. On a fresh node, initialize a throwaway
instance (`vault operator init -key-shares=1 -key-threshold=1`), unseal it, log in with
its root token, then:

```bash
vault operator raft snapshot restore -force vault-YYYY-MM-DD_HHMM.snap
```

Vault seals again: unseal with the **original** keys. The throwaway key and token are
gone with the data they belonged to.

## Testing

CI deploys the role for real on a GitHub runner VM, deploys again (must change
nothing), runs check mode (must change nothing), then initializes a throwaway Vault,
unseals it and takes a snapshot ([`tests/verify.sh`](tests/verify.sh)). Plus
ansible-lint (production profile) and a secret scan.

## License

MIT
