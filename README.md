# nns-app

`nns-app` runs selected Linux applications inside dedicated network namespaces and connects each namespace through an isolated network transport.

A browser, messenger, crawler, build tool, or another process can use its own VPN without replacing the host's default route or DNS configuration. Each named environment has separate routes, DNS, firewall state, tunnel state, and a kill switch.

> **Release:** 1.0.21  
> **Status:** experimental  
> **Current backends:** OpenVPN and WireGuard  
> **Planned backends:** AmneziaWG and provider-specific transports

## Main features

- One Linux network namespace per named application environment.
- Optional namespace chaining with `--via <upstream-app>`.
- Host networking and host DNS remain unchanged.
- Namespace-only resolver configuration under `/etc/netns/`.
- Kill switch blocks direct fallback to the host uplink.
- Applications run as the configured desktop user, not as root.
- systemd manages namespace and VPN-backend lifecycles.
- Self-contained OpenVPN and WireGuard profiles can be imported.
- A public OpenVPN relay can be selected automatically with `add ... any`.
- VPN Gate metadata is cached for two days with stale-cache fallback.
- Namespace and OpenVPN service startup failures print their own recent logs.
- Two-letter VPN Gate country filters now match country codes exactly.
- Restarting after an incomplete namespace setup safely rebuilds endpoint runtime files.
- `./nns-app.sh install` now installs or refreshes the engine without creating an app.
- Repeated `add <name> any` calls rotate through the top 20 matching VPN Gate relays.
- VPN Gate candidates must complete a short OpenVPN handshake before import.
- `nns-app run` prepares cgroup2 and securityfs inside its private mount namespace so Snap GUI applications can start.
- Runtime `--via` creates a real veth/NAT chain through another active NNS VPN.
- WireGuard supports full-tunnel IPv4 provider profiles, endpoint pinning, kill-switch rules, status reporting, and chained upstream/downstream operation.
- Strict five-second startup failure handling.
- Optional `-i` asynchronous start mode leaves a slow connection running.

## Architecture

Direct mode:

```text
application -> nns-browser -> browser VPN -> host NAT -> host uplink
```

Chained mode:

```text
application
    -> nns-browser
    -> inner VPN
    -> veth into nns-hidemy
    -> HideMy tunnel
    -> Internet
```

In chained mode the downstream veth is placed directly inside the upstream
namespace. Forwarding and NAT are installed only from that veth to the
upstream tunnel interface. If the upstream tunnel disappears, the rule no
longer matches another interface and the upstream namespace's default-drop
FORWARD policy prevents fallback to its physical veth.

Before the inner tunnel is online, the downstream namespace may contact only
the configured inner VPN endpoint and its namespace DNS servers. Protected
application traffic is accepted only through the inner tunnel interface.

## Requirements

The current release targets Ubuntu with systemd and requires:

- Bash
- OpenVPN
- wireguard-tools (`wg` and `wg-quick`)
- iproute2 network namespaces
- iptables
- systemd
- sudo
- curl
- ping
- OpenSSL
- Python 3 for public-relay profile selection
- util-linux (`setpriv`)

Missing dependencies are installed automatically by `nns-app install` on supported Ubuntu systems.

## Installation

Install or refresh the engine itself:

```bash
chmod +x nns-app.sh
sudo ./nns-app.sh install
```

This installs:

```text
/usr/local/sbin/nns_app.sh
/usr/local/bin/nns-app
```

Create a direct application environment:

```bash
sudo nns-app install browser
```

Persistently route it through an already installed upstream app:

```bash
sudo nns-app install browser --via hidemy
```

This writes `UPSTREAM_APP="hidemy"` to the app configuration. Use
`--via host` to restore direct-host mode.

The installer creates or refreshes:

```text
/usr/local/bin/nns-app
/usr/local/sbin/nns_app.sh
/etc/nns-app/<name>/
/etc/systemd/system/nns-netns@.service
/etc/systemd/system/nns-openvpn@.service  # legacy filename; manages either backend
/etc/sudoers.d/nns-app-<name>
```

Verify the installed version:

```bash
nns-app --version
```

Expected:

```text
nns-app 1.0.21
Author:  Maxim Lyadvinsky
License: GPL-3.0-or-later
```

Running `install` again refreshes the engine, systemd units, and sudoers rules while preserving existing app configuration and imported profiles:

```bash
sudo ./nns-app.sh install browser
```

## Quick start with an existing profile

OpenVPN:

```bash
sudo nns-app add browser ~/Downloads/location.ovpn
nns-app start browser
nns-app run browser curl -4 https://api.ipify.org
nns-app run browser firefox --no-remote
```

WireGuard:

```bash
sudo nns-app add browser ~/Downloads/provider-wireguard.conf
nns-app start browser
nns-app run browser curl -4 https://api.ipify.org
```

The backend is detected from profile content and stored as `VPN_TYPE`. Re-adding a profile can switch an existing app between OpenVPN and WireGuard.

Inspect state:

```bash
nns-app list
```

Stop and remove the runtime namespace:

```bash
nns-app stop browser
```

## Find and add a public VPN profile

Use `any` to download the current VPN Gate relay list, select a supported OpenVPN profile, validate it, and add it as the active profile:

```bash
sudo nns-app add browser any
```

Optionally filter by a two-letter country code or a country-name fragment:

```bash
sudo nns-app add browser any JP
sudo nns-app add browser any Germany
```

Two-letter values are matched only against VPN Gate's `CountryShort` field.
For example, `US` cannot match `Russian Federation`. Longer values such as
`Germany` continue to use case-insensitive country-name matching.

The VPN Gate CSV list is cached in:

```text
/var/cache/nns-app/vpngate.csv
```

The cache is reused for two days. A failed refresh falls back to the last
cached list even when it is older. Live OpenVPN probing protects selection
from obviously dead entries in an older list. Force a fresh download with:

```bash
sudo nns-app add browser any DE --refresh
```

The profile itself is copied into the named app environment, so removing or
refreshing the server-list cache does not remove previously imported profiles.

Selection uses persistent round-robin state. For each application and country
filter, nns-app rotates through the 20 highest-ranked matching relays instead of
selecting the same top-scoring server repeatedly. State files are stored under:

```text
/var/lib/nns-app/vpngate-<app>-<filter>.last
```

Delete the corresponding state file to restart rotation from the strongest
candidate.

Before importing a relay, nns-app quick-checks up to ten round-robin
candidates. Each candidate receives a six-second OpenVPN control-channel probe.
A successful TCP socket alone is insufficient; the candidate must reach
`Peer Connection Initiated` (or full initialization). This avoids rejecting a
valid server merely because pushed routes and DNS take several more seconds.
The selector prints the actual candidate-pool size.

When an entire probe batch fails, the round-robin marker advances to the last
tested relay. A subsequent `add any` call therefore continues with the next
untested candidates when the pool contains more entries.

Select and probe a public profile through the intended upstream path:

```bash
sudo nns-app add test any US --via hidemy
```

Both a required cache refresh and candidate probes use `nns-hidemy`. When the
command itself is launched through `nns-app run hidemy`, the selector also
detects that current namespace unless an explicit `--via` overrides it.
Temporary probe interfaces do not install routes or configure addresses.

The quick check confirms that the relay currently completes OpenVPN negotiation.
It does not establish that the volunteer relay is trustworthy or that every
destination will be reachable through it.

The current implementation uses the VPN Gate public relay list. Relays are operated by volunteers and may be slow, unavailable, logged, filtered, or untrusted. This feature is suitable for testing and low-risk HTTPS traffic; it should not be treated as trusted privacy infrastructure.

Profiles downloaded through `any` pass the same validation and managed-copy processing as locally imported profiles.

## Chained startup with `--via`

The persistent upstream from `UPSTREAM_APP` is used by default:

```bash
nns-app start -i test
```

Override it for one start without editing configuration:

```bash
nns-app start -i test --via hidemy
nns-app start test --via host
```

The upstream app must already be started, have an active OpenVPN or WireGuard tunnel, and pass its own online check. Multiple downstream apps
may share one upstream. Stopping an upstream with `nns-app stop` first stops
its currently attached downstream apps. An unexpected upstream failure cannot
leak downstream traffic because forwarding is accepted only toward the
recorded upstream tunnel interface.

`--via` on `add any` controls download/probe routing. `--via` on `start`
controls the actual runtime topology; using only the former does not chain the
application namespace.

## Startup modes

### Strict start

```bash
nns-app start browser
```

Strict start waits up to `READY_TIMEOUT`, which defaults to five seconds. A tunnel interface alone is not considered success: `nns-app` also checks that the namespace can pass traffic.

When the data path is still offline after the deadline, `nns-app`:

1. prints recent VPN-backend log lines;
2. stops the VPN service;
3. removes the runtime namespace;
4. returns a nonzero exit status.

This prevents a failed connection from retrying indefinitely in the background.

### Ignore/asynchronous start

```bash
nns-app start -i browser
```

The long form is also accepted:

```bash
nns-app start --ignore-start-error browser
```

For compatibility, the option may also follow the app name:

```bash
nns-app start browser -i
```

With `-i`, `nns-app` uses a short readiness probe and normally returns in about one to two seconds. When the VPN is not online yet, it:

- prints a warning;
- returns success;
- leaves the namespace and VPN service running;
- does not stop the failed or slow connection.

Check progress later:

```bash
nns-app list
sudo journalctl -fu nns-openvpn@browser.service
```

`-i` ignores only the readiness failure. Invalid configuration, a missing profile, failure to create the namespace, or failure to start systemd services remains an actual error.

A namespace creation error occurs before OpenVPN is launched. Version 1.0.14
prints the recent `nns-netns@<name>.service` log automatically in this case;
`-i` cannot and should not hide this structural failure.

Version 1.0.14 also fixes restart cleanup ordering. A stale namespace is removed
before `/run/nns-app/<name>.endpoints` is generated, preventing cleanup from
deleting the newly generated endpoint list during the same start operation.

Applications are still protected: with the kill switch enabled, `nns-app run` refuses to launch a command until the tunnel route and data path are usable.

## Commands

| Command | Description |
|---|---|
| `nns-app install <name>` | Install or refresh the engine and create a named environment |
| `nns-app add <name> <profile.ovpn|wireguard.conf>` | Validate and import an OpenVPN or WireGuard profile |
| `nns-app add <name> any [country] [--refresh] [--via <app>|host]` | Select and probe a VPN Gate profile through the chosen path |
| `nns-app start <name>` | Start and require a usable data path within the configured timeout |
| `nns-app start -i <name>` | Start asynchronously; leave a slow/offline service running |
| `nns-app stop <name>` | Stop the transport and remove the runtime namespace |
| `nns-app run <name> <command> [args...]` | Run a command in the namespace as the configured user |
| `nns-app list` | Show state, active profile, tunnel address, and external address |
| `nns-app remove <name>` | Remove one app environment and its profiles |
| `nns-app purge` | Remove the engine and all `nns-app` environments |
| `nns-app --version` | Show version, author, and license |

App names may contain letters, digits, `.`, `_`, and `-`, with a maximum length of 32 characters.

## Per-app configuration

Each environment has a root-owned configuration file:

```text
/etc/nns-app/<name>/<name>.cfg
```

Edit it with:

```bash
sudoedit /etc/nns-app/browser/browser.cfg
```

Important settings:

| Setting | Default | Purpose |
|---|---:|---|
| `APP_USER` | installing user | User identity used for launched applications |
| `DEFAULT_PROFILE` | empty | Active managed VPN profile |
| `VPN_TYPE` | empty | Set automatically to `openvpn` or `wireguard` |
| `KILLSWITCH` | `on` | Block direct traffic outside the tunnel |
| `AUTOSTART` | `off` | Enable the environment at boot |
| `WAN_IFACE` | `auto` | Host uplink or explicitly selected interface |
| `DNS_SERVERS` | `1.1.1.1 9.9.9.9` | Namespace-only DNS resolvers |
| `DISABLE_IPV6` | `on` | Disable IPv6 inside the namespace |
| `PROFILE_FIXUPS` | `on` | Normalize the managed copy for compatibility |
| `DISABLE_DCO` | `off` | Explicit OpenVPN DCO policy; ignored for WireGuard |
| `READY_TIMEOUT` | `5` | Strict-start readiness deadline in seconds |
| `EXTERNAL_IP_URL` | `https://api.ipify.org` | External-address status endpoint |

The `-i` startup mode intentionally uses its own short probe instead of `READY_TIMEOUT`.

## OpenVPN profile policy

Imported profiles are treated as untrusted input. The current backend accepts a restricted profile subset:

- TUN profiles only; TAP is rejected.
- Certificates and keys must be embedded in the profile.
- Interactive password prompts are unsupported.
- External credential/key paths are rejected.
- Scripts, plugins, management directives, and other root-executed hooks are rejected.
- The source profile is never modified.
- The managed copy is normalized from CRLF/CR to Unix LF line endings before parsing.
- Parsed VPN endpoint ports and protocols are validated before any iptables rule is created.
- A root-owned managed copy is stored under `/etc/nns-app/<name>/profiles/`.
- Vendor-specific directives requiring a patched OpenVPN binary are unsupported by stock Ubuntu OpenVPN.

With `PROFILE_FIXUPS="on"`, managed-copy compatibility processing may:

- add `disable-dco`;
- permit a detected legacy SHA-1/MD5 certificate chain;
- add a CBC cipher fallback for a legacy profile.

Disable automatic changes with:

```bash
PROFILE_FIXUPS="off"
```

Then re-add the original profile.

## WireGuard profile policy

Import a provider WireGuard profile with:

```bash
sudo nns-app add browser ~/Downloads/provider.conf
```

The current WireGuard backend intentionally supports a restricted client
profile subset:

- exactly one `[Interface]` followed by one or more `[Peer]` sections;
- an inline 32-byte base64 `PrivateKey`;
- at least one IPv4 interface `Address`;
- IPv4 or hostname `Endpoint` values with UDP ports;
- full-tunnel IPv4 `AllowedIPs` (`0.0.0.0/0`, or both `/1` halves);
- `Table = auto` or no `Table` setting;
- optional `MTU`, `ListenPort`, `FwMark`, `PresharedKey`, and `PersistentKeepalive`.

For safety, `PreUp`, `PostUp`, `PreDown`, `PostDown`, `SaveConfig`, unknown
sections, and unknown options are rejected. IPv6-only endpoints and split-tunnel
profiles are not supported in this release.

The managed source copy remains under `/etc/nns-app/<name>/profiles/` with mode
`0600`. At startup, nns-app creates a temporary root-only runtime configuration:

- profile `DNS` is omitted because namespace DNS is controlled by `DNS_SERVERS`;
- IPv6 addresses and allowed ranges are omitted when `DISABLE_IPV6="on"`;
- `wg-quick` creates the interface and routes only inside the app namespace;
- the endpoint is pinned to the namespace veth and allowed by the kill switch;
- shutdown runs `wg-quick down` and removes the temporary configuration.

The existing systemd template keeps its historical filename
`nns-openvpn@.service` for upgrade compatibility, but its description and
entry point are backend-neutral and it manages either OpenVPN or WireGuard.

WireGuard does not have a persistent userspace tunnel daemon. nns-app keeps a
small supervised lifecycle process alive after `wg-quick up` so systemd can
stop the interface deterministically with the same app commands used for
OpenVPN.

## Isolation and security

Every environment receives its own:

- network namespace;
- loopback interface;
- veth pair and allocated `/30` network;
- route table;
- resolver file;
- namespace-local firewall;
- backend-specific OpenVPN process or WireGuard interface lifecycle managed by systemd.

OpenVPN DNS helper integration is disabled, and WireGuard `DNS` entries are omitted from the runtime copy, so imported profiles cannot replace host DNS.

Namespace and tunnel setup require root. `nns-app run` enters the namespace as root and then permanently drops to `APP_USER` with `setpriv` before executing the requested program. Commands are executed directly without `eval` or shell re-parsing.

The installer creates restricted sudoers commands for routine operations. Re-run `install` after upgrading so new command forms such as `start -i` are added to the sudoers rule.

## Troubleshooting

Show all environments:

```bash
nns-app list
```

Follow VPN-backend logs (the unit keeps its legacy name):

```bash
sudo journalctl -fu nns-openvpn@browser.service
```

Inspect namespace setup:

```bash
sudo journalctl -u nns-netns@browser.service -n 100 --no-pager
```

Version 1.0.12 normalizes Windows-style CRLF profiles automatically. On an
older installation, `proto tcp^M` or `remote ... 443^M` in `cat -v` output can
make iptables reject the endpoint rule. Re-add the profile after upgrading, or
temporarily normalize the managed copy with:

```bash
sudo sed -i 's/\r$//' /etc/nns-app/<name>/profiles/<profile>.ovpn
```

Inspect interfaces and routes:

```bash
sudo ip -n nns-browser address
sudo ip -n nns-browser route
```

Inspect firewall counters:

```bash
sudo ip netns exec nns-browser iptables -nvL --line-numbers
```

Test the data path:

```bash
nns-app run browser ping -c 3 1.1.1.1
nns-app run browser curl -4 https://api.ipify.org
```

A log message such as `Initialization Sequence Completed` proves that OpenVPN initialized its control/data-channel state; it does not by itself prove that the provider is forwarding application traffic. `nns-app` therefore performs a separate namespace data-path probe.

## Known limitations

- Linux and systemd only.
- Ubuntu is the primary tested platform.
- IPv4 is the primary supported path; IPv6 is disabled by default.
- OpenVPN and full-tunnel IPv4 WireGuard profiles are implemented.
- Runtime namespaces are removed on normal stop.
- The most recently added profile becomes active.
- Firewall management currently uses iptables.
- Public relays may disappear or change without notice.
- Provider-side session limits, stale mappings, custom clients, and custom protocol extensions are outside the generic backends' control.
- GUI applications with single-instance or sandbox policies may need application-specific launch options.

## Roadmap

- Further backend abstraction shared by OpenVPN, WireGuard, and future transports.
- Direct `wg` configuration as an alternative to the current namespace-local `wg-quick` lifecycle.
- AmneziaWG support.
- Provider-specific configuration/control-plane helpers.
- Fast profile switching without destroying the namespace.
- Explicit profile listing and selection commands.
- nftables backend with transactional updates.
- IPv6 tunnel and kill-switch support.
- Health states separating process, handshake, route, DNS, and Internet readiness.
- Debian/Ubuntu packaging and automated integration tests.

## License

Copyright © 2026 Maxim Lyadvinsky.

`nns-app` is licensed under the GNU General Public License v3.0 or later (`GPL-3.0-or-later`).

## Snap applications inside an NNS namespace

`ip netns exec` creates a private mount namespace while binding
`/etc/netns/<namespace>/resolv.conf` over `/etc/resolv.conf`. Snap applications
need both cgroup v2 and securityfs visible in that mount namespace. Older
versions of nns-app could therefore fail with:

```text
internal error, please report: running "firefox" failed:
cannot find tracking cgroup
```

Version 1.0.19 mounts `cgroup2` and `securityfs` in the private command mount
namespace before dropping privileges to the configured application user. The
mounts disappear when the command exits and do not alter the host mount table.

Example:

```bash
nns-app run hidemy firefox --no-remote
```

To inspect the mounts from a namespaced shell:

```bash
nns-app run hidemy bash
findmnt /sys/fs/cgroup /sys/kernel/security
```


### WireGuard-specific diagnostics

```bash
sudo ip netns exec nns-browser wg show
sudo ip -n nns-browser link show type wireguard
sudo ip -n nns-browser rule show
sudo ip -n nns-browser route show table all
```

A WireGuard interface may exist before it has exchanged a handshake. `nns-app start` and `nns-app run` therefore require a real ping or HTTP data-path probe, not merely the presence of the interface.
