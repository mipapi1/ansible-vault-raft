#!/bin/bash
# Checks a host the role just deployed: Vault is up, held and sealed; initializes a
# throwaway instance (1 key), unseals it, sets up the snapshot token as the README
# describes and runs one snapshot. Run as root on the host. Test machines only.
set -euo pipefail

export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=/opt/vault/tls/vault.crt

dpkg-query -W -f='${Status}\n' vault | grep -q '^hold ' || { echo "vault package not held" >&2; exit 1; }
systemctl is-active --quiet vault
systemctl is-active --quiet vault-snapshot.timer

for _ in $(seq 30); do
  rc=0; vault status >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && break   # 2 = sealed: up and answering
  sleep 1
done
[ "$rc" -eq 2 ] || { echo "vault status: expected sealed (2), got $rc" >&2; exit 1; }

init=$(vault operator init -key-shares=1 -key-threshold=1 -format=json)
vault operator unseal "$(jq -r '.unseal_keys_b64[0]' <<<"$init")" >/dev/null
VAULT_TOKEN=$(jq -r .root_token <<<"$init")
export VAULT_TOKEN

vault policy write raft-snapshot - >/dev/null <<'POLICY'
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
POLICY
(umask 077; vault token create -orphan -period=768h -policy=raft-snapshot -field=token \
  > /etc/vault.d/snapshot.token)
unset VAULT_TOKEN

systemctl start vault-snapshot
ls /var/backups/vault/vault-*.snap >/dev/null
journalctl -u vault-snapshot -n 1 --no-pager -o cat
echo "OK: Vault up, held, initialized, unsealed; snapshot saved"
