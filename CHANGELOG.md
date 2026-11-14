# Changelog

Highlights are grouped by major release series. Individual patch and minor releases are intentionally omitted.

## 2.1.2 — Experimental macOS WireGuard/OpenVPN client backend (2026)

- Client inventories now show IP instead of creation time; live OpenVPN/AWG
  addresses take precedence over configured fixed addresses. Added detailed
  `status <client>` / `client status <gateway> <client>` including connection
  information, traffic counters, and metadata (also for managed remote clients).

- Added a separate macOS installer and Bash 3-compatible CLI for WireGuard and
  OpenVPN clients (`install/add/start/stop/status/list/run/remove/recover/dns/myip/git-via`).
  OpenVPN uses `--route-noexec` with self-contained `.ovpn` profiles (inline
  certs; no up/down scripts).
- Uses an owned kernel `utun`, IPv4 address, an interface-scoped route, and a C
  interposer for selected TCP sockets. Host default route, DNS, PF rules and
  Unix groups remain unmodified.
- `run` inserts native bind options for SIP-protected `ping`, `nc`,
  `ssh`/`scp`/`sftp`, `curl`, `wget`, `rsync`, `dig`, `traceroute` and
  `openssl s_client`; warns on unbound Apple platform tools and bare `git`
  (prefer `git-via`); `NNS_BIND_QUIET=1` suppresses warnings. Preserves
  user-supplied bind/source options and leaves localhost on the host stack.
- Added a constrained per-app IPv4 A DNS resolver through the selected VPN
  in compatible injected processes; no system DNS changes.
- Added an explicit Linux/macOS feature comparison and macOS static/mock tests.
- Linux feature implementation preserved from 2.0.16. The Darwin backend is
  experimental and has weaker process isolation than Linux namespaces.

## 2.x — Unified private networking (2026)

- Unified management of VPN apps, host-exit servers, gateways, clients and routing, including inventory, health checks, `run`, `set-via`, export and revocation.
- Added OpenVPN and AmneziaWG servers, Cloak transport, client-specific addresses, split/full routes and optional client-to-client access.
- Improved WireGuard/AmneziaWG split-tunnel support and DNS isolation: validated profile DNS settings and safe `resolvectl` hooks, namespace DNS proxy, and NSS overrides for Git/SSH hostname resolution.
- Added `git-via <app>` to route a repository's SSH connections through an NNS app, with `git-via -` to restore its prior settings.
- Added automatic gateway endpoint configuration, full-state backup/restore, safer remote upgrades and in-place server configuration reconciliation.
- Hardened private-key handling, AppArmor compatibility, kill switches, DNS routing and service lifecycle cleanup.

## 1.x — Per-application VPN namespaces (2026)

- Introduced isolated Linux network namespaces with per-app routing, DNS configuration, kill switches, and OpenVPN/WireGuard profile support.
- Added application launch and lifecycle commands, VPN Gate relay selection, status reporting and basic client profile export.
- Introduced VPN chaining, inherited namespaces, remote gateways, `.nnslink` bundles, and direct/stunnel/Cloak transports.
- Added automated remote VPN exits, SSH-forwarded private gateways, credential management and remote synchronization.
- Improved reliability with watchdogs, recovery tools, Snap/desktop compatibility, modular builds and regression tests.
