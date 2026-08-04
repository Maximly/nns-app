# nns-app

`nns-app` runs selected Linux applications in dedicated network namespaces and
connects each namespace through OpenVPN or WireGuard without replacing the
host's default route or DNS configuration.

**Release:** 1.3.21

**Supported platforms:** Ubuntu and Fedora with systemd  
**VPN backends:** OpenVPN 2.6+, WireGuard, and inherit-only child namespaces

The release includes both the modular source tree and a pre-built,
single-file installer: `nns-app-install.sh`.

## Quick start

Install nns-app once on the local Linux host:

```bash
chmod +x nns-app-install.sh
sudo ./nns-app-install.sh install
```

Then choose one of the following two alternatives. Use a different application
name if you want to keep both configurations on the same client.

### Run a VPN locally

Install the application environment, then add either your own profile:

```bash
nns-app install my-private-app
nns-app add my-private-app ~/my-base-profile.ovpn
nns-app run my-private-app ping -c 4 1.1.1.1
```

or let nns-app select and test a free VPN Gate profile, optionally by country:

```bash
nns-app install my-private-app
nns-app add my-private-app any
# Or, for example: nns-app add my-private-app any JP
nns-app run my-private-app ping -c 4 1.1.1.1
```

The selected provider profile runs on the current host. The `ping` process runs
inside `my-private-app` and its traffic exits through that profile.

### Run a VPN on a remote Linux host

Use your own profile:

```bash
nns-app install my-private-app via --remote user@remote-host
nns-app add my-private-app ~/my-base-profile.ovpn
nns-app run my-private-app ping -c 4 1.1.1.1
```

or select a free VPN Gate profile and deploy it automatically to the remote
host:

```bash
nns-app install my-private-app via --remote user@remote-host
nns-app add my-private-app any
# Or, for example: nns-app add my-private-app any JP
nns-app run my-private-app ping -c 4 1.1.1.1
```

The first command bootstraps or upgrades nns-app on `remote-host` over SSH. The
second command either deploys the supplied profile or selects a free profile,
then automatically creates the private remote exit, gateway, client
credentials, and local link. The final command runs `ping` locally inside
`my-private-app`, with its traffic routed through the remote host and then
through the deployed provider VPN. Existing `ssh user@remote-host` access and
remote `sudo` permission are required for the first bootstrap.

VPN Gate is a volunteer-operated public network. Relays may disappear, log
traffic, or provide inconsistent performance. Use end-to-end encryption and a
provider-managed profile for reliable or sensitive use.

## Highlights

- One isolated network namespace per named application environment.
- OpenVPN and WireGuard client profiles.
- Per-environment DNS, routes, firewall state, tunnel state, and kill switch.
- Local VPN chaining through `--via <upstream-app>`.
- Inherit-only child namespaces that share one upstream tunnel without opening another VPN session.
- Detailed `status` output with focused failure logs.
- Adaptive data-path watchdog that preserves running application namespaces.
- Snap desktop-application support inside private mount namespaces.
- Managed remote OpenVPN gateways routed through a selected remote nns-app exit.
- Three-command automatic remote deployment over SSH, with automatic sharing of matching provider exits plus manual enrollment, synchronization, credential rotation, and status.
- Direct, SSH-forward, stunnel, and Cloak gateway transports with portable `.nnslink` bundles.
- Unique client certificates and TLS Crypt v2 keys for gateway clients.
- Collision-safe network, routing-table, and policy-priority allocation.
- Dedicated, tagged gateway firewall chains.
- Fedora firewalld integration with a private nns-app zone and forwarding policy.
- Cycle detection and systemd dependencies for chained environments.
- Weekly atomic CRL renewal for managed gateways.
- Transactional gateway, client, and PKI changes.
- Process-wide and per-object locking for administrative operations.

## Names used in the examples

The examples use descriptive placeholders consistently:

| Name | Meaning |
|---|---|
| `my-private-app` | A local application environment with its own VPN profile |
| `my-upstream-vpn` | A local nns-app environment used as another environment's upstream |
| `my-base-profile.ovpn` | A provider OpenVPN profile imported into an nns-app environment |
| `my-app-profile.ovpn` | The profile used by a downstream application environment |
| `my-wireguard-profile.conf` | A provider WireGuard profile imported into an nns-app environment |
| `my-remote-exit` | The nns-app environment on the remote Linux box that provides egress |
| `my-relay` | The managed gateway exposed by the remote Linux box |
| `my-linux-client` | One unique gateway client identity for a local Linux box |
| `my-remote-profile.ovpn` | A direct self-contained profile exported by the remote gateway |
| `my-remote-link.nnslink` | A gateway profile plus transport metadata and pinned transport material |
| `my-remote-vpn` | The local nns-app environment that imports the remote profile |

Replace these names with labels that describe your own applications, profiles,
servers, and clients.

Paths beginning with `~` refer to the invoking user's home directory. The shell
expands `~` before `sudo` starts `nns-app`, so a command such as
`sudo nns-app add my-private-app ~/my-base-profile.ovpn` reads the profile from
the current user's home, not from `/root`. Imported profiles are copied into
root-owned nns-app storage. Gateway exports are written with mode `0600` and,
when invoked through `sudo`, ownership is returned to the invoking user.

## Simple automatic remote mode

For the usual case—run a local application through a provider profile that
must execute on a remote Linux host—the public workflow is only:

```bash
nns-app install my-private-app via --remote user@remote-host
nns-app add my-private-app ~/my-base-profile.ovpn
nns-app run my-private-app ping 1.1.1.1
```

The compact `--via-remote user@remote-host` form remains accepted as an alias.

The first command uses the invoking user's existing SSH access. It confirms and
pins the host key, installs or upgrades the same nns-app version remotely,
creates a dedicated root-owned SSH key for subsequent unattended operation, and
installs a restricted remote helper. Remote `sudo` may request a password once
during this bootstrap.

The second command validates the self-contained provider profile locally and
then deploys it remotely. nns-app automatically creates a hidden remote exit,
a loopback-only managed OpenVPN gateway, a unique client credential, and the
local `.nnslink` profile. It also starts the local environment and enables both
ends for boot recovery. The default data transport is a supervised SSH local
forward through the existing SSH port, so no additional cloud firewall rule or
public gateway port is needed.

When another automatic client on the same remote host uses an identical
recorded profile, nns-app reuses that provider exit immediately. If the profile
files differ but the newly started provider session receives the same
provider-side tunnel IPv4 address as an existing automatic exit, nns-app treats
them as the same single-session provider identity. The address comparison runs
as soon as the candidate tunnel address is assigned, before full Internet
readiness is required, so a provider that drops the older duplicate session
cannot trap deployment in a reconnect/timeout loop. nns-app removes the
duplicate exit, reconnects the existing pool, and adds a new unique gateway
client. The result is one provider VPN session and one remote gateway shared by several
local nns-app environments, while each local machine keeps its own certificate,
private key, TLS Crypt v2 key, SSH key, and lifecycle state.

The third command executes the requested process inside the already running
local namespace. If the environment was stopped manually, `run` starts it
again. Normal status, synchronization, and credential rotation remain
available:

```bash
nns-app status my-private-app
sudo nns-app remote status my-private-app
sudo nns-app remote sync my-private-app
sudo nns-app remote rotate my-private-app
```

Requirements for automatic mode:

- use a new or otherwise unconfigured application name; nns-app will not silently convert an existing local-profile environment into a remote one;
- `ssh user@remote-host` must already work for the invoking user, using a key,
  agent, or an interactive password during the first bootstrap;
- the remote SSH endpoint must resolve to IPv4; nns-app's managed data plane is currently IPv4-only;
- that remote account must be allowed to run `sudo` during bootstrap;
- provider OpenVPN profiles must contain inline credentials and must not need
  an interactive password, as in local nns-app mode.

Automatic-remote environments use `AUTOSTART="on"`. After either client or
remote host reboots, systemd recreates the remote provider exit, private
gateway, local SSH forward, OpenVPN client, online check, and watchdog. Running
applications themselves do not survive a client reboot.

For a shared pool, `nns-app stop <app>` disconnects that local member and marks
it inactive. The remote provider exit remains online while another pool member
is active; the last active member stops the shared gateway and exit. `start` or
`run` reactivates the member and brings the pool online when necessary.

Removing an automatic-remote app revokes that client's remote gateway
credential, removes its state and dedicated SSH key, and preserves a shared
provider pool while other clients still reference it. The managed gateway and
provider exit are removed only with the last pool member:

```bash
nns-app remove my-private-app
```

`nns-app purge` performs the same ownership-scoped cleanup for every automatic
remote before deleting local nns-app state and binaries. If a remote host is
unreachable, removal fails before local credentials are deleted, so it can be
retried. Use `--local-only` only when intentionally abandoning remote objects:

```bash
sudo nns-app purge --local-only
```

Cleanup does not uninstall the shared nns-app engine or VPN packages from the
remote host because other clients may still use them.

The lower-level `remote`, `gateway`, `link`, `--transport`, and manual export
commands remain supported for custom listeners, public direct gateways,
stunnel, Cloak, external PKI, or other fine tuning.

## Build or use the pre-built installer

The repository already contains:

```text
nns-app-install.sh
```

Install directly from it:

```bash
chmod +x nns-app-install.sh
sudo ./nns-app-install.sh install
```

To rebuild it from the modular source:

```bash
./build.sh
```

The equivalent Make target is:

```bash
make build
```

The build syntax-checks every ordered module under `src/`, concatenates the
modules, validates the combined Bash file, compiles every embedded Python
helper, and writes a deterministic `nns-app-install.sh` in the project root.

Run the static and helper tests as a regular user:

```bash
make test
```

The tests use private temporary directories and do not require root. Use root
only for installation and for commands that change live networking, systemd,
firewall, routing, or PKI state.

## Source layout

```text
src/
  00-preamble.sh     metadata, help, common helpers, and locking
  10-config.sh       configuration loading and upstream-graph validation
  20-install.sh      dependencies, systemd units, and app provisioning
  30-profiles.sh     OpenVPN/WireGuard validation and VPN Gate selection
  40-network.sh      endpoints, firewall rules, and namespace lifecycle
  50-runtime.sh      VPN execution and app start/stop lifecycle
  60-gateway.sh      gateway PKI, routing, firewall, and client management
  65-link-remote.sh   inherit sharing, .nnslink transport, and SSH management
  70-run-status.sh   application execution and status reporting
  90-main.sh         public and internal command dispatch

tools/
  check_embedded_python.py

tests/
  test-static.sh
  test-functions.sh

CONTRIBUTING.md      contributor-facing safety and ownership invariants
CHANGELOG.md
```

`CONTRIBUTING.md` contains the implementation rules that must remain true when
changing routing, firewall, PKI, locking, configuration, or lifecycle code.
The README keeps only the user-facing architecture and operating workflow.

The generated installer remains a single executable file so it can be copied
to a new Ubuntu or Fedora host without installing the source tree.

## Architecture

### Direct application environment

```text
application
  -> nns-my-private-app
  -> OpenVPN or WireGuard
  -> host NAT
  -> host uplink
```

The application environment has its own route table and resolver configuration.
The host route and host DNS remain unchanged.

### Chained application environment

```text
application
  -> nns-my-private-app
  -> application-specific VPN
  -> veth inside nns-my-upstream-vpn
  -> upstream VPN tunnel
  -> Internet
```

Configure a persistent upstream:

```bash
sudo nns-app install my-private-app --via my-upstream-vpn
```

Or override the upstream for one start:

```bash
nns-app start -i my-private-app --via my-upstream-vpn
```

Before its own tunnel is ready, the downstream namespace can reach only its
configured VPN endpoint through the upstream tunnel. If the upstream tunnel
disappears, forwarding rules stop matching and traffic is dropped instead of
falling back to the upstream namespace's host-facing veth.

`nns-app` rejects direct and indirect upstream cycles such as
`my-app-a -> my-app-b -> my-app-a`. Generated systemd drop-ins order downstream
namespaces after `nns-online@<upstream>.service` and bind their lifecycle to it.

### Inherit-only local sharing

An inherit-only child has its own namespace, resolver, process boundary, and
kill switch, but does not start OpenVPN or WireGuard itself:

```text
application
  -> nns-my-shared-app
  -> veth inside nns-my-remote-vpn
  -> my-remote-vpn tunnel
  -> Internet
```

Create it with:

```bash
sudo nns-app install my-shared-app \
    --backend inherit \
    --via my-remote-vpn
nns-app start my-shared-app
nns-app run my-shared-app firefox --no-remote
```

The child OUTPUT policy permits its veth, while the upstream namespace permits
forwarding only into its verified tunnel. If the upstream stops, systemd binds
the child lifecycle to it and the forwarding/NAT path disappears; no host-uplink
fallback is installed. Inherit mode deliberately rejects `--via host`.

### Managed remote gateway

```text
local application
  -> local nns-app OpenVPN client
  -> remote host OpenVPN listener
  -> remote gateway TUN
  -> dedicated policy table
  -> transit veth
  -> selected remote nns-app exit
  -> remote provider tunnel
  -> Internet
```

The remote OpenVPN listener remains in the remote host namespace. Only traffic
arriving from the gateway TUN is policy-routed into the selected nns-app exit.
Host-generated packets that happen to use an address from the client pool are
not captured by that rule.

The gateway data path uses:

- a unique `iif <gateway-tun>` policy rule;
- a dedicated routing table with an explicit blackhole fallback;
- a dedicated host-to-namespace transit `/30`;
- dedicated tagged iptables chains;
- source-restricted forwarding;
- NAT only through the selected remote VPN tunnel;
- loose reverse-path filtering only on managed asymmetric interfaces.

## Requirements

The installer detects Ubuntu/Debian or Fedora and installs the matching packages
with `apt-get` or `dnf`/`dnf5`:

- Bash and systemd
- OpenVPN 2.6 or newer
- `wireguard-tools`
- `iproute2` on Ubuntu/Debian or `iproute` on Fedora
- `iptables` on Ubuntu/Debian or `iptables-nft` on Fedora
- `iputils-ping` on Ubuntu/Debian or `iputils` on Fedora
- `openssh-client` on Ubuntu/Debian or `openssh-clients` on Fedora
- sudo, curl, OpenSSL, Python 3, and `util-linux`

On Fedora, nns-app keeps SELinux enabled and restores the standard contexts of
installed engine, systemd, and sudoers files. When firewalld is active, nns-app
creates a dedicated `nns-app` zone and `nns-app-forward` policy, assigns only its
managed host-side interfaces, and removes those global objects during purge.
The existing per-environment iptables-nft rules remain responsible for the kill
switch, endpoint restrictions, NAT, and detailed forwarding policy.

Optional transports require a locally installed binary on both ends:

- `stunnel4` (or `stunnel`) for `--transport stunnel`;
- `ck-server` on the gateway and `ck-client` on clients for `--transport cloak`.

The installer never downloads transport binaries from third-party release pages.

## Install and create an application environment

Install or refresh the engine:

```bash
sudo ./nns-app-install.sh install
```

Installed paths:

```text
/usr/local/sbin/nns_app.sh
/usr/local/bin/nns-app
/etc/systemd/system/nns-netns@.service
/etc/systemd/system/nns-openvpn@.service
/etc/systemd/system/nns-online@.service
/etc/systemd/system/nns-watchdog@.service
/etc/systemd/system/nns-watchdog@.timer
/etc/systemd/system/nns-gateway@.service
/etc/systemd/system/nns-gateway-crl-refresh@.service
/etc/systemd/system/nns-gateway-crl-refresh@.timer
```

`nns-openvpn@.service` is retained as the compatibility unit name, but it
manages OpenVPN, WireGuard, a transported OpenVPN client, or an inherit-only keeper process.

Create an environment:

```bash
sudo nns-app install my-private-app
```

Import an OpenVPN profile:

```bash
sudo nns-app add my-private-app ~/my-base-profile.ovpn
```

Or import a WireGuard profile:

```bash
sudo nns-app add my-private-app ~/my-wireguard-profile.conf
```

Start and use the environment:

```bash
nns-app start my-private-app
nns-app status my-private-app
nns-app run my-private-app curl -4 https://api.ipify.org
nns-app run my-private-app firefox --no-remote
nns-app run my-private-app bash
```

`run` restores the invoking user’s command-search path after privilege dropping
and appends the standard `/usr/local/sbin`, `/usr/sbin`, and `/sbin` locations.
Interactive shells therefore retain user-installed command directories while
system diagnostics such as `ip`, `ss`, and `ifconfig` remain discoverable. The
rest of the environment is deliberately allow-listed rather than copied
wholesale; dangerous loader and shell-startup variables are not inherited.

Stop it:

```bash
nns-app stop my-private-app
```

Remove the environment and its imported profiles:

```bash
sudo nns-app remove my-private-app
```

`remove` refuses to delete an environment that is still configured as an
upstream for another application environment or gateway.

## Startup modes

Strict start waits for the configured data path:

```bash
nns-app start my-private-app
```

The default timeout is five seconds unless changed in the application configuration.
On failure, the VPN service and namespace are stopped.

Asynchronous start returns after the initial launch and leaves a slow
connection retrying:

```bash
nns-app start -i my-private-app
```

Check it later:

```bash
nns-app status my-private-app
```

## Local chaining

Create and start an upstream VPN environment:

```bash
sudo nns-app install my-upstream-vpn
sudo nns-app add my-upstream-vpn ~/my-base-profile.ovpn
nns-app start -i my-upstream-vpn
nns-app status my-upstream-vpn
```

Create a second environment whose VPN connection must travel through that
upstream:

```bash
sudo nns-app install my-private-app --via my-upstream-vpn
sudo nns-app add my-private-app ~/my-app-profile.ovpn
nns-app start -i my-private-app
nns-app status my-private-app
```

A one-start override does not change the saved configuration:

```bash
nns-app start -i my-private-app --via my-upstream-vpn
```

Use `--via host` for a one-start direct-host override.

## Public VPN Gate profile selection

Download, rank, probe, and import a public OpenVPN profile:

```bash
sudo nns-app add my-private-app any
sudo nns-app add my-private-app any JP
sudo nns-app add my-private-app any Germany
```

Force a fresh server list:

```bash
sudo nns-app add my-private-app any US --refresh
```

Probe candidates through an upstream environment:

```bash
sudo nns-app add my-private-app any US --via my-upstream-vpn
```

VPN Gate is a volunteer network. Profiles can disappear or stop responding
without notice; use `status` and provider-managed profiles for reliable
deployments.

## Status commands

List all application environments:

```bash
nns-app list
```

Show a detailed report:

```bash
nns-app status my-private-app
```

Show the IP and route for the current shell context:

```bash
nns-app myip
```

On the host, this reports the host source/local IPv4, external IPv4, default
route, and interface. Inside a shell started with `nns-app run <app> bash`, the
same command automatically reports that app's tunnel path. Inspect a named app
from any host shell with:

```bash
nns-app myip my-private-app
```

For an automatic-remote app, the report includes the SSH remote host, managed
gateway and remote provider exit. The SSH account name is intentionally omitted
from this concise route report. `myip <app>` is read-only and does not start a
stopped environment.

The report distinguishes `ONLINE`, `OFFLINE`, `STARTING`, `FAILED`, and
`STOPPED` and includes:

- active profile and backend;
- configured and runtime upstream;
- namespace and backend service state;
- endpoint and current OpenVPN handshake stage;
- WireGuard endpoint, handshake age, and transfer totals;
- tunnel interface and address;
- external IPv4 and data-path probe;
- focused cuts from the current systemd invocation on failure.

## Managed remote gateway

On the remote Linux box, first create and start the nns-app environment that will
provide the gateway's final Internet exit:

```bash
sudo nns-app install my-remote-exit
sudo nns-app add my-remote-exit ~/my-base-profile.ovpn
nns-app start -i my-remote-exit
nns-app status my-remote-exit
```

Create a gateway routed through that exit:

```bash
sudo nns-app gateway create my-relay \
    --via my-remote-exit \
    --listen tcp:443 \
    --public vpn.example.net:443
```

`--public` is written into exported client profiles. It may differ from the
local listener when a router forwards another public port.

Optional network and DNS settings:

```bash
sudo nns-app gateway create my-relay \
    --via my-remote-exit \
    --listen udp:443 \
    --public vpn.example.net:443 \
    --pool 10.200.40.0/24 \
    --dns "1.1.1.1 9.9.9.9"
```

Custom pools are rejected when they overlap:

- live host or namespace routes;
- existing application networks;
- existing gateway pools or transit networks;
- the reserved app range `10.240.0.0/16`;
- the reserved gateway transit range `10.239.0.0/16`.

Create one client identity per local machine:

```bash
sudo nns-app gateway client add my-relay my-linux-client
sudo nns-app gateway client export my-relay my-linux-client \
    --output ~/my-remote-profile.ovpn
```

Start and inspect the remote gateway:

```bash
sudo nns-app gateway start my-relay
sudo nns-app gateway status my-relay
sudo nns-app gateway list
sudo nns-app gateway client list my-relay
```

Transfer the exported profile over an authenticated channel. On the local box:

```bash
sudo nns-app install my-remote-vpn
sudo nns-app add my-remote-vpn ~/my-remote-profile.ovpn
nns-app start -i my-remote-vpn
nns-app status my-remote-vpn
nns-app run my-remote-vpn curl -4 https://api.ipify.org
```

Rotate a client to a new certificate, private key, TLS Crypt v2 key, and
transport identity generation:

```bash
sudo nns-app gateway client rotate my-relay my-linux-client
```

Revoke a lost client identity:

```bash
sudo nns-app gateway client revoke my-relay my-linux-client
```

Revocation and CRL generation are transactional. Active gateways are restarted
after revocation so the client session is disconnected immediately. A systemd
timer refreshes every gateway CRL weekly; `gateway status` shows its next
update date.

Remove the gateway and all of its private material:

```bash
sudo nns-app gateway remove my-relay
```

The gateway does not automatically open the host firewall or configure an
external router. Permit or forward the selected TCP/UDP port separately.

### DPI-resistant gateway transports

Direct mode remains the default:

```bash
sudo nns-app gateway create my-relay \
    --via my-remote-exit \
    --listen tcp:443 \
    --public vpn.example.net:443 \
    --transport direct
```

For a TLS wrapper:

```bash
sudo nns-app gateway create my-relay \
    --via my-remote-exit \
    --listen tcp:443 \
    --public vpn.example.net:443 \
    --transport stunnel
```

For Cloak:

```bash
sudo nns-app gateway create my-relay \
    --via my-remote-exit \
    --listen tcp:443 \
    --public vpn.example.net:443 \
    --transport cloak \
    --server-name www.bing.com
```

Wrapped gateways bind OpenVPN to a private loopback port and expose only the
transport listener publicly. Cloak uses `www.bing.com` as its default decoy
server name; override it with `--server-name`, and keep it different from the
gateway's own public hostname to prevent a redirection loop. Export wrapped
gateways as `.nnslink`; a plain `.ovpn` cannot carry the wrapper configuration:

```bash
sudo nns-app gateway client export my-relay my-linux-client \
    --format nnslink \
    --output ~/my-remote-link.nnslink

sudo nns-app install my-remote-vpn
sudo nns-app link import my-remote-vpn ~/my-remote-link.nnslink
```

A bundle contains a versioned JSON manifest, the self-contained OpenVPN profile,
and only the transport material required by that client. Imports reject links,
devices, absolute paths, parent traversal, unknown files, oversized content,
unsafe metadata, malformed Cloak settings, invalid stunnel trust material, and
unsupported manifest versions. The managed client starts the transport in the
application namespace before OpenVPN and stops both when either process fails.

### SSH remote management

Register a remote host once. Both machines must run nns-app 1.2.0 or newer.
The first connection records its SSH host key; subsequent commands require that
pinned key and non-interactive SSH/sudo:

```bash
sudo nns-app remote add edge1 --ssh user@vpn.example.net
```

Create a unique remote client and import its bundle locally:

```bash
sudo nns-app remote connect edge1:my-relay \
    --client my-linux-client \
    --name my-remote-vpn
```

Refresh the local bundle without changing credentials, rotate the remote
certificate/key generation, or inspect both management and gateway state:

```bash
sudo nns-app remote sync my-remote-vpn
sudo nns-app remote rotate my-remote-vpn
sudo nns-app remote status my-remote-vpn
```

When `remote sync` or `remote rotate` replaces a bundle for a running local app,
nns-app restarts the complete namespace so endpoint routes and kill-switch rules
are rebuilt from the synchronized transport metadata.

SSH is used only for enrollment and management. The running OpenVPN/stunnel/Cloak
data path connects directly to the gateway public endpoint and continues without
an SSH session.

## Gateway security

Each managed gateway has:

- a private CA;
- a unique certificate and private key per client;
- a unique TLS Crypt v2 client key;
- TLS Crypt v2 `force-cookie`;
- TLS 1.2 minimum;
- AEAD data ciphers;
- a certificate revocation list;
- atomic configuration and CRL replacement.

Administrative gateway and PKI operations are serialized with `flock`.
Gateway creation and client enrollment use staging directories and publish
their final state only after validation.

Direct OpenVPN with TLS Crypt v2 is harder to fingerprint than a plain
OpenVPN profile, but it is not indistinguishable from HTTPS. Strong protocol
filtering may still require a separate camouflage transport.

## App configuration

Each application environment has:

```text
/etc/nns-app/<name>/<name>.cfg
```

Important fields:

```ini
DEFAULT_PROFILE=""
VPN_TYPE=""
KILLSWITCH="on"
AUTOSTART="off"
UPSTREAM_APP=""
WAN_IFACE="auto"
DNS_SERVERS="1.1.1.1 9.9.9.9"
DISABLE_IPV6="on"
DISABLE_DCO="off"
PROFILE_FIXUPS="on"
READY_TIMEOUT="5"
EXTERNAL_IP_URL="https://api.ipify.org"
WATCHDOG_MODE="auto"
WATCHDOG_FAILURES="3"
WATCHDOG_COOLDOWN="300"
TRANSPORT_TYPE="direct"
TRANSPORT_REMOTE_HOST=""
TRANSPORT_REMOTE_PORT=""
TRANSPORT_LOCAL_PORT=""
TRANSPORT_CONFIG=""
TRANSPORT_SSH_TARGET=""
TRANSPORT_SSH_IDENTITY=""
TRANSPORT_SSH_KNOWN_HOSTS=""
TRANSPORT_SSH_REMOTE_PORT=""
REMOTE_MODE=""
REMOTE_ALIAS=""
REMOTE_GATEWAY=""
REMOTE_CLIENT=""
REMOTE_OWNER_ID=""
REMOTE_EXIT_APP=""
REMOTE_PROFILE_GENERATION=""
REMOTE_SERVER_FINGERPRINT=""
```

The ordinary local/manual install default is `AUTOSTART="off"`. Simple
automatic-remote mode changes it to `on` after `install ... via --remote` and
starts/enables the environment after profile deployment.


Configuration files are root-owned and rejected when group/world writable.

### Adaptive data-path watchdog

`WATCHDOG_MODE="auto"` starts a lightweight systemd timer only while an
OpenVPN or WireGuard environment is running. It does not monitor inherit-only
children because their recovery belongs to the upstream environment.

Every 30 seconds the watchdog checks the real namespace data path. It arms only
after that environment has been online at least once, so it does not interfere
with a slow initial VPN connection. A single failed probe does nothing. After
`WATCHDOG_FAILURES` consecutive failures it restarts only
`nns-openvpn@<app>.service`; the network namespace and processes already
running inside it remain alive. `WATCHDOG_COOLDOWN` prevents restart loops.
When an app is chained through another nns-app environment, recovery is
deferred while that upstream is offline.

Use `WATCHDOG_MODE="off"` for profiles that must never be restarted
automatically. `nns-app status <app>` reports the timer, failure count, last
result, and watchdog-triggered restart attempts.

All known fields are reset before every load, preventing values from a
previously loaded application or gateway from leaking into another object.

After manually changing `UPSTREAM_APP`, refresh generated systemd dependencies:

```bash
sudo nns-app install <name>
```

## Profile policy

OpenVPN imports reject root-level directives that can execute scripts, load
plugins, include arbitrary files, or expose management interfaces. Managed
copies can add compatibility directives when `PROFILE_FIXUPS="on"`.

WireGuard imports accept full-tunnel IPv4 client profiles. These directives
are rejected:

```text
PreUp
PostUp
PreDown
PostDown
SaveConfig
```

Namespace DNS remains authoritative instead of being delegated to `wg-quick`.

## Snap applications

`ip netns exec` creates a private mount namespace for namespace-specific
resolver files. Snap launchers also require cgroup v2 and securityfs there.
`nns-app run` detects direct Snap aliases, the Snap launcher itself, and distro
transition wrappers such as a distribution-provided `/usr/bin/firefox` wrapper. It mounts those
filesystems inside the private command mount namespace before dropping to the
configured desktop user. Ordinary commands and non-Snap desktop applications
skip this extra mount preparation.

```bash
nns-app run my-private-app firefox --no-remote
```

The temporary mounts disappear with the command and do not alter the host
mount table.

## Upgrade

Install the current pre-built file:

```bash
sudo ./nns-app-install.sh install
```

The installer refreshes systemd templates and generated dependency drop-ins.
On Fedora it also installs the distribution-specific dependency names and
reconciles the dedicated firewalld zone and forwarding policy when firewalld is
running.

A gateway still running from 1.0.23 must be restarted once so the current
policy-rule and dedicated firewall-chain model replaces the legacy rules:

```bash
sudo nns-app gateway stop my-relay
sudo nns-app gateway start my-relay
```

The installer prints a warning when it detects a running gateway that requires
that migration restart.

## Troubleshooting

Application environment:

```bash
nns-app status my-private-app
sudo journalctl \
    -u nns-netns@my-private-app.service \
    -u nns-openvpn@my-private-app.service \
    -n 150 -o cat --no-pager
```

Managed gateway:

```bash
sudo nns-app gateway status my-relay
sudo journalctl \
    -u nns-gateway@my-relay.service \
    -n 150 -o cat --no-pager
```

Inspect namespace and WireGuard state:

```bash
sudo ip -n nns-my-private-app address
sudo ip -n nns-my-private-app route show table all
sudo ip netns exec nns-my-private-app wg show
```

Inspect a chained or gateway data path:

```bash
sudo ip rule show
sudo ip route show table all
sudo iptables-save
sudo ip netns exec nns-my-remote-exit iptables-save
```

## Known limitations

- IPv4 client data paths only.
- Ubuntu and Fedora with systemd are supported; other distributions require manual dependency and firewall validation.
- Managed gateways use an OpenVPN server backend only.
- Router port forwarding and host INPUT firewall changes are not automated.
- Client and server certificate renewal requires issuing a new client identity
  or recreating the gateway before certificate expiry.
- Direct OpenVPN gateway transport is not a full DPI-camouflage protocol.

## Contributing

Read `CONTRIBUTING.md` before changing networking, firewall, route ownership,
PKI, locking, or systemd lifecycle code. Run:

```bash
make test
```

before committing source or generated-installer changes.

## License

GPL-3.0-or-later. See `LICENSE`.
