# Changelog

## v1.0.0 (2026-10-21)

First release: the role behind a homelab's Vault VM, made generic.

- Official HashiCorp apt package, pinned and held; never restarts a running Vault
- Integrated storage (Raft), self-signed listener certificate, optional proxy
  X-Forwarded-For trust
- No swap, root-owned config, ufw (refuses to enable without admin networks)
- Audit log rotation, nightly Raft snapshots with a periodic token
- CI: ansible-lint, a real deploy on the runner (idempotence, check mode, init,
  unseal, snapshot), gitleaks
