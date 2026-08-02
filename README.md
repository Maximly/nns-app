# nns-app

`nns-app` runs selected Linux applications inside dedicated network namespaces and connects each namespace through an isolated network transport.

A browser, messenger, crawler, build tool, or another process can use its own VPN without replacing the host's default route or DNS configuration. Each named environment has separate routes, DNS, firewall state, tunnel state, and a kill switch.

> **Release:** 1.0.11  
> **Status:** experimental  
> **Current backend:** OpenVPN  
> **Planned backends:** WireGuard, AmneziaWG, and provider-specific transports

## Main features

- One Linux network namespace per named application environment.
- Host networking and host DNS remain unchanged.
- Namespace-only resolver configuration under `/etc/netns/`.
- Kill switch blocks direct fallback to the host uplink.
- Applications run as the configured desktop user, not as root.
- systemd manages namespace and OpenVPN lifecycles.
- Self-contained OpenVPN profiles can be imported.
- A public OpenVPN relay can be selected automatically with `add ... any`.
- Strict five-second startup failure handling.
- Optional `-i` asynchronous start mode leaves a slow connection running.

## Architecture

```text
                         Linux host

  normal applications ---------------------------> host uplink

  nns-app run browser firefox
              |
              v
  +-----------------------------------------------------------+
  | network namespace: nns-browser                            |
  |                                                           |
  | application -> namespace firewall -> tunnel interface     |
  |                                         |                 |
  | namespace DNS                           v                 |
  | /etc/netns/nns-browser/resolv.conf    VPN transport       |
  +-----------------------+-----------------------------------+
                          |
                    veth pair /30
                          |
                 host forwarding + NAT
                          |
                      host uplink
```

Before the tunnel is online, the namespace may contact only the configured VPN endpoint and its namespace DNS servers. Protected application traffic is accepted through the tunnel interface. Direct fallback is blocked when the kill switch is enabled.

## Requirements

The current release targets Ubuntu with systemd and requires:

- Bash
- OpenVPN
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

```bash
chmod +x nns-app.sh
sudo ./nns-app.sh install browser
```

The installer creates or refreshes:

```text
/usr/local/bin/nns-app
/usr/local/sbin/nns_app.sh
/etc/nns-app/<name>/
/etc/systemd/system/nns-netns@.service
/etc/systemd/system/nns-openvpn@.service
/etc/sudoers.d/nns-app-<name>
```

Verify the installed version:

```bash
nns-app --version
```

Expected:

```text
nns-app 1.0.11
Author:  Maxim Lyadvinsky
License: GPL-3.0-or-later
```

Running `install` again refreshes the engine, systemd units, and sudoers rules while preserving existing app configuration and imported profiles:

```bash
sudo ./nns-app.sh install browser
```

## Quick start with an existing profile

```bash
sudo nns-app add browser ~/Downloads/location.ovpn
nns-app start browser
nns-app run browser curl -4 https://api.ipify.org
nns-app run browser firefox --no-remote
```

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

The current implementation uses the VPN Gate public relay list. Relays are operated by volunteers and may be slow, unavailable, logged, filtered, or untrusted. This feature is suitable for testing and low-risk HTTPS traffic; it should not be treated as trusted privacy infrastructure.

Profiles downloaded through `any` pass the same validation and managed-copy processing as locally imported profiles.

## Startup modes

### Strict start

```bash
nns-app start browser
```

Strict start waits up to `READY_TIMEOUT`, which defaults to five seconds. A tunnel interface alone is not considered success: `nns-app` also checks that the namespace can pass traffic.

When the data path is still offline after the deadline, `nns-app`:

1. prints recent OpenVPN log lines;
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

Applications are still protected: with the kill switch enabled, `nns-app run` refuses to launch a command until the tunnel route and data path are usable.

## Commands

| Command | Description |
|---|---|
| `nns-app install <name>` | Install or refresh the engine and create a named environment |
| `nns-app add <name> <profile.ovpn>` | Validate and import a self-contained OpenVPN profile |
| `nns-app add <name> any [country]` | Find and import a current public VPN Gate profile |
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
| `DEFAULT_PROFILE` | empty | Active OpenVPN profile |
| `KILLSWITCH` | `on` | Block direct traffic outside the tunnel |
| `AUTOSTART` | `off` | Enable the environment at boot |
| `WAN_IFACE` | `auto` | Host uplink or explicitly selected interface |
| `DNS_SERVERS` | `1.1.1.1 9.9.9.9` | Namespace-only DNS resolvers |
| `DISABLE_IPV6` | `on` | Disable IPv6 inside the namespace |
| `PROFILE_FIXUPS` | `on` | Normalize the managed copy for compatibility |
| `DISABLE_DCO` | `off` | Explicit OpenVPN DCO policy |
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

## Isolation and security

Every environment receives its own:

- network namespace;
- loopback interface;
- veth pair and allocated `/30` network;
- route table;
- resolver file;
- namespace-local firewall;
- OpenVPN process and systemd service instances.

OpenVPN DNS helper integration is disabled so a profile cannot replace host DNS through `systemd-resolved`.

Namespace and tunnel setup require root. `nns-app run` enters the namespace as root and then permanently drops to `APP_USER` with `setpriv` before executing the requested program. Commands are executed directly without `eval` or shell re-parsing.

The installer creates restricted sudoers commands for routine operations. Re-run `install` after upgrading so new command forms such as `start -i` are added to the sudoers rule.

## Troubleshooting

Show all environments:

```bash
nns-app list
```

Follow OpenVPN logs:

```bash
sudo journalctl -fu nns-openvpn@browser.service
```

Inspect namespace setup:

```bash
sudo journalctl -u nns-netns@browser.service -n 100 --no-pager
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
- OpenVPN is the only implemented backend in this release.
- Runtime namespaces are removed on normal stop.
- The most recently added profile becomes active.
- Firewall management currently uses iptables.
- Public relays may disappear or change without notice.
- Provider-side session limits, stale mappings, custom clients, and custom protocol extensions are outside the generic OpenVPN backend's control.
- GUI applications with single-instance or sandbox policies may need application-specific launch options.

## Roadmap

- Transport/backend abstraction shared by OpenVPN, WireGuard, and future transports.
- Native WireGuard configuration without host-global `wg-quick` side effects.
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
