# nns-app

`nns-app` runs selected Linux applications inside dedicated network namespaces and attaches each namespace to an isolated network transport.

The project is designed as a small, auditable command-line alternative to routing the whole desktop through one VPN. A browser, messenger, crawler, build tool, or any other process can be launched in its own network namespace without changing the host's default route or DNS configuration.

> **Project status:** experimental. The current implementation provides an OpenVPN backend. The architecture and command model are being extended for WireGuard and other transports.

## Why nns-app?

System-wide VPN clients are often too broad: they alter host routes, replace DNS settings, and affect every application. `nns-app` isolates networking per application instead.

- Separate namespace, routes, DNS, firewall, and tunnel state for every named app.
- Host networking remains unchanged for normal applications.
- Built-in kill switch prevents protected application traffic from falling back to the host uplink.
- Multiple isolated app environments can coexist.
- Applications run as the original desktop user, not as root.
- Lifecycle is managed through systemd.
- The transport layer is intended to be backend-independent.

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
  |  application -> namespace firewall -> tunnel interface    |
  |                                         |                 |
  |  namespace DNS                          v                 |
  |  /etc/netns/nns-browser/resolv.conf   VPN / transport     |
  +-----------------------+-----------------------------------+
                          |
                    veth pair /30
                          |
                 host forwarding + NAT
                          |
                      host uplink
```

The tunnel control connection is allowed to reach only its configured endpoint through the namespace veth. Protected application traffic is allowed through the tunnel interface, while direct fallback is blocked when the kill switch is enabled.

## Current backend support

| Backend | Status | Notes |
|---|---:|---|
| OpenVPN | Available | Self-contained IPv4 TUN profiles with inline credentials |
| WireGuard | Planned | Native configuration and interface lifecycle |
| AmneziaWG | Planned | Candidate backend for obfuscated WireGuard deployments |
| Other transports | Design goal | Backend interface is expected to support additional routed transports |

The public command model should remain stable as new backends are introduced. Backend-specific options will be kept behind per-app configuration rather than exposed to launched applications.

## Requirements

Current builds target Ubuntu and require:

- Bash
- systemd
- iproute2 network namespaces
- iptables
- sudo
- util-linux (`setpriv`)
- curl and ping for readiness checks
- a supported tunnel backend; currently OpenVPN

Dependencies are installed automatically by `nns-app install` on supported Ubuntu systems.

## Installation

```bash
chmod +x nns-app.sh
sudo ./nns-app.sh install browser
```

The installer creates:

```text
/usr/local/bin/nns-app                 user-facing command
/usr/local/sbin/nns_app.sh             installed engine
/etc/nns-app/<app>/                    per-app configuration
/etc/systemd/system/nns-netns@.service namespace service
/etc/systemd/system/nns-openvpn@.service current OpenVPN backend service
/etc/sudoers.d/nns-app-<app>           restricted app-owner permissions
```

Run without arguments to display version and usage information:

```bash
nns-app
```

## Quick start

The current release uses an OpenVPN profile as the transport configuration:

```bash
sudo nns-app add browser ~/Downloads/location.ovpn
nns-app start browser
nns-app run browser curl -4 https://api.ipify.org
nns-app run browser firefox --no-remote
```

Check all configured environments:

```bash
nns-app list
```

Example output:

```text
Name               Status    Online
------------------ --------- -----------------------------------------------
browser            started   location | 10.20.30.40 -> 203.0.113.10
```

Stop the environment:

```bash
nns-app stop browser
```

## Commands

| Command | Description |
|---|---|
| `nns-app install <name>` | Install or refresh the engine and create a named app environment |
| `nns-app add <name> <profile>` | Import a backend profile and make it the active profile |
| `nns-app start <name>` | Create the namespace and start its transport |
| `nns-app stop <name>` | Stop the transport and remove the runtime namespace |
| `nns-app run <name> <command> [args...]` | Run a command inside the namespace as the configured user |
| `nns-app list` | Show app state, active profile, tunnel address, and external address |
| `nns-app remove <name>` | Remove one app environment and its profiles |
| `nns-app purge` | Remove the engine and all nns-app environments |
| `nns-app --version` | Show version, author, and license |

App names may contain letters, digits, `.`, `_`, and `-`, with a maximum length of 32 characters.

## Per-app configuration

Each app has a root-owned configuration file:

```text
/etc/nns-app/<name>/<name>.cfg
```

Edit it with:

```bash
sudoedit /etc/nns-app/browser/browser.cfg
```

Important settings in the current release:

| Setting | Default | Purpose |
|---|---:|---|
| `APP_USER` | installing user | User identity used for launched applications |
| `DEFAULT_PROFILE` | empty | Active backend profile |
| `KILLSWITCH` | `on` | Block direct application traffic outside the tunnel |
| `AUTOSTART` | `off` | Enable the app services at boot |
| `WAN_IFACE` | `auto` | Host uplink or an explicitly pinned interface |
| `DNS_SERVERS` | `1.1.1.1 9.9.9.9` | Namespace-only DNS servers |
| `DISABLE_IPV6` | `on` | Disable IPv6 inside the namespace |
| `READY_TIMEOUT` | `75` | Seconds to wait for a usable data path |
| `EXTERNAL_IP_URL` | `https://api.ipify.org` | Endpoint used by status checks |

Current OpenVPN-specific compatibility settings are also stored here. They will move under backend-specific configuration as the multi-backend design matures.

## Isolation and security model

### Namespace isolation

Every app receives its own:

- Linux network namespace;
- loopback device;
- veth pair and allocated `/30` network;
- route table;
- resolver file under `/etc/netns`;
- namespace-local firewall;
- tunnel process and systemd instance.

### Kill switch

With `KILLSWITCH="on"`:

- direct application output through the namespace veth is denied;
- only the configured transport endpoint is reachable before the tunnel is up;
- established return traffic is accepted;
- application traffic is accepted through the tunnel interface;
- `nns-app run` refuses to launch a protected command until the data path is online.

The kill switch is intended to prevent accidental fallback. It is not a replacement for auditing the host firewall, kernel, tunnel backend, or provider.

### Host DNS protection

Namespace applications use `/etc/netns/<namespace>/resolv.conf`. The current OpenVPN backend disables OpenVPN's systemd-resolved helper so a profile cannot replace the host resolver through a namespace boundary.

### Privilege separation

Namespace and tunnel setup require root. A launched application is entered into the namespace and then permanently dropped to the configured user with `setpriv`. Commands are executed directly without `eval` or shell re-parsing.

The installer creates a narrowly scoped sudoers rule allowing the app owner to run only routine operations for that app without repeatedly entering a password.

## OpenVPN backend notes

The current backend intentionally accepts a restricted profile subset:

- TUN profiles only; TAP is currently rejected.
- Credentials and certificates must be embedded in the profile.
- Interactive password prompts are unsupported.
- Profile scripts, plugins, management directives, external key paths, and other root-executed hooks are rejected.
- The original source profile is never modified; `nns-app` stores and, when enabled, normalizes a managed copy.
- Vendor-specific patched OpenVPN directives are not supported by the stock Ubuntu OpenVPN binary.

Automatic profile compatibility changes can include disabling DCO, permitting a detected legacy certificate chain, and adding a legacy CBC cipher fallback. Disable this behavior per app with:

```bash
PROFILE_FIXUPS="off"
```

Then re-add the original profile.

## Troubleshooting

Show overall state:

```bash
nns-app list
```

Follow the current OpenVPN backend log:

```bash
sudo journalctl -fu nns-openvpn@browser.service
```

Inspect namespace creation and firewall setup:

```bash
sudo journalctl -u nns-netns@browser.service -n 100 --no-pager
```

Inspect routes:

```bash
sudo ip -n nns-browser route
```

Inspect namespace firewall counters:

```bash
sudo ip netns exec nns-browser iptables -nvL --line-numbers
```

Test connectivity without launching a GUI application:

```bash
nns-app run browser ping -c 3 1.1.1.1
nns-app run browser curl -4 https://api.ipify.org
```

A tunnel backend can report that its handshake completed while the provider still does not pass data. `nns-app` therefore checks the data path separately and reports the environment as offline until traffic succeeds.

## Known limitations

- Linux and systemd only.
- Ubuntu is the primary tested platform.
- IPv4 is the primary supported path; IPv6 is disabled by default.
- The current release implements only the OpenVPN backend.
- Stopping an app currently removes its runtime namespace rather than keeping a persistent idle namespace.
- Profile selection currently follows the most recently added profile.
- Firewall management currently uses iptables.
- Desktop applications with strict single-instance or sandbox rules may require application-specific launch options.
- Provider-side session limits, stale mappings, authentication policy, and custom protocol extensions are outside the engine's control.

## Roadmap

Planned development areas include:

1. A transport/backend abstraction shared by OpenVPN, WireGuard, and future providers.
2. Native WireGuard profile import and `wg`/`wg-quick` lifecycle management.
3. Fast profile switching without destroying the application namespace.
4. Explicit `profile list`, `profile select`, and `switch` commands.
5. nftables support with transactional rule updates.
6. IPv6 tunnel and kill-switch support.
7. Backend health states separating process, handshake, route, DNS, and Internet readiness.
8. Optional persistent namespaces and make-before-break transport switching.
9. Packaging for Debian/Ubuntu and automated integration tests.

## Design principles

- Keep host networking stable.
- Isolate each application independently.
- Fail closed when the kill switch is enabled.
- Treat imported profiles as untrusted input.
- Avoid executing provider-supplied scripts as root.
- Keep the engine small enough to audit.
- Separate generic namespace lifecycle from transport-specific behavior.
- Preserve a consistent CLI as backends are added.

## Contributing

Issues and patches are welcome, especially for:

- backend abstraction design;
- WireGuard and AmneziaWG support;
- namespace/firewall cleanup correctness;
- additional Linux distribution testing;
- reproducible integration tests;
- security review.

Please avoid committing VPN credentials, private keys, access tokens, generated runtime profiles, packet captures containing sensitive traffic, or provider-specific secrets.

## License

Copyright © 2026 Maxim Lyadvinsky.

This project is licensed under the **GNU General Public License v3.0 or later** (`GPL-3.0-or-later`). See [`LICENSE`](LICENSE) for the full license text.
