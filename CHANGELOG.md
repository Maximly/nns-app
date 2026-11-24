# Changelog

Highlights are grouped by major release series. Individual patch and minor releases are intentionally omitted.

## 2.2 — AnyConnect / OpenConnect backend (2026)

- Added a generic OpenConnect VPN backend on Linux: Cisco AnyConnect is the
  first validated protocol, and `nc`, `pulse`, `gp`, `fortinet`, `f5` and
  `array` share the same plumbing. `openconnect` runs inside the managed
  network namespace with an nns-app `vpnc-script` replacement, so pushed
  addresses, MTU, routes and DNS stay namespace-local and the host network
  stack is untouched. `nns-app add` accepts `.oc` key=value profiles
  (`server=`, `user=`, `passwd=` (alias `password=`), `authgroup=`,
  `fingerprint=` (`SHA1:`/`SHA256:` hex pins and openconnect's own
  `pin-sha256:` base64 form), `token-mode=`/`token-secret=`, `route-mode=`,
  `mtu=`, inline `<cert>`/`<key>` blocks); anything else is rejected as
  untrusted input.
- Added `nns-app oc-login <app>`: interactive `openconnect --authenticate`
  (password, push or OTP prompts) stores a session cookie for unattended
  restarts; the backend prefers the cookie, then inline credentials, and the
  data-path watchdog records `auth-required` instead of looping on expired
  sessions. TOTP/HOTP secrets let gateways with one-time codes restart
  without interaction.
- Kill-switch endpoint pinning, split-tunnel handling, MTU auto-repair,
  watchdog, status diagnosis (`AnyConnect state`, DTLS, tunnel DNS,
  authentication mode), `myip`/`myloc`, `list` (`vpn-client/oc`) and
  VPN chaining all support the new backend. OpenVPN remains the only
  default-installed protocol; WireGuard and OpenConnect tools are add-ons
  installed on demand with `nns-app --install wireguard` /
  `nns-app --install openconnect` (mirroring the existing
  `--install amnezia`), and `nns-app add` suggests the matching command
  when a profile's backend binaries are missing. On macOS `install_macos`
  likewise no longer installs openconnect; `add`/`start` point at
  `brew install openconnect`.

  The macOS backend gained engine-aliveness guards: a dead VPN engine
  (its utun is gone) is reported as STALE instead of "started", `run`
  refuses stale or utun-reused state instead of routing through the wrong
  tunnel, and `nns-app run`/`git-via` restart a stale app automatically
  via passwordless sudo before executing the command.
- macOS: AnyConnect support with `openconnect` (Homebrew), a managed `utun`,
  `/32` address confinement, interface-scoped routes for pushed split
  networks, a generated hook instead of `vpnc-script` (no host DNS/route
  changes), `oc-login`, and pushed-DNS hand-off to the per-app resolver.

## 2.1.7 — Experimental macOS WireGuard/OpenVPN client backend (2026)

- Client inventories now show IP instead of creation time; live OpenVPN/AWG
  addresses take precedence over configured fixed addresses. Added detailed
  `status <client>` / `client status <gateway> <client>` including connection
  information, traffic counters, and metadata (also for managed remote clients).

- Added a separate macOS installer and Bash 3-compatible CLI for WireGuard and
  OpenVPN clients (`install/add/start/stop/status/list/run/remove/recover/dns/myip/myloc/git-via`).
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
- Added macOS `myloc` for host or per-app egress via `ip-api.com`, and made
  `myip` optional-name (host by default, app when named). App probes still
  require Internet egress through the VPN profile. Public probe hostnames are
  resolved on the host and passed to `curl --resolve`, so an unrouted private
  VPN DNS address does not hide a working public exit.
- `myloc` on Linux and macOS now falls back to the `ipwho.is` HTTPS
  geolocation endpoint when the primary `ip-api.com` probe is unreachable or
  rate-limited, and reports which provider answered. Probe endpoints are
  overridable via `NNS_MYLOC_URL` and `NNS_MYLOC_FALLBACK_URLS`. The provider
  that last answered for a given egress (network namespace or macOS app) is
  remembered and tried first on later runs.
- Private-only gateways: an OpenVPN gateway whose `--via` upstream is a
  split-tunnel app with the kill switch enabled no longer pushes
  `redirect-gateway`; it inherits the upstream's private networks and DNS
  policy (servers and split-DNS domains) into server pushes and exported
  client profiles (marked `nns-app private-only`). On client hosts such
  profiles classify as split tunnels, so start readiness, the watchdog
  (`ready-split`), status and the namespace split-DNS proxy use client-side
  routes instead of demanding public Internet connectivity.
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
