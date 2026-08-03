# Contributing to nns-app

This document defines the implementation invariants that contributors must
preserve. The user-facing topology and commands are documented in `README.md`.

## Build and generated artifact

The maintained source is split into ordered modules under `src/`. `build.sh`
syntax-checks every module, concatenates them, validates the combined Bash
file, compiles all embedded Python heredocs, and writes
`nns-app-install.sh`.

The generated installer is committed as a release artifact. A source change is
complete only when the generated installer is rebuilt and `make test` remains
deterministic.

## Comment style

Comments should explain an invariant, safety requirement, compatibility
constraint, or non-obvious reason. Avoid comments that merely restate the next
command, depend on private deployment names, or describe obsolete release
history when a version-neutral compatibility statement is sufficient.

Use descriptive example names such as `my-private-app`, `my-upstream-vpn`,
`my-relay`, and `my-linux-client`. Do not introduce unexplained product,
location, host, or personal names into public help, comments, tests, or docs.

## Trust boundaries

- App, gateway, client, and remote configuration files are root-owned.
- Configuration files are sourced only after owner and mode validation.
- Every supported variable is reset before a file is sourced.
- Imported VPN profiles are untrusted input.
- OpenVPN directives capable of executing code, loading plug-ins, changing
  process confinement, or exposing management interfaces are rejected.
- WireGuard hook directives are rejected.
- Generated private keys use mode `0600` or `0640` as appropriate.
- `.nnslink` archives are untrusted input and must be allow-listed by member name and type before extraction.
- Remote SSH targets are structured data, never shell fragments; host keys remain pinned in a dedicated root-owned `known_hosts` file.

Adding a sourced field requires updating the corresponding reset and validation
function.

## Application data path

A direct app has a network namespace joined to the host by a veth pair. The
namespace has its own resolver and default route. Before the VPN is ready, the
kill switch permits only the selected VPN endpoint and required DNS traffic.
Protected traffic is accepted only through the app tunnel.

A chained app replaces the host-side uplink with a veth placed in an upstream
NNS namespace. Forwarding and NAT in the upstream namespace are restricted to
its active tunnel interface. A downstream app must never fall back to the
upstream namespace's ordinary host-facing veth.

An inherit-only app uses the same child veth topology but has no inner VPN
endpoint or tunnel. Its OUTPUT policy may use only its child veth, and the
upstream namespace remains responsible for tunnel-only forwarding and NAT.
Inherit mode must reject a host upstream, must report readiness through the
upstream data path, and must remain bound to `nns-online@<upstream>.service`.

`UPSTREAM_APP` forms a directed acyclic graph. Keep both configuration-time
cycle detection and defensive visited sets in lifecycle traversal.

## Managed gateway data path

The gateway control listener remains in the remote host namespace so the
encrypted client connection uses the host's normal public ingress and egress
route. In direct mode this is the OpenVPN listener. In stunnel or Cloak mode,
the public listener is the wrapper and OpenVPN must bind only to its allocated
loopback TCP port.

Transport configuration is regenerated from root-owned gateway/client state.
Cloak's allowed UID set must include active clients only. A wrapper and its
OpenVPN process are one lifecycle: failure of either must terminate the other
so systemd can restart a coherent pair.

Decrypted packets arriving on the server TUN are selected by an `ip rule` that
matches all of these owned attributes:

- gateway-specific priority;
- gateway TUN input interface;
- configured client pool;
- gateway-specific routing table.

The table contains only the managed transit-veth default and a lower-priority
blackhole default. Gateway code must never flush an entire numeric route table
or delete a policy rule by priority alone.

The host forwards gateway traffic only from the server TUN into the dedicated
transit veth. The selected upstream NNS namespace forwards and NATs that
traffic only through its active VPN tunnel. Dedicated tagged iptables chains
contain owned rules and terminal drops that prevent fallback.

## Resource ownership

Check every new network against:

- configured app namespace networks;
- configured gateway client and transit networks;
- live host addresses and routes;
- live network-namespace addresses and routes.

Check every new gateway route table and policy priority against existing
nns-app configs, live `ip rule` output, live table contents, and
`/etc/iproute2/rt_tables`.

Cleanup must remove only exact resources owned by the object being stopped.
Broad table flushes, priority-only rule deletion, and untagged shared firewall
rules are prohibited.

## Remote management and bundles

SSH is a management plane only. `remote connect`, `sync`, and `rotate` may
retrieve profiles over SSH, but a started local app must connect directly to
the gateway public endpoint without an SSH tunnel or live control session.

Remote commands must:

- use `BatchMode=yes` and a dedicated pinned `known_hosts` file;
- quote each nns-app argument as data before constructing the restricted remote command;
- require root or non-interactive `sudo -n` on the remote host;
- keep SSH credentials and identity paths out of exported VPN profiles;
- write imported profile and transport state into root-owned local storage.

`.nnslink` format changes require an explicit manifest version. Never extract
an archive with a broad tar command or accept arbitrary filenames, links,
devices, absolute paths, or parent traversal. Plain `.ovpn` export is valid
only for direct gateways because wrappers require additional state.

## Locking

Administrative mutations use `flock` files under `/run/lock/nns-app`.

Lock order:

1. `global`
2. `gateway-<name>` or another object-specific lock

Locks are reference-counted within one process. Do not hold a per-gateway lock
while calling `systemctl stop nns-gateway@...`: the unit's `ExecStopPost`
helper runs in another process and must acquire the same lock.

Read-only client export/list and gateway status use a shared gateway lock. PKI
database updates use an exclusive gateway lock and a filesystem snapshot that
is restored on failure.

## systemd lifecycle

- `nns-netns@.service` owns an app namespace.
- `nns-openvpn@.service` is the compatibility name for the backend-neutral VPN
  process unit.
- `nns-online@.service` represents a verified app data path.
- `nns-watchdog@.timer` probes only running OpenVPN/WireGuard environments.
  Recovery must arm only after a verified online state, require consecutive
  failures, defer to an offline upstream, honor cooldown, and restart only the
  backend unit so application processes keep their network namespace.
- Per-instance drop-ins order chained apps and gateways after the upstream
  online unit and bind their lifecycle to it.
- `nns-gateway@.service` owns the managed OpenVPN server and gateway data path.
- `nns-gateway-crl-refresh@.timer` renews gateway CRLs weekly.

Keep the distinction between a running process, a created tunnel, and a
verified online data path visible in status and unit dependencies.

## PKI transactions

Gateway creation is staged in a temporary directory and renamed only after the
CA, server certificate, TLS Crypt v2 key, CRL, and server configuration pass
validation.

Client issuance and revocation snapshot the OpenSSL CA database. A failure
before commit restores that snapshot. CRLs are written through a temporary file
and atomically installed.

Each client machine receives a unique certificate, private key, and TLS Crypt
v2 key. Do not encourage reusing exported client profiles between machines.

## Tests

Run `make test` as an unprivileged user. Source-level function tests set
`NNS_APP_SOURCE_ONLY=1` and redirect locks with `NNS_APP_LOCK_DIR` to a private
temporary directory. Production execution ignores that override and always
uses `/run/lock/nns-app` with root ownership checks.


`make test` runs:

- module and combined Bash syntax checks;
- embedded Python compilation;
- deterministic-build verification;
- checks for previously dangerous routing patterns;
- network allocator helper tests;
- OpenVPN status-version-3 parsing;
- CA database snapshot and restore tests;
- public example-name checks.

Live namespace, firewall, OpenVPN, WireGuard, and gateway integration should be
tested on an Ubuntu host before release deployment.
