# Changelog

## 1.3.5

- Fixed managed gateway startup under OpenVPN: `--up` appends TUN metadata arguments after the configured command arguments, so the internal callback now accepts and ignores those extra values instead of rejecting the valid invocation.
- Remove stale uniquely named managed TUN interfaces during gateway teardown and before reconciled retries.
- Tightened managed gateway private-key permissions to root-only, eliminating OpenVPN's group/other-access warning.

## 1.3.4

- Fixed managed OpenVPN gateways with custom `ngw...` interface names by emitting `dev-type tun` before `dev`.
- Gateway startup now detects systemd auto-restart immediately, prints the relevant journal, and stops the failed unit instead of leaving an endless restart loop.
- Automatic-remote deployment now reports a precise gateway-start failure while preserving the working remote provider exit for an idempotent retry.
- Removed obsolete `persist-key` from newly generated managed OpenVPN server and client profiles.

## 1.3.3

- Fixed managed gateway creation always failing during staging: `openssl crl` does not support the certificate-only `-checkend` option, so every freshly generated CRL was rejected even though it was valid.
- Added a portable CRL lifetime check based on `openssl crl -nextupdate` and GNU `date`; gateway startup now refreshes CRLs only when they are actually close to expiration.
- Gateway creation now identifies the failed staging phase instead of returning only a generic cleanup error.
- Automatic-remote uploads now retain the sanitized provider profile name instead of inheriting the random `mktemp` prefix.

## 1.3.2

- Automatic remote environments now report a clear pending-profile state after `install ... via --remote ...` and before `add` deploys a provider profile.
- `start` and auto-starting `run` now print the exact required `nns-app add <app> <profile>` command instead of the misleading generic backend-detection error.
- `status` reports `Health: PENDING` and `Backend: pending remote deployment` for this intentional intermediate state.

## 1.3.1

- Fixed automatic remote deployment losing all arguments after `_remote-auto deploy`. The global newline/tab `IFS` made `${array[*]}` join quoted arguments with newlines, so the remote shell executed only the first line. Remote command payloads now use an explicit space-delimited, shell-quoted builder.
- Fixed app installation executing backticked command names embedded in the generated configuration heredoc, which produced misleading `add`, `link import`, and `remote` errors even though installation continued.
- Added regression coverage for exact remote argument preservation, spaces and shell metacharacters, and executable-free configuration generation.

## 1.3.0

- Added a three-command automatic remote workflow: `install <app> via --remote <user@host>`, `add <app> <provider-profile>`, and `run <app> <command>`.
- Bootstrap or upgrade the same nns-app engine on the remote host over the user's existing SSH access, install a dedicated root-owned deployment key, pin the remote host key, and create a restricted `_remote-auto` sudo entry.
- Deploy the provider OpenVPN or WireGuard profile into a hidden remote exit environment, create and start a private managed OpenVPN gateway, enroll a unique client, and import the generated `.nnslink` locally without exposing the internal objects to the normal workflow.
- Added an SSH-forward gateway transport. The remote OpenVPN listener binds only to `127.0.0.1`; a supervised local SSH forward uses the already reachable SSH port, so no cloud firewall or extra public listener is required.
- Automatic remote `run` starts a stopped environment on demand. Existing manual `remote`, `gateway`, transport, and `.nnslink` commands remain available for fine tuning.
- Extended synchronization, credential rotation, status, configuration metadata, endpoint pinning, tests, and documentation for automatic remote deployments.

## 1.2.5

- Added an adaptive per-environment data-path watchdog for OpenVPN and WireGuard.
- Start the watchdog timer only while a supported environment is running; inherit-only children defer recovery to their upstream.
- Arm recovery only after the environment has been online once, then require three consecutive failed namespace probes before restarting only the VPN backend; slow initial connections are not interrupted.
- Defer child recovery while its configured upstream is offline and enforce a five-minute restart cooldown to avoid restart loops.
- Added `WATCHDOG_MODE`, `WATCHDOG_FAILURES`, and `WATCHDOG_COOLDOWN` configuration plus watchdog state and restart attempts in `nns-app status`.

## 1.2.4

- Preserve an explicit allow-list of desktop-session variables across the sudo and `env -i` boundaries used by `nns-app run`.
- Restore Electron/Chromium detection of GNOME Keyring and KWallet when applications are launched inside an nns-app namespace.
- Regenerate existing per-app sudoers rules during engine upgrades so the expanded environment allow-list is active without reinstalling each app.
- Keep dangerous loader and shell-startup variables excluded; the launched process still receives a clean environment.

## 1.2.3

- Limited command-local cgroup2 and securityfs preparation to Snap launches.
- Ordinary CLI commands and non-Snap desktop applications now enter only the
  requested network namespace and resolver mount context.
- Kept Cursor/Electron AppArmor user-namespace handling separate from Snap
  mount preparation.

## 1.2.2

- Fixed `nns-app run` aborting before command execution when preparing `/sys/fs/cgroup` and `/sys/kernel/security`. The launcher no longer attempts to chmod kernel-managed virtual-filesystem directories.
- Added a static regression check preventing `install -d -m` from being reintroduced for these paths.

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
