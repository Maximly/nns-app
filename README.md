# nns-app

**Per-application private networking on Linux, with an experimental macOS VPN client backend.**

On Linux, `nns-app` creates isolated network namespaces and connects them through
OpenVPN, WireGuard, AmneziaWG, other NNS applications, or managed VPN gateways.
Applications retain their user privileges and receive namespace-local routes, DNS
and a kill switch. On macOS, the **IPv4 WireGuard and OpenVPN client subset**
is available: a managed kernel `utun`, interface-scoped route and an opt-in C
socket interposer. The macOS backend is **not a network namespace or a security
sandbox**.

**Current release:** 2.1.2 · **License:** GPL-3.0-or-later · **Platforms:** Linux with systemd (Ubuntu and Fedora tested); experimental macOS WireGuard/OpenVPN TCP client · **Network stack:** IPv4

## Contents

- [Linux vs macOS feature compatibility](#linux-vs-macos-feature-compatibility)
- [macOS install and quick start](#macos-install-and-quick-start)

- [Capabilities](#capabilities)
- [Install and upgrade](#install-and-upgrade)
- [Quick start](#quick-start)
- [Client workflows](#client-workflows)
  - [WireGuard and private DNS](#wireguard-and-private-dns)
  - [Git over a private VPN](#git-over-a-private-vpn)
  - [VPN chaining and inherited networks](#vpn-chaining-and-inherited-networks)
  - [Remote VPN exit](#remote-vpn-exit)
- [VPN servers and gateways](#vpn-servers-and-gateways)
  - [OpenVPN server](#openvpn-server)
  - [VPN-backed gateway](#vpn-backed-gateway)
  - [Cloak transport](#cloak-transport)
  - [AmneziaWG server](#amneziawg-server)
  - [Client management](#client-management)
- [Operate and troubleshoot](#operate-and-troubleshoot)
- [Backup and restore](#backup-and-restore)
- [Security and limitations](#security-and-limitations)
- [Build and contribute](#build-and-contribute)

## Linux vs macOS feature compatibility

**Linux behavior is unchanged in 2.1** apart from the version number and an
explicit guard preventing the Linux installer from executing on macOS.
The macOS backend is a separate implementation, not a fork of Linux modules.

| Feature / command | Linux (systemd) | macOS |
| --- | --- | --- |
| `install <app>`, `add <app> profile` | Supported | Supported for **WireGuard `.conf`** and **OpenVPN `.ovpn`** |
| `start`, `stop`, `status`, `list`, `remove` | Supported | Supported; `start/stop/recover` require `sudo` |
| `run <app> command` | General Linux network namespace | **Compatible unsandboxed IPv4 executables only**: DYLD interposition for TCP, plus native bind options for `ping`, `nc`, `ssh`/`scp`/`sftp`, `curl`, `dig` and `traceroute` |
| Host network impact | Host default route unchanged; namespace/veth/firewall infrastructure | Default route and DNS unchanged; **creates system-visible `utun` + interface-scoped route** |
| VPN clients: WireGuard | Supported | Supported (`wireguard-go`, `wg`, `wg-quick strip`) |
| VPN clients: OpenVPN | Supported | Experimental client (`openvpn --route-noexec`; inline certs only) |
| VPN clients: AmneziaWG | Supported | Not implemented |
| Separate namespace / routing domain | True Linux `ip netns` | **No**: shared macOS kernel network stack |
| Per-app routing | Namespace routes | `IP_BOUND_IF` + source IP + interface-scoped route for intercepted TCP; native source/interface binding for supported SIP tools |
| DNS isolation | Namespace-specific resolver and NSS policy | Limited IPv4 A queries in injected `getaddrinfo()`, via optional VPN DNS; no host DNS changes |
| DNS search domains, CNAME chains, IPv6/AAAA, DNS-over-TCP | Linux resolver behavior | Not fully implemented; DNS responses containing an A record supported |
| UDP / ICMP / IPv6 app traffic | IPv4 UDP/ICMP via namespace; IPv6 policy depends on settings | No general routing or isolation. `ping`, `traceroute`, `nc` and `dig` work only through their native bind options; IPv6 is unsupported. |
| `git-via <app|->` (SSH) | Supported | Supported for compatible **Homebrew OpenSSH**; Apple-protected SSH unsupported |
| Git via HTTPS | `nns-app run <app> git ...` | Experimental with compatible Homebrew Git/curl and configured private DNS |
| `myip` | Supported | Supported only if VPN `AllowedIPs` and gateway permit Internet egress |
| `myloc` | Supported | Not implemented |
| VPN chaining, inherited networks, `set-via` | Supported | Not implemented |
| Managed OpenVPN/AWG servers and gateways | Supported | Not implemented |
| Remote exit, `.nnslink`, clients, export/revoke | Supported | Not implemented |
| Backup/restore, repair, watchdog, timers | Supported | Not implemented; macOS has limited `recover` cleanup command |
| Kill switch / network leak prevention | Namespace-based policy enforcement | **Not guaranteed**: SIP tools without a bind option and child processes can bypass the launcher |
| Firewall modifications | Per-namespace/system integration | **None (no PF)** |
| System DNS modifications | None; namespace-specific DNS | None; resolver hook only within compatible injected processes. SIP tools use the system resolver. |

### macOS install and quick start

The macOS installer is created on macOS, once per target architecture:
`./build.sh` compiles `nns-run` and `libnnsbind.dylib`, then embeds the binaries
and Darwin CLI in a **single executable `install_macos`** next to `build.sh`.
Installing it requires no sources, compiler or build step. Homebrew is the
prerequisite for runtime dependencies (`wireguard-go`, `wireguard-tools`,
`openvpn`, Homebrew curl and OpenSSH), which `install_macos` installs when
missing. The Linux-built release ZIP contains `install_linux`; run `./build.sh`
on your Mac to produce its platform-specific `install_macos` (do not copy a
Linux or other-architecture binary in its place).

WireGuard profiles need an IPv4 `[Interface] Address` and peer `AllowedIPs` that
cover the private destination. OpenVPN profiles must be self-contained `.ovpn`
files with inline certificates/keys (no `up`/`down` scripts); `start` runs
`openvpn --route-noexec` so pulled routes do not replace the host default.
Do not reuse the same tunnel IP for two managed instances.

```bash
# On macOS, only when the prebuilt install_macos is not already provided:
./build.sh
sudo ./install_macos
nns-app --version

nns-app install work-vpn
nns-app add work-vpn ~/work-wg.conf    # or ~/work.ovpn
# If profile DNS is absent, specify the reachable VPN resolver:
nns-app dns work-vpn 10.3.1.1
sudo nns-app start work-vpn
nns-app status work-vpn
nns-app run work-vpn /opt/homebrew/opt/curl/bin/curl -4 -vk https://gitlab.example.internal/
# SIP-protected tools receive their native bind option automatically.
# Prefer numeric addresses: hostname lookup in these tools still uses the host resolver.
nns-app run work-vpn ping -c 3 10.3.1.10
nns-app run work-vpn nc -vz 10.3.1.10 22
nns-app run work-vpn ssh user@10.3.1.10
sudo nns-app stop work-vpn
```

`install` creates a user-owned configuration directory under
`~/Library/Application Support/nns-app/apps/`; `add` copies the profile with
permissions `0600`. `start` brings up WireGuard (`wireguard-go`) or OpenVPN,
records the tunnel IPv4/`utun`, and adds **only** a route scoped to that
interface. It does **not** execute profile shell hooks, change the unscoped
default route, enable PF, create Unix groups, or modify host DNS. Runtime
metadata is under `/var/run/nns-app-macos/<uid>/`. `stop` removes the scoped
route **before** closing the tunnel. If interrupted,
`sudo nns-app recover <app>` retries cleanup.

`nns-app run` must be invoked **without sudo**. The C helper sets `IP_BOUND_IF`
and binds the selected VPN IPv4 source on supported `connect()` sockets.
The DNS hook intercepts `getaddrinfo()` and sends IPv4 A queries to the
per-app VPN resolver, when configured. If no private DNS server is configured,
non-numeric non-localhost hostname lookup fails rather than falling back to
host DNS within compatible processes. It does not implement system-wide DNS,
DNS search suffixes, DNS TCP fallback, or a universal DNS leak blocker.

Apple SIP-protected platform binaries ignore `DYLD_INSERT_LIBRARIES`, so the
launcher also understands the native bind switches of common network tools:
`ping` and `nc` get `-b <utun>`, `ssh` gets `-b <vpn-ip>`, `scp`/`sftp` get
`-o BindAddress=<vpn-ip>`, `curl` gets `--interface <utun>`, `wget` gets
`--bind-address=<vpn-ip>`, `rsync` gets `--address=<vpn-ip>`, `dig` gets
`-b <vpn-ip>`, `traceroute` gets `-s <vpn-ip>`, and `openssl s_client` gets
`-bind <vpn-ip>:0`. These options make the tool's own socket use the
interface-scoped route, which is why `nns-app run work-vpn /sbin/ping 10.3.1.10`
works without injection. A bind or source option supplied by the user is
preserved, and loopback/link-local/multicast destinations are left on the host
stack. `ping6` and `traceroute6` are rejected because the backend is IPv4-only.
Apple platform binaries without a known bind option (`host`, `nslookup`,
`telnet`, most GUI apps) print a warning and still use ordinary host
connectivity; set `NNS_BIND_QUIET=1` to hide that warning. Shell scripts that
spawn commands, Network.framework clients, and child helpers are also unbound.

For Git over SSH, use a compatible Homebrew OpenSSH binary rather than
Apple's protected `/usr/bin/ssh`:

```bash
cd ~/src/private-repo
git-via work-vpn
git pull
git-via -           # restore prior repository-local SSH command
```

Apple System Integrity Protection/hardened executables, apps using different
socket APIs, child helper services and traffic without a native bind option
may ignore this launcher and use ordinary host connectivity. SIP-protected
tools also use the macOS resolver for hostnames; use numeric addresses or a
compatible Homebrew client when private DNS matters. **Do not interpret
`nns-app run` on macOS as secure or fail-closed isolation** until an OS-level
interception and blocking backend has been implemented and verified.
Start/stop may also send system network-change notifications because `utun`
exists in the shared stack.

Do not run `install_linux` on macOS: it is a Linux-only installer.
The release provides OS-specific installers; `build.sh` generates **only the
installer for its current OS**. Prebuilt macOS installers should be distributed
for their target architectures, not cross-built on Linux. If you still
have a standalone `nns-wg.sh` prototype running, stop it with that prototype's
`down` command before starting the integrated backend (to avoid duplicating
its VPN source address).

The following full-featured VPN chaining, server, gateway and namespace
sections document the **Linux implementation only**, unless explicitly noted.

## Capabilities

| Feature | Description |
| --- | --- |
| Application isolation | Separate network namespace, veth, resolver, routing policy, and kill switch for each app |
| VPN clients | OpenVPN 2.6+, WireGuard, and AmneziaWG; full- and split-tunnel IPv4 routes |
| Chaining | Route one VPN through another, or inherit a VPN connection without starting an inner tunnel |
| Private DNS | Honor validated WireGuard `DNS =` and safe `resolvectl` hook declarations within the namespace |
| Git integration | `git-via <app>` routes a repository's SSH transport through the selected app; `git-via -` resets it |
| VPN servers | Host-egress OpenVPN and AmneziaWG; OpenVPN gateways with an upstream VPN exit |
| Remote networking | SSH-managed remote exits, managed clients, `.nnslink` bundles, optional Cloak/stunnel transports |
| Operations | Inventory, status, external-IP/geolocation inspection, watchdogs, backups, and repair |

## Install and upgrade

The release archive contains modular `src/` files and a generated standalone
`install_linux`. Install from a **trusted local copy**:

```bash
sudo ./install_linux
nns-app --version
nns-app list
```

To update only the local machine without refreshing managed remote hosts:

```bash
sudo ./install_linux --local-only
```

Installer-managed packages include `iproute2`, `iptables`, Python 3, OpenSSL,
SSH, OpenVPN, WireGuard tools, and other runtime dependencies as appropriate.
The installer supports `apt` and `dnf`; it does not automatically add third-party
repositories or install a kernel module for AmneziaWG.
On Fedora, `iptables-nft` is used and firewalld integration manages the
`nns-app` zone and `nns-app-forward` policy.

**Optional AmneziaWG userspace tools (Ubuntu):**

```bash
sudo nns-app --install amnezia
```

This explicitly builds `awg`, `awg-quick`, and `amneziawg-go` from pinned
upstream AmneziaWG 3.1 tags. It needs Internet access and build tools. Other
Linux distributions need compatible tools installed separately; DKMS is not
required by the userspace implementation.

**Prerequisites:** systemd, Linux network namespaces, IPv4 forwarding, iptables,
root privileges for network administration, and appropriate SSH/sudo access for
remote management. For Cloak, install `ck-server`/`ck-client` separately.

## Quick start

Create an application environment, import a profile, and run a program through
that environment:

```bash
nns-app install work-vpn
nns-app add work-vpn ~/work.conf   # .conf: WireGuard or AmneziaWG; .ovpn: OpenVPN
nns-app start work-vpn
nns-app status work-vpn
nns-app run work-vpn curl -4 https://api.ipify.org
```

Run your normal program in place of `curl`. The command retains the configured
application user's privileges and file access; only its network context changes.
When the profile contains **only private IPv4 `AllowedIPs`**, a public IP probe
will not work by design. Use the private destination instead:

```bash
nns-app run work-vpn ip route get 10.77.0.53
nns-app run work-vpn getent ahostsv4 git.corp.example
```

Stop or remove the environment with `nns-app stop work-vpn` or
`sudo nns-app remove work-vpn`. An app marked *started* with split routes
ready is not necessarily able to reach its remote peer; check the handshake
and application service separately.

## Client workflows

### WireGuard and private DNS

Two safe ways to configure a WireGuard or AmneziaWG private DNS resolver are
supported. **Use one method per profile.** The addresses and names below are
illustrative only.

**Standard WireGuard DNS** sends all DNS queries to the VPN resolver and adds a
search suffix:

```ini
[Interface]
Address = 10.77.0.20/24
DNS = 10.77.0.53, corp.example
```

**Route-only DNS** sends only `corp.example` and its subdomains to the private
resolver; other queries use the application's configured fallback DNS servers,
subject to the kill switch:

```ini
[Interface]
PostUp = resolvectl dns %i 10.77.0.53
PostUp = resolvectl domain %i '~corp.example'
PostDown = resolvectl revert %i
```

`nns-app` **validates but does not execute** these precise hook forms. It
extracts the DNS policy and removes hooks before passing the profile to
`wg-quick`/`awg-quick`. Other shell hooks are rejected. The private DNS server
must be reachable via the profile's IPv4 `AllowedIPs`; private DNS queries are
never redirected outside the tunnel if that resolver is unreachable.

Namespace DNS uses a local resolver at `127.0.0.53` and a namespace-specific
`/etc/resolv.conf`. On systems with `nss-resolve`, a namespace-specific
`nsswitch.conf` selects `hosts: files dns` so Git/SSH/glibc resolution does not
accidentally use the host's `systemd-resolved` socket. Neither host file is
modified. For a private-only split tunnel, public DNS may intentionally be
unavailable unless the private server can answer those names.

### Git over a private VPN

In the Git repository that needs private SSH access:

```bash
nns-app start work-vpn
cd ~/src/project
git-via work-vpn
git pull
git fetch
git push
```

To switch namespace, run `git-via other-vpn`. To restore the previous
repository-local SSH setting (or remove the override if none existed):

```bash
git-via -
```

`git-via` only changes the current repository's `core.sshCommand`; it does
**not** alter global Git configuration or HTTPS remotes. Run it without
`sudo`. If needed, inspect the effective command with
`git config --show-origin --get core.sshCommand`. The selected NNS app must
be running when SSH connects. Environment-level Git/SSH overrides may still
take precedence.

For HTTPS remotes, run Git itself inside the namespace:

```bash
nns-app run work-vpn git -C ~/src/project pull
```

### VPN chaining and inherited networks

Use one VPN tunnel to carry another:

```bash
nns-app install upstream-vpn
nns-app add upstream-vpn ~/upstream.ovpn
nns-app start upstream-vpn

nns-app install downstream-vpn --via upstream-vpn
nns-app add downstream-vpn ~/downstream.ovpn
nns-app start downstream-vpn
```

Alternatively, use the upstream tunnel directly from a second namespace,
without running a second VPN client:

```bash
nns-app install dev-sandbox --backend inherit --via upstream-vpn
nns-app start dev-sandbox
nns-app run dev-sandbox curl -4 https://api.ipify.org
```

An inherited namespace requires an upstream NNS app (not `host`). Dependency
cycles are rejected and the kill switch prevents a fallback through the host
uplink. All app environments have separate names and lifecycles.

### Remote VPN exit

For a managed VPN exit on another Linux host:

```bash
nns-app install remote-work via --remote user@remote.example
nns-app add remote-work ~/provider.ovpn
nns-app run remote-work curl -4 https://api.ipify.org
```

The remote host receives a managed provider exit and private gateway; the
local client connects through a supervised SSH-forwarded OpenVPN control
channel. SSH access and appropriate non-interactive sudo permissions are
required. Remote upgrades reject downgrading a newer destination engine.

To select a publicly listed VPN Gate relay instead of supplying a profile:

```bash
nns-app add work-vpn any
nns-app add work-vpn any JP
```

Availability and trust of volunteer relays vary. In automatic-remote mode,
relay selection and probing occur on the remote host.

For explicitly registered remote gateway clients:

```bash
sudo nns-app remote add remote-one --ssh user@remote.example
sudo nns-app remote connect remote-one --client laptop --name remote-client
sudo nns-app remote sync remote-client
sudo nns-app remote rotate remote-client
nns-app remote status remote-one
```

Manual gateways support direct, stunnel and Cloak transport. Versioned
`.nnslink` bundles convey validated connection settings. Automatic remote
SSH forwarding is distinct from exported public OpenVPN profiles.

## VPN servers and gateways

### OpenVPN server

Create a server that routes clients through the host's Internet connection:

```bash
sudo nns-app install office-server --server \
  --listen udp:1194 --public vpn.example.net:1194 \
  --pool 10.253.50.0/24 --dns "1.1.1.1 9.9.9.9"

nns-app export ovpn office-server --client laptop \
  --fixed-ip --split-tunnel --output ~/laptop.ovpn
```

`--listen tcp:443` selects TCP. Without `--listen`, the application selects an
available UDP port. Supply `--public` if clients connect through DNS, NAT, or
a load balancer. Configure router/cloud ingress and forwarding separately.
Re-running `install <name> --server` preserves its CA and client identities;
re-export profiles when public endpoints or transports change.

### VPN-backed gateway

A managed OpenVPN gateway can route client traffic through another app's VPN:

```bash
sudo nns-app gateway create relay-gateway --via upstream-vpn
nns-app start relay-gateway
nns-app export ovpn relay-gateway --client phone --full-tunnel \
  --output ~/phone.ovpn
```

Change the existing gateway's exit without reissuing its client credentials:

```bash
sudo nns-app set-via relay-gateway other-vpn
nns-app status relay-gateway
```

Active clients briefly disconnect during upstream switching. The gateway
attempts to restore the previous configuration if the switch fails. `host`
selects direct host egress. AmneziaWG servers currently support host exit only.

The public listener remains on the host; the gateway's decrypted client
traffic uses its configured exit. Consequently, `nns-app run <gateway>
<command>` executes in the egress context, not the listener context.

### Cloak transport

Cloak can protect a TCP OpenVPN listener (requires separately provisioned
Cloak binaries):

```bash
sudo nns-app install protected-server --server \
  --transport cloak --listen tcp:443 \
  --public vpn.example.net:443 --server-name www.example.org

nns-app export ovpn protected-server --client laptop \
  --split-tunnel --output ~/protected-laptop.ovpn
```

Export produces both `.ovpn` and `.cloak.json` files. Start `ck-client`
locally with the exported transport configuration, and import the `.ovpn`
profile in a compatible OpenVPN client. The client OpenVPN connection uses
the local Cloak forward rather than the public listener directly.

### AmneziaWG server

```bash
sudo nns-app install awg-server --server --amnezia \
  --listen udp:51821 --public vpn.example.net:51821 \
  --client-to-client=on

nns-app export awg awg-server --client laptop \
  --split-tunnel --output ~/laptop-awg.conf
```

Each exported native AmneziaWG profile has its own keys and the appropriate
server obfuscation settings. Use an AmneziaWG-compatible client, not standard
WireGuard or an OpenVPN application. `--full-tunnel` uses `0.0.0.0/0`.
Reinstalling an existing server preserves peer keys and parameters; listener
and pool migrations are not currently performed in place.

### Client management

```bash
nns-app list clients
nns-app status laptop                  # when client name is unique
nns-app status office-server/laptop     # unambiguous
sudo nns-app client status office-server laptop
sudo nns-app fixed-ip office-server laptop on
sudo nns-app route-mode office-server laptop split
sudo nns-app client-to-client office-server on
sudo nns-app client export office-server laptop --full-tunnel \
  --output ~/laptop-full.ovpn
sudo nns-app client revoke office-server laptop
sudo nns-app client remove office-server laptop
```

Client listings show **IP** instead of **Created**. For connected OpenVPN
clients, IP is the current virtual address reported by OpenVPN; for connected
AmneziaWG peers, it is the peer's assigned address. Offline clients show
an assigned fixed IP if one exists, otherwise `-`. `status <client>` reports
connection state, current and fixed IPs separately, real/peer address, transfer
counters, timestamps, routing, and credential metadata without exposing keys.
If two gateways have a client with the same name, use `status <gateway>/<client>`
or `client status <gateway> <client>`. macOS VPN-server client management remains
unsupported.

Fixed IPs are assigned on the server, not embedded in exported OpenVPN
profiles. Split routes keep clients' default Internet paths; full routes push
the VPN's default IPv4 route and DNS. Client-to-client access is disabled by
default; enabling it may restart OpenVPN and disable DCO. Client removal
revokes credentials before deleting managed metadata. Exported files may
remain on client machines but revoked credentials cannot authenticate.

**Destructive action:** `nns-app remove <server>` permanently removes server
CA/private keys and managed client records. Back up before removing it.

## Operate and troubleshoot

Inspect and manage environments:

```bash
nns-app list
nns-app list namespaces
nns-app list gateways
nns-app list clients
nns-app list all
nns-app status work-vpn
nns-app myip work-vpn
nns-app myloc work-vpn
nns-app myloc --json
sudo nns-app repair
sudo nns-app repair --local-only
```

`myip` describes the namespace and route context. `myloc` queries the public
Internet exit using ip-api.com (unencrypted HTTP, non-commercial usage limit
of 45 requests/minute per exit). A private-only split tunnel may have no
public exit at all. An `active` tunnel service does not prove peer reachability.

Check DNS and WireGuard without changing host networking:

```bash
nns-app run work-vpn cat /etc/resolv.conf
nns-app run work-vpn getent ahostsv4 git.corp.example
nns-app run work-vpn dig @10.77.0.53 git.corp.example A
sudo ip netns exec nns-work-vpn wg show
systemctl status nns-dns@work-vpn.service --no-pager
sudo journalctl -u nns-openvpn@work-vpn.service -n 50 --no-pager
```

For OpenVPN, `nns-app status` reports readiness and recent connectivity
checks. Full-tunnel OpenVPN apps can automatically test and recover from a
verified TLS/HTTPS transfer stall by trying smaller TUN MTUs. Recovery is
bounded; failure restores the original MTU. Set `AUTO_MTU="off"` in
`/etc/nns-app/<app>/<app>.cfg` to disable it; clear `TUN_MTU` and restart
to return to profile defaults. The watchdog restarts failed backends with
cooldowns and avoids restarting children while their upstream is offline.

The app configuration also supports `KILLSWITCH`, `AUTOSTART`, `UPSTREAM_APP`,
`DNS_SERVERS`, `DISABLE_IPV6`, `WATCHDOG_MODE`, and related settings. Files are
root-owned and validated. Network and firewall resources are owned by nns-app;
cloud firewall policies or router port forwarding are **not** configured.

## Backup and restore

```bash
sudo nns-app backup --output /var/backups/nns-app.tar.gz
sudo ./install_linux restore /var/backups/nns-app.tar.gz
# Restore without starting saved services:
sudo ./install_linux restore /var/backups/nns-app.tar.gz --no-start
```

The backup contains managed configuration, keys, identities, and service
state. Treat it as highly sensitive: restrict file access and encrypt at rest
and in transit. Restore validates structure and hashes. Remote hosts require
their own backups. Changes in public IPs, firewall rules, and NAT after a
migration must be handled separately.

## Security and limitations

- **No arbitrary VPN script execution:** unsafe OpenVPN directives and
  WireGuard/AmneziaWG hooks are rejected. The narrowly accepted DNS hooks
  are parsed as data and never executed.
- **Per-namespace enforcement:** kill switches block non-VPN fallback.
  Disabling the kill switch changes this guarantee, particularly for split
  tunnels and DNS.
- **Credentials:** private material is root-owned, and managed SSH connections
  use pinned host keys. Never commit real VPN profiles or keys to the repo.
- **IPv4 focus:** IPv6-only profiles and IPv6 server forwarding are not
  supported; this is not a general site-to-site router.
- **Operational limits:** VPN Gate and obfuscation transports cannot guarantee
  availability or reachability through every network. Test your actual kernel,
  firewall and VPN backend before relying on the deployment.

## Build and contribute

```bash
./build.sh   # Linux -> install_linux; macOS -> install_macos with bundled binaries
make test    # Linux regression suite, or macOS static/mocked tests
```

Linux source is organized into ordered `src/[0-9][0-9]-*.sh` modules.
The Linux-built ZIP includes prebuilt `install_linux`; running the same
`build.sh` on macOS generates the self-contained `install_macos` (which is
not cross-compiled or included in this Linux-built archive). Both installers
are in the repository root beside `build.sh`. See
[CONTRIBUTING.md](CONTRIBUTING.md) for trust boundaries, lifecycle invariants,
resource ownership and test expectations.

License: GNU GPL v3.0 or later ([LICENSE](LICENSE)). Release-series highlights:
[CHANGELOG.md](CHANGELOG.md).
