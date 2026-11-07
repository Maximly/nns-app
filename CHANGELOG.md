# Changelog

Major milestones are grouped by capability. Maintenance-only releases are not listed separately.

## 2.0.1 — Unified VPN and namespace management (2026-11-07)

- Unified the local inventory of application namespaces, public VPN servers, managed gateways and exported client identities, with filtered views and detailed health reporting.
- Added host-based OpenVPN servers with UDP or TCP listeners, per-client certificates, revocation, fixed server-assigned IPv4 addresses, independent split/full routing and optional client-to-client forwarding.
- Added Cloak-protected OpenVPN server transport, per-client Cloak credentials and paired client configuration exports.
- Added AmneziaWG 3.1 host servers, randomized obfuscation parameters, fixed peer allocations, native split/full client exports and peer revocation.
- Extended WireGuard and AmneziaWG client import to preserve IPv4 split-tunnel routes and AmneziaWG 3.1 header-protection settings.
- Added full-state backup and restore with archive validation, credential preservation and recovery of managed systemd service state.
- Protected destination hosts against remote-bootstrap downgrades and supported in-place server configuration reconciliation without replacing client credentials.

## 1.3 — Automatic remote application exits

- Introduced `install <app> via --remote <user@host>` for remotely provisioned VPN exits with a private, SSH-forwarded gateway.
- Added automated provider-profile deployment, unique gateway/client enrollment, remote runtime synchronization, credential rotation and supervised reconnect behavior.
- Added client profile export and revocation for remotely managed public OpenVPN access.
- Consolidated local and remote runtime status, external exit-IP inspection, repair and inventory reporting.

## 1.2 — Chaining, remote gateways and recovery

- Introduced inherited namespaces and multi-hop chaining, with dependency-aware startup/shutdown and protection against host-uplink fallback.
- Added manually managed remote hosts, OpenVPN gateways, `direct`/`stunnel`/`cloak` transports and versioned `.nnslink` bundles.
- Added adaptive data-path watchdogs, network-namespace recovery and safer desktop/Electron/Snap launch support.
- Strengthened remote SSH trust, bundle import validation and credential rotation.

## 1.1 — Reliability and packaging

- Split the implementation into ordered source modules, added a deterministic single-file installer build and regression tests.
- Improved network and policy-route allocation, resource ownership, firewall isolation, DNS handling and startup diagnosis.
- Added transactional gateway certificate issuance/revocation, service dependency management, OpenVPN version checks and CRL renewal.
- Improved privilege handling and application launcher behavior.

## 1.0 — Per-application VPN namespaces

- Introduced per-app Linux network namespaces with veth routing, DNS isolation and kill switches.
- Added OpenVPN and WireGuard client profiles, application launch helpers, start/stop/status commands and optional VPN Gate relay selection.
- Added upstream-gateway routing, per-client OpenVPN certificates and initial public profile export.
