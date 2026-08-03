# Changelog

## 1.1.25

- Replaced unexplained example names with a consistent descriptive naming set:
  `my-private-app`, `my-upstream-vpn`, `my-remote-exit`, `my-relay`,
  `my-linux-client`, and `my-remote-profile.ovpn`.
- Removed deployment-specific names from public help, README examples, tests,
  source comments, and the generated installer.
- Rewrote the README for terminology consistency and separated direct,
  chained, and remote-gateway workflows.
- Replaced the partly duplicated `ARCHITECTURE.md` with the standard
  `CONTRIBUTING.md`; the README now owns user-facing architecture while the
  contributor guide owns implementation invariants.
- Audited source comments so they explain safety invariants, compatibility
  constraints, and non-obvious lifecycle behavior instead of private history.
- Removed an obsolete gateway section marker left at the end of the runtime
  module.
- No networking or PKI data-path behavior changed in this build.

## 1.1.24

- Reorganized the source into ordered modules under `src/`.
- Added `./build.sh` and `make build` to generate `nns-app-install.sh`.
- Included a pre-built `nns-app-install.sh`.
- Added deterministic build, Bash syntax, embedded-Python, and helper tests.
- Added reference-counted process-wide and per-gateway `flock` locking.
- Reset and validate every app, gateway, and client configuration field before
  sourcing root-owned config files.
- Added direct and indirect `--via` cycle detection.
- Added `nns-online@.service` and generated systemd dependency drop-ins for
  chained apps and gateways.
- Added collision-aware app, client-pool, transit-network, route-table, and
  policy-priority allocation using live routes and existing configs.
- Replaced broad policy-rule deletion and route-table flushing with exact,
  ownership-checked cleanup.
- Replaced the gateway source-only policy rule with an incoming-interface rule
  bound to the gateway TUN.
- Added migration cleanup for the 1.0.23 source-only gateway rule.
- Added dedicated tagged gateway firewall chains and source-restricted drops.
- Added loose `rp_filter` only on managed asymmetric gateway interfaces.
- Corrected OpenVPN status v3 parsing to use tab-separated records.
- Added exact listener/PID, veth, policy-route, firewall-chain, CRL, and
  upstream checks to gateway status.
- Added atomic weekly CRL refresh through a timer enabled immediately on install.
- Made gateway creation, client enrollment, revocation, and CA database updates
  transactional, with rollback of CA state and staged filesystem changes.
- Added OpenVPN 2.6 minimum-version enforcement.
- Prevented removal of apps still referenced by another app or gateway.
- Added contributor-facing safety and ownership invariants (moved to `CONTRIBUTING.md` in 1.1.25).
- Updated and reorganized the README; removed the experimental-status label.

## 1.0.23

- Added managed remote OpenVPN gateways.
- Added per-client X.509 certificates, TLS Crypt v2 keys, export, list, and
  revoke commands.
- Added policy routing from the remote gateway into a selected NNS exit.

## 1.0.22

- Added `nns-app status <app>`.
- Added OpenVPN handshake-stage diagnosis, WireGuard handshake/transfer
  details, and focused current-invocation log cuts.

## 1.0.21

- Added WireGuard client-profile support.
- Added WireGuard status, endpoint pinning, kill switch, and `--via` chaining.

## 1.0.20

- Added real runtime `--via` chaining between local NNS namespaces.
- Added veth, forwarding, NAT, MSS clamping, upstream lifecycle, and
  kill-switch handling.

## 1.0.19

- Fixed Snap GUI launches inside `ip netns exec` by preparing cgroup v2 and
  securityfs in the private command mount namespace.

## 1.0.18

- Increased VPN Gate cache TTL to two days.
- Increased candidate attempts and probe timeout.
- Added pool-size and failed-batch diagnostics.

## 1.0.17

- Added live OpenVPN candidate probing before importing VPN Gate profiles.

## 1.0.16

- Added persistent round-robin rotation through the top VPN Gate candidates.

## 1.0.15

- Added engine-only `install` without requiring an app name.

## 1.0.14

- Fixed exact two-letter VPN Gate country-code matching.
- Fixed stale namespace cleanup ordering.

## 1.0.13

- Added VPN Gate CSV caching, stale-cache fallback, explicit refresh, and
  improved startup logs.

## 1.0.12

- Normalized CRLF/CR line endings and hardened endpoint validation.

## 1.0.11

- Added asynchronous `start -i`.

## 1.0.10

- Added `add <app> any [country]` with VPN Gate selection.

## 1.0.9

- Added transactional strict startup and cleanup after timeout.

## 1.0.8

- Added initial VPN readiness waiting.
