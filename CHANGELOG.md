# Changelog

Highlights are grouped by major release series. Individual patch and minor releases are intentionally omitted.

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
