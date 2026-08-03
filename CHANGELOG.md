# Changelog

## 1.2.1

- Fixed `nns-app run` exiting silently before launching the command. The internal namespace guard used `readlink` on `/run/netns/<name>`, but iproute2 stores named namespaces as mounted namespace references rather than symbolic links.
- Namespace identity is now compared through the followed namespace filesystem device and inode, with explicit diagnostics when either reference cannot be inspected.
- Added regression coverage for namespace-reference identity and rejection of the broken `readlink /run/netns/...` pattern.

## 1.2.0

- Added `VPN_TYPE="inherit"` and `install <app> --backend inherit --via <upstream>` for isolated child namespaces that share one existing nns-app tunnel without starting another VPN client.
- Kept inherit children inside the existing systemd dependency graph, readiness checks, dependent shutdown, exact veth rules, and upstream tunnel-only forwarding/NAT path.
- Added SSH remote registration and management: `remote add`, `remote connect`, `remote sync`, `remote rotate`, and `remote status`.
- Pinned each remote SSH host key in a root-owned per-remote `known_hosts` file; management requires batch SSH and non-interactive remote sudo, while the runtime VPN path remains independent of SSH.
- Added generation-aware transactional gateway client rotation, including new client certificate, private key, TLS Crypt v2 key, and Cloak UID where applicable.
- Added gateway transports `direct`, `stunnel`, and `cloak`. Wrapped gateways expose the transport publicly and bind the OpenVPN server to a private loopback TCP port; Cloak supports a validated, non-looping decoy hostname through `--server-name`.
- Added versioned `.nnslink` export/import bundles containing a self-contained OpenVPN profile plus the minimum transport configuration and trust material.
- Added strict bundle validation against path traversal, links, devices, unknown members, oversized payloads, unsafe manifest metadata, malformed Cloak settings, invalid stunnel CA material, and unsupported versions/transports.
- Added transport-aware endpoint pinning and kill-switch rules in local namespaces, explicit Cloak remote-host/port invocation, plus supervised startup/teardown of the wrapper and OpenVPN processes.
- `remote sync` and `remote rotate` now rebuild a running local namespace after importing changed endpoint or transport state.
- Extended app/gateway status, help, README, contributor invariants, and tests for inherit, remote management, transport state, and `.nnslink` safety.

## 1.1.27

- Replaced root-specific and `Downloads` profile paths in README and command
  help examples with paths in the invoking user's home directory, such as
  `~/my-base-profile.ovpn` and `~/my-remote-profile.ovpn`.
- Documented that the shell expands `~` before `sudo`, imported profiles are
  copied into root-owned managed storage, and exported gateway profiles are
  returned to the invoking user with mode `0600`.
- Updated gateway client-enrollment guidance to export profiles directly to
  the invoking user's home directory.
- Added static regression checks that reject `/root/` and desktop-specific
  `~/Downloads/` paths in public documentation, command help, or the generated
  installer.
- No networking, routing, VPN, firewall, systemd, or PKI behavior changed.

## 1.1.26

- Fixed unprivileged `make test`: function tests now use a private temporary
  lock directory instead of trying to create root-owned `/run/lock/nns-app`.
- Restricted the lock-directory override to source-only test mode; normal
  execution always uses the fixed root-owned system lock directory.
- Added lock-directory ownership, permission, and symlink validation.
- Removed a second root-only assumption in CA snapshot tests: temporary CA
  backup directories now preserve strict permissions without forcing root
  ownership in source-only test mode.
- Consolidated function-test temporary files under one cleanup trap.
- Documented that the complete test suite runs without root privileges.

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
