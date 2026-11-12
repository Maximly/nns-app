# nns-app

`nns-app` isolates Linux application traffic in network namespaces and manages VPN
clients and servers from one CLI. It supports OpenVPN, WireGuard, AmneziaWG,
chained namespaces, SSH-managed remote exits, and host-based VPN servers.
The host's default route and DNS configuration remain independent of individual
application environments.

**Release:** 2.0.12  
**Supported platforms:** Ubuntu and Fedora with systemd (Debian-family package installation is also supported)  
**VPN backends:** OpenVPN 2.6+, WireGuard, AmneziaWG, and VPN-free inherited namespaces  
**License:** GPL-3.0-or-later

The distribution contains modular Bash source and a generated single-file installer,
`nns-app-install.sh`. Commands below assume that installer is available locally.

### Optional AmneziaWG 3.1 tooling (Ubuntu)

The application installer does **not** install AmneziaWG dependencies automatically.
To explicitly install the userspace tools on Ubuntu, run:

```bash
sudo nns-app --install amnezia
```

This installs Ubuntu build prerequisites and builds upstream `awg`, `awg-quick`,
and `amneziawg-go` from pinned AmneziaWG 3.1 tags into `/usr/local/bin`.
It uses the userspace backend, not DKMS or kernel modules, and does not alter
existing VPN app profiles. It needs Internet access to Ubuntu repositories,
GitHub, and potentially the official Go toolchain service.

Only after provisioning the tools, start the configured app:

```bash
nns-app start <app_name>
```

## Requirements

- Linux with systemd, network namespaces, IPv4 forwarding and iptables; root access to install and manage networking.
- OpenVPN 2.6+, `iproute2`, `iptables`, `wireguard-tools`, Python 3, OpenSSL, sudo and SSH tools. The installer installs mapped packages using `apt` or `dnf`.
- On Fedora, `iptables-nft` is used and firewalld integration manages the `nns-app` zone and `nns-app-forward` policy.
- For AmneziaWG, run `sudo nns-app --install amnezia` on Ubuntu to provision the userspace tools explicitly. Other distributions require compatible `awg`, `awg-quick`, and `amneziawg-go` installed separately. nns-app does not install DKMS or third-party package repositories.
- For Cloak, install `ck-server` on the server and `ck-client` on each client separately.
- IPv4 is the managed data plane; IPv6-only VPN profiles and IPv6 server forwarding are not supported.

## Route-only DNS in WireGuard profiles

WireGuard and AmneziaWG client profiles may use **only** the following
`wg-quick` hook forms in `[Interface]` (with literal IPv4 servers and
route-only DNS suffixes):

```ini
PostUp = resolvectl dns %i 192.168.83.10
PostUp = resolvectl domain %i '~promobit.loc'
PostDown = resolvectl revert %i
```

`nns-app` validates these declarations, **does not execute** them, and strips
them from the runtime config. Instead, its unprivileged namespace DNS proxy
forwards `promobit.loc` and subdomains to `192.168.83.10`; all other queries
use `DNS_SERVERS` and remain subject to the namespace kill switch. The private
DNS server must belong to the peer's IPv4 `AllowedIPs` routes. An inactive
private resolver never falls back to a public DNS server for matching domains.
After the tunnel becomes ready, `/etc/netns/nns-<app>/resolv.conf` points at the
namespace-local resolver on `127.0.0.53`. The host resolver is unchanged.

For a private-only split tunnel with `KILLSWITCH=on`, ordinary public DNS will
be unreachable unless the DNS server itself is accessible through the VPN;
this is intentional to prevent DNS leakage. Unsupported script hooks remain
rejected at import.

## Quick start

```bash
sudo bash nns-app-install.sh install
nns-app --version
nns-app list
```

`install` refreshes configured automatic-remote nodes as well as the local engine.
To upgrade only the current machine without contacting remote hosts:

```bash
sudo bash nns-app-install.sh install --local-only
```

Remote bootstrap checks destination versions and refuses to replace a newer
engine with an older one. Upgrade the initiating and destination hosts to the
same release before performing remote-management operations.

### Run a VPN locally

```bash
nns-app install my-private-app
nns-app add my-private-app ~/my-base-profile.ovpn
nns-app start my-private-app
nns-app run my-private-app ping -c 4 1.1.1.1
nns-app status my-private-app
```

Use a WireGuard `.conf` or AmneziaWG `.conf` instead of an `.ovpn` file to
select those backends. AmneziaWG parameters are validated and preserved.
WireGuard and AmneziaWG accept IPv4 split-tunnel `AllowedIPs` such as
`10.30.0.0/16`; a split-route configuration can be `READY` without confirming
reachability to an actual remote service. The kill switch blocks unmatched
traffic by default.

**Automatic OpenVPN MTU recovery:** On startup, a full-tunnel OpenVPN app
first checks IP reachability, then verifies completed HTTPS transfers using
Cloudflare's 32-KiB speed-test download and the ipify IPv4 endpoint. If both
succeed, the interface MTU is unchanged unless a previously saved value
needs reapplication. If a transfer stalls *after* TLS
ClientHello, nns-app temporarily tests smaller TUN MTUs (1400, 1360, 1320,
1280, 1200). It saves the first setting at which every previously failing
transfer recovers twice and every initially healthy probe remains working;
otherwise it restores the original MTU. Unavailable targets do not prevent
recovery of an independently confirmed TLS stall. DNS failures, TCP connection
failures, certificate errors, and split-tunnel apps cannot by themselves
trigger tuning. Probes are budget-limited, and the
last result is displayed in `nns-app status`. Set `AUTO_MTU="off"` in the
app configuration to disable checks; `TUN_MTU` holds the last measured value
and is reapplied at TUN creation/reconnect by OpenVPN's `--up` callback.
An independent, network-free 10-second timer reconciles later MTU drift;
its check is not delayed by the connectivity watchdog. Clearing `TUN_MTU`
returns to the profile's MTU on the next restart. External probe hosts are not guaranteed to
be available on every network.

For free VPN Gate OpenVPN relay selection:

```bash
nns-app add my-private-app any
nns-app add my-private-app any JP
```

The VPN Gate relay list is downloaded and candidates are probed before a
profile is installed. Public relays may use documented public OpenVPN
credentials (`vpn` / `vpn`); availability and trust vary by provider.

### Run a VPN on a remote Linux host

```bash
nns-app install my-private-app via --remote user@remote-host
nns-app add my-private-app ~/my-remote-profile.ovpn
nns-app run my-private-app ping -c 4 1.1.1.1
```

In automatic-remote mode, nns-app installs a managed remote exit environment,
creates a private gateway and forwards its OpenVPN control connection over a
supervised SSH tunnel. The local client does not need access to VPN Gate when
using `nns-app add my-private-app any`; selection and probing take place on
the remote host. Remote bootstrap requires SSH access and suitable remote sudo
permissions, and protects newer destination engines from downgrade.

A public OpenVPN profile can also be exported from a managed automatic-remote
app; `--embedded` is optional even on the first export:

```bash
nns-app export ovpn my-private-app --client my-laptop \
    --output ~/my-laptop.ovpn
nns-app export ovpn my-private-app --client my-phone \
    --embedded --output ~/my-phone.ovpn
nns-app revoke my-private-app my-phone
```

The remote SSH transport is part of the local app's managed runtime; exported
public OpenVPN profiles are a separate access method and require a reachable
public gateway endpoint.

## Application environments

### Unified app lifecycle

Every name shown by `nns-app list` is a managed app. The same `start`, `stop`,
`status`, `remove` and `run` commands accept VPN clients, OpenVPN servers,
AmneziaWG servers and upstream-backed gateways. The `gateway` subcommands
remain available for managing gateway-specific settings and client identities.

For gateway apps, `run` executes through the gateway's configured **exit**, not
inside its OpenVPN listener: a `via host` server uses the host network and a
`via <vpn-app>` gateway runs in the upstream VPN namespace. Commands run with
non-root user privileges; gateways must be started before `run`.

```bash
nns-app start office-vpn
nns-app status office-vpn
nns-app run office-vpn ping -c 4 ya.ru   # host-exit server: host network
nns-app stop office-vpn

nns-app start relay-gateway
nns-app run relay-gateway curl -4 https://api.ipify.org  # via upstream-vpn
```

### Change a gateway's upstream

```bash
sudo nns-app set-via relay-gateway secondary-vpn
nns-app status relay-gateway
nns-app run relay-gateway curl -4 https://api.ipify.org
```

`set-via <gateway-app> <upstream-app|host>` changes the egress of an existing
OpenVPN server/gateway without reissuing client certificates or modifying its
public endpoint, port, subnet or client routing policy. An active gateway
checks the new upstream's readiness, disconnects existing clients briefly,
then restarts on the new exit. If startup fails, nns-app attempts to restore
the previous configuration and running service. A stopped gateway remains
stopped; it may be assigned an offline upstream for later use. `host` selects
the host's uplink. AmneziaWG servers currently support host exit only.

### Namespace lifecycle

```bash
nns-app install my-upstream-vpn
nns-app add my-upstream-vpn ~/upstream.ovpn
nns-app start my-upstream-vpn
nns-app run my-upstream-vpn curl -4 https://api.ipify.org
nns-app stop my-upstream-vpn
nns-app remove my-upstream-vpn
```

Each app gets its own network namespace, veth pair, resolver, routing policy and
kill switch. `nns-app run` enters the namespace and then drops privileges to the
configured application user. Desktop sessions, Electron applications and Snap
launches receive the required restricted session and mount integration.

### Chained namespaces and shared VPN connections

```bash
nns-app install my-private-app --via my-upstream-vpn
nns-app add my-private-app ~/another-vpn.ovpn
nns-app start my-private-app

nns-app install my-linux-client --backend inherit --via my-upstream-vpn
nns-app start my-linux-client
nns-app run my-linux-client curl -4 https://api.ipify.org
```

A chained VPN app sends its encrypted tunnel through an upstream app's VPN.
An `inherit` child has no inner VPN client and shares the upstream VPN through
an isolated namespace. Upstream dependency cycles are rejected. Child data
paths have no fallback to the ordinary host uplink.

### Application configuration and monitoring

App configuration lives under `/etc/nns-app/<app>/<app>.cfg`. Relevant fields
include `KILLSWITCH`, `AUTOSTART`, `UPSTREAM_APP`, `DNS_SERVERS`,
`DISABLE_IPV6`, `DISABLE_DCO`, `WATCHDOG_MODE`, `WATCHDOG_FAILURES` and
`WATCHDOG_COOLDOWN`. Configuration files are root-owned and validated before
being loaded.

The watchdog monitors established OpenVPN/WireGuard namespace connectivity,
waits for consecutive failures and restarts only the VPN backend. It avoids
restarting a child while its upstream is offline and applies a cooldown.
Use `nns-app status <app>` to inspect readiness, routes, DNS and recovery state.

## VPN servers

### OpenVPN gateway with a VPN upstream

```bash
sudo nns-app gateway create relay-gateway --via upstream-vpn
nns-app start relay-gateway
nns-app status relay-gateway
nns-app run relay-gateway curl -4 https://api.ipify.org
nns-app export ovpn relay-gateway --client phone --full-tunnel \
    --output ~/relay-phone.ovpn
```

The gateway accepts incoming OpenVPN connections on the host, while client
Internet traffic exits through the `upstream-vpn` VPN namespace. `--listen` and
`--public` override automatically discovered listener and public endpoint.

### OpenVPN server — direct UDP or TCP

Create a host-egress OpenVPN server without a separate upstream VPN app:

```bash
sudo nns-app install office-vpn --server \
    --listen udp:1194 --public vpn.example.net:1194 \
    --pool 10.253.50.0/24 --dns "1.1.1.1 9.9.9.9"

nns-app export ovpn office-vpn --client laptop \
    --fixed-ip --split-tunnel --output ~/laptop.ovpn
nns-app status office-vpn
```

`--listen tcp:443` creates a TCP OpenVPN server. If no explicit listener is
specified, a free UDP listener is selected. `--public` identifies the address
clients use, including installations behind NAT; router port forwarding and
cloud ingress policy must be configured outside nns-app.

Re-running `install <name> --server` reconciles an existing server while
preserving its CA, certificates and client identities. Re-export client
profiles after changing their public endpoint or transport.

The server forwards IPv4 client traffic through the Linux host's normal uplink.
Per-server firewall/NAT rules are owned by nns-app; starting a host VPN server
enables runtime IPv4 forwarding. It does not provision external NAT rules.

### Cloak-protected OpenVPN server

```bash
sudo nns-app install private-vpn --server \
    --transport cloak --listen tcp:443 \
    --public vpn.example.net:443 \
    --server-name www.example.org

nns-app export ovpn private-vpn --client mac \
    --split-tunnel --output ~/private-vpn-mac.ovpn
```

Cloak exposes a public TCP listener and forwards to an OpenVPN TCP listener
bound to loopback. Export creates both `private-vpn-mac.ovpn` and
`private-vpn-mac.cloak.json`. Copy both files to the client. On macOS, run:

```bash
ck-client -c ./private-vpn-mac.cloak.json \
    -s vpn.example.net -p 443 -l 11940
```

Then import the `.ovpn` profile into Tunnelblick. It connects to
`127.0.0.1:11940`, not directly to the public Cloak endpoint. Cloak binaries
must be supplied independently. Existing server certificates survive a
transport change, but exported client transport settings must be refreshed.

### AmneziaWG server

```bash
sudo nns-app install my-awg --server --amnezia \
    --listen udp:51821 --public vpn.example.net:51821 \
    --client-to-client=on

nns-app export awg my-awg --client mac \
    --split-tunnel --output ~/mac-awg.conf
nns-app status my-awg
```

The AmneziaWG server creates its key material, header-protection key,
obfuscation parameters, a managed UDP interface and client peer allocations.
Each exported native `.conf` contains its own private key and the matching
server parameters. In split mode the exported `AllowedIPs` contains the VPN
client pool; `--full-tunnel` selects `0.0.0.0/0`. Import it into an
AmneziaWG-compatible client, **not** Tunnelblick or standard WireGuard.

Reinstalling an existing AmneziaWG server preserves peer keys and obfuscation
settings. Changing its listener or address pool is not supported as an
in-place migration. `awg`, `awg-quick`, and the userspace backend `amneziawg-go` are required for runtime.
On Ubuntu, provision them explicitly using `nns-app --install amnezia`.

### OpenVPN clients: fixed IPs, routing and isolation

```bash
sudo nns-app fixed-ip office-vpn laptop on
nns-app fixed-ip office-vpn laptop
sudo nns-app route-mode office-vpn laptop split
sudo nns-app route-mode office-vpn laptop full
sudo nns-app client-to-client office-vpn on
sudo nns-app client-to-client office-vpn off
```

`--fixed-ip` and `fixed-ip` assign stable addresses on the server through
OpenVPN client-specific configuration; no static address is embedded in the
exported `.ovpn`. Dynamic clients occupy the lower portion of the client pool
when fixed addresses are enabled. `route-mode split` retains the client's
normal Internet default route and DNS; `full` pushes the server's default
Internet route and DNS. Route changes reconnect active OpenVPN clients.

Client-to-client connectivity is disabled by default. Enabling it restarts an
active server and disables OpenVPN DCO so OpenVPN can forward between clients.

### Client lifecycle and server management

```bash
nns-app list clients
nns-app list gateways
nns-app gateway client list office-vpn
# Export creates missing client identities; repeat export reuses existing keys.
sudo nns-app client export office-vpn laptop --full-tunnel --output ~/laptop.ovpn
sudo nns-app client export my-awg mac --full-tunnel --output ~/mac.conf

# Revoke without deleting the record, or revoke and completely remove it.
sudo nns-app client revoke office-vpn laptop
sudo nns-app client remove office-vpn laptop
sudo nns-app client remove my-awg mac
sudo nns-app stop office-vpn
sudo nns-app start office-vpn
sudo nns-app remove office-vpn
```

Removing a server permanently deletes its CA, private keys and managed client
records. Back up first. Client removal first revokes access, then deletes that client's credentials,
keys and metadata from the server. For OpenVPN, the CA database and CRL keep
the revoked certificate serial so deleted clients cannot reconnect. For
AmneziaWG, the peer is removed from the running server and its keys are deleted.
Previously exported profiles remain on client devices but cannot authenticate.
Re-exporting an existing active client preserves its credentials. Output files
are never overwritten; choose a new path to export again.

## Managed remote gateways

For advanced setups, a gateway can send clients through a separately managed
upstream namespace rather than through the server host's default uplink:

```bash
nns-app install my-remote-exit
nns-app add my-remote-exit ~/my-remote-profile.ovpn
nns-app start my-remote-exit

sudo nns-app gateway create my-relay --via my-remote-exit

sudo nns-app gateway client add my-relay my-linux-client
sudo nns-app gateway client export my-relay my-linux-client \
    --output ~/my-linux-client.ovpn
```

The gateway automatically selects an unused host UDP listener (starting at
1194), discovers the host's public IPv4 address, and advertises that port in
client profiles. Supply `--listen udp:<port>` and `--public <host>:<port>`
when a specific port, DNS hostname, external NAT mapping, or load balancer
is required. nns-app manages the local firewall, not the cloud provider's
security group or an upstream router's port forwarding. Use `--transport cloak`
or `--transport stunnel` for a TCP gateway; those default to the first
available host TCP port starting at 443.

Manual remote registration, connection and credential updates use these commands:

```bash
sudo nns-app remote add remote-one --ssh user@remote-host
sudo nns-app remote connect remote-one --client laptop --name client-vpn
sudo nns-app remote sync client-vpn
sudo nns-app remote rotate client-vpn
nns-app remote status remote-one
```

Manual gateways support `direct`, `stunnel` and `cloak` transport types.
Versioned `.nnslink` bundles carry transport settings for managed client
imports; untrusted bundles are validated before extraction. Automatic-remote
apps use a supervised SSH-forward transport instead of exposing a new public
listener. Different remote apps can reuse a shared pool of remote provider
exit resources when their configuration permits it.

## Inventory and diagnosis

```bash
nns-app list             # all managed local instance types
nns-app list namespaces  # namespace applications only
nns-app list gateway     # managed gateways and servers
nns-app list clients     # exported client identities
nns-app list all         # local and remote apps + exported clients
nns-app status office-vpn
nns-app myip my-private-app
nns-app myip office-vpn
nns-app myloc my-private-app   # geolocation of its Internet exit
nns-app myloc office-vpn     # geolocation of the gateway upstream exit
nns-app myloc --json         # machine-readable JSON for the current context
sudo nns-app repair
sudo nns-app repair --local-only
```

`myloc` queries the public exit through the selected app namespace or gateway
upstream. Its free ip-api.com endpoint uses unencrypted HTTP, is limited to
45 requests/minute per exit address and permits non-commercial use only.
Geolocation is approximate; a query failure never falls back to the host network.

`status` reports runtime readiness; a locally healthy listener does not
establish public reachability. Check host/firewall rules, router forwarding,
provider ingress policy and client logs when a remote connection fails.

A managed public server opens a tagged iptables INPUT rule for its listener;
UFW and firewalld integration is handled where available. Pre-existing
administrator firewall rules are not removed or globally flushed.
For Fedora, inspect the `nns-app-forward` firewalld forwarding policy.

Typical diagnostics:

```bash
sudo systemctl status 'nns-gateway@office-vpn.service'
sudo journalctl -u 'nns-gateway@office-vpn.service' -n 100 --no-pager
sudo systemctl status 'nns-openvpn@my-private-app.service'
sudo iptables-save | grep -i nns
```

## Backup and restore

Create an archive of managed configurations, keys, client identities and
service state:

```bash
sudo nns-app backup --output /var/backups/nns-app.tar.gz
```

Restore using a trusted installer on a compatible host:

```bash
sudo bash nns-app-install.sh restore /var/backups/nns-app.tar.gz
# Restore without starting saved services:
sudo bash nns-app-install.sh restore /var/backups/nns-app.tar.gz --no-start
```

A backup embeds the installed engine for emergency recovery, but running the
current trusted installer is preferred. Restore checks archive structure and
hashes before applying data. Backup archives contain VPN private keys and
potentially SSH identities: restrict their access and encrypt them at rest and
in transit. Remote hosts must be backed up independently. Moving to another
host may require updated public endpoints, forwarding or cloud firewall rules.

## Security and limitations

- Profile imports reject dangerous OpenVPN directives and WireGuard hooks.
- Root-owned state, dedicated per-instance firewall rules and verified SSH host keys protect managed connections.
- Kill switches are applied per namespace; a disabled kill switch can allow traffic outside a split-tunnel route.
- Full-tunnel gateway operation covers IPv4 only. It does not provide IPv6 leak protection outside the managed namespace or a complete site-to-site router.
- Cloak and AmneziaWG provide different traffic signatures, but no transport guarantees operation through all filtering networks.
- VPN Gate is a public volunteer service. Public credentials and transport availability can change independently of nns-app.
- Live cross-platform deployment and connectivity must be verified on the intended kernel, VPN runtime and firewall configuration.

## Build and contribute

```bash
make build       # regenerate nns-app-install.sh from src/
make test        # static and source-level regression tests
```

The generated installer concatenates ordered `src/[0-9][0-9]-*.sh` modules.
Release archives include the source, prebuilt installer and tests.
See [CONTRIBUTING.md](CONTRIBUTING.md) for source layout, trust boundaries,
network-resource ownership and testing requirements.

## License

GNU General Public License v3.0 or later; see [LICENSE](LICENSE).
