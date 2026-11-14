#!/bin/bash
# nns-app -- macOS WireGuard/OpenVPN client (IPv4, opt-in per-process routing).
# Unlike the Linux backend: no netns, PF, user/group changes or host DNS edits.
# The only kernel networking additions are one utun and its -ifscope route.
set -euo pipefail
umask 077
PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:/opt/homebrew/bin:/usr/local/bin"
export PATH
SELF=$0
# Repo-root VERSION is the source of truth. build.sh substitutes the
# @@NNS_VERSION@@ token when embedding this script. An unsubstituted value
# still contains "@", which triggers the source-tree file lookup.
VERSION="@@NNS_VERSION@@"
if [[ "$VERSION" == *@* ]]; then
  _nns_dir=$(cd "$(dirname "$SELF")" && pwd -P)
  if [ -f "$_nns_dir/../VERSION" ]; then
    VERSION=$(tr -d '[:space:]\r' < "$_nns_dir/../VERSION")
  elif [ -f "$_nns_dir/VERSION" ]; then
    VERSION=$(tr -d '[:space:]\r' < "$_nns_dir/VERSION")
  else
    printf 'ERROR: VERSION file missing (expected at repo root next to macos/).\n' >&2
    exit 1
  fi
  unset -v _nns_dir
fi
STATE_BASE=/var/run/nns-app-macos
LIBEXEC=/usr/local/libexec/nns-app
MYLOC_URL="http://ip-api.com/json/?fields=status,message,query,country,countryCode,regionName,city,zip,lat,lon,timezone,isp,org,as"
if [ ! -x "$LIBEXEC/nns-run" ] && [ -x "$(dirname "$SELF")/bin/nns-run" ]; then
  LIBEXEC=$(cd "$(dirname "$SELF")/bin" && pwd -P)
fi
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
valid_name() {
  case "${1:-}" in ''|*[!a-zA-Z0-9_-]*) fail "Invalid app name '$1' (letters, digits, _ and - only).";; esac
  [ "${#1}" -le 32 ] || fail 'App name too long (max 32).'
}
valid_ipv4() {
  printf '%s\n' "$1" | awk -F. 'NF != 4 {exit 1} {for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || length($i)>3 || $i>255) exit 1; exit 0}'
}
is_darwin() { [ "$(uname -s)" = Darwin ]; }
default_if() { route -n get -inet default 2>/dev/null | awk '$1=="interface:"{print $2;exit}'; }
owner_init() {
  OWNER=${SUDO_USER:-$(id -un)}
  [ "$OWNER" != root ] || fail 'Launch as a regular macOS user (sudo only for start/stop/recover).'
  UID_NUM=$(id -u "$OWNER") || fail 'Cannot determine owner UID.'
  HOME_DIR=$(dscl . -read "/Users/$OWNER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  [ -n "$HOME_DIR" ] || fail "Cannot discover home directory for $OWNER."
  APP_BASE="$HOME_DIR/Library/Application Support/nns-app/apps"
  USER_RUNTIME="$STATE_BASE/$UID_NUM"
}
app_paths() {
  valid_name "$1"
  APP=$1
  CFG_DIR="$APP_BASE/$APP"
  RUNSTATE="$USER_RUNTIME/$APP"
  TYPE_FILE="$CFG_DIR/type"
  if [ -f "$TYPE_FILE" ]; then
    APP_TYPE=$(cat "$TYPE_FILE")
  else
    APP_TYPE=wireguard
  fi
  case "$APP_TYPE" in
    openvpn) CONF="$CFG_DIR/profile.ovpn" ;;
    wireguard|*) APP_TYPE=wireguard; CONF="$CFG_DIR/profile.conf" ;;
  esac
}
require_profile() {
  [ -f "$CONF" ] || fail "Profile not installed for '$APP'; use nns-app add $APP <profile.conf|.ovpn>."
}
app_type_label() {
  case "${1:-$APP_TYPE}" in
    openvpn) printf 'vpn-client/ovpn' ;;
    *) printf 'vpn-client/wg' ;;
  esac
}
detect_profile_kind() {
  # Classify an incoming profile path as wireguard or openvpn.
  local path=$1
  case "$path" in
    *.ovpn) printf 'openvpn'; return ;;
    *.conf)
      if grep -Eq '^[[:space:]]*\[Interface\]' "$path" &&
         grep -Eiq '^[[:space:]]*PrivateKey[[:space:]]*=' "$path"; then
        printf 'wireguard'; return
      fi
      if grep -Eiq '^[[:space:]]*remote[[:space:]]+' "$path"; then
        printf 'openvpn'; return
      fi
      ;;
  esac
  fail 'Unrecognized profile; use a WireGuard .conf or OpenVPN .ovpn file.'
}
require_admin() {
  [ "$(id -u)" -eq 0 ] || fail 'Use sudo nns-app start|stop|recover <app>. Other commands run without sudo.'
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || fail 'Use sudo from the app owner account.'
}
read_runtime() {
  [ -f "$RUNSTATE/ready" ] || fail "App '$APP' not running (use sudo nns-app start $APP)."
  [ "$(cat "$RUNSTATE/owner_uid")" = "$UID_NUM" ] || fail 'Incorrect runtime ownership.'
  UTUN=$(cat "$RUNSTATE/utun")
  VPN_IP=$(cat "$RUNSTATE/vpn_ip")
  PHY=$(cat "$RUNSTATE/phy")
  case "$UTUN" in utun[0-9]*) ;; *) fail 'Corrupt utun state.';; esac
  valid_ipv4 "$VPN_IP" || fail 'Corrupt tunnel IPv4.'
}
check_iface() { ifconfig "$UTUN" >/dev/null 2>&1; }
profile_value() {
  # Read the first key in [Interface]. No evaluation, interpolation or hooks.
  [ -f "$CONF" ] || return 0
  awk -F= -v wanted="$1" '
    /^\[/ {section=tolower($0);gsub(/[ \t]/,"",section)}
    section=="[interface]" && index($0,"=")>0 {
      key=tolower($1);gsub(/[ \t]/,"",key)
      if (key==wanted) {val=substr($0,index($0,"=")+1);sub(/^[ \t]*/,"",val);sub(/[ \t]*$/, "", val);print val;exit}
    }' "$CONF"
}
reject_hooks() {
  # Stored profiles must already have hooks stripped at import time.
  if grep -Eiq '^[[:space:]]*(preup|postup|predown|postdown)[[:space:]]*=' "$CONF"; then
    fail 'WireGuard shell hooks remain in the profile; re-run nns-app add after fixing the conf.'
  fi
}

# Like Linux: accept only the declarative resolvectl DNS trio, never execute
# hooks, strip them from the stored profile, and return the first DNS IPv4.
normalize_wg_profile() {
  local conf=$1
  command -v python3 >/dev/null 2>&1 || fail 'python3 is required to import WireGuard profiles.'
  python3 - "$conf" <<'PY'
import ipaddress, pathlib, re, shlex, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
has_dns_eq = bool(re.search(r"(?im)^\s*DNS\s*=", text))
hook_dns, hook_domains, hook_revert = [], [], 0
kept = []

def fail(msg):
    raise SystemExit(msg)

for raw in text.splitlines(keepends=True):
    line = raw.rstrip("\r\n")
    if not line.strip() or line.lstrip().startswith("#"):
        kept.append(raw if raw.endswith("\n") else raw + "\n")
        continue
    if "=" not in line:
        kept.append(line + "\n")
        continue
    key, value = line.split("=", 1)
    key_l = key.strip().lower()
    value = value.strip()
    if key_l in {"preup", "predown", "saveconfig"}:
        fail(f"{key.strip()} hooks are not supported on macOS.")
    if key_l not in {"postup", "postdown"}:
        kept.append(line + "\n")
        continue
    try:
        args = shlex.split(value, posix=True)
    except ValueError:
        fail(f"malformed {key.strip()} quoting")
    if key_l == "postdown":
        if args != ["resolvectl", "revert", "%i"] or hook_revert:
            fail("only one 'PostDown = resolvectl revert %i' is permitted")
        hook_revert = 1
        continue
    if len(args) < 4 or args[0] != "resolvectl" or args[2] != "%i":
        fail("only resolvectl dns/domain %i DNS settings are permitted in PostUp")
    if args[1] == "dns" and not hook_dns:
        for item in args[3:]:
            try:
                address = ipaddress.ip_address(item)
            except ValueError:
                fail("PostUp DNS requires literal IPv4 addresses")
            if address.version != 4 or address.is_unspecified or address.is_multicast:
                fail("PostUp DNS requires usable IPv4 addresses")
            hook_dns.append(str(address))
        continue
    if args[1] == "domain" and not hook_domains:
        for item in args[3:]:
            if not item.startswith("~"):
                fail("PostUp domain must be route-only (~domain)")
            domain = item[1:].lower().rstrip(".")
            labels = domain.split(".")
            if (len(domain) > 253 or not labels or any(
                len(label) > 63 or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", label)
                for label in labels
            )):
                fail("invalid route-only DNS domain")
            hook_domains.append(domain)
        continue
    fail("duplicate or unsupported PostUp DNS hook")

if hook_dns or hook_domains or hook_revert:
    if not (hook_dns and hook_domains and hook_revert == 1):
        fail("resolvectl hooks require PostUp dns, PostUp domain and PostDown revert")
    if has_dns_eq:
        fail("Do not mix DNS = with resolvectl DNS hooks; specify DNS policy once")

path.write_text("".join(kept), encoding="utf-8")
if hook_dns:
    print(hook_dns[0])
PY
}

# Validate OpenVPN client profiles (Linux validate_ovpn intent) and extract
# the first dhcp-option DNS IPv4. Hooks/scripts are never executed.
normalize_ovpn_profile() {
  local conf=$1
  command -v python3 >/dev/null 2>&1 || fail 'python3 is required to import OpenVPN profiles.'
  python3 - "$conf" <<'PY'
import ipaddress, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if not text.strip():
    raise SystemExit("Profile is empty.")
if path.stat().st_size > 5 * 1024 * 1024:
    raise SystemExit("Profile is unexpectedly large (>5 MiB).")

unsafe = re.compile(
    r"^(up|down|route-up|route-pre-down|ipchange|learn-address|"
    r"client-connect|client-disconnect|auth-user-pass-verify|tls-verify|"
    r"tls-crypt-v2-verify|plugin|script-security|iproute|config|daemon|"
    r"writepid|chroot|cd|user|group|log|log-append|status|status-version|"
    r"pkcs11-providers|pkcs11-id|cryptoapicert|engine|management)$"
)
external_cred = re.compile(
    r"^(ca|cert|key|pkcs12|tls-auth|tls-crypt|tls-crypt-v2|crl-verify|"
    r"askpass|auth-user-pass)$"
)
# Client directives we keep. Unknown first tokens (export notes, WARNING prose)
# are commented out so OpenVPN does not treat "Remote host firewall..." as remote.
known = {
    "client", "dev", "dev-type", "proto", "remote", "remote-random",
    "remote-random-hostname", "remote-cert-tls", "nobind", "bind",
    "persist-key", "persist-tun", "persist-remote-ip", "persist-local-ip",
    "resolv-retry", "connect-retry", "connect-retry-max", "connect-timeout",
    "explicit-exit-notify", "float", "keepalive", "ping", "ping-exit",
    "ping-restart", "reneg-sec", "hand-window", "tran-window",
    "verify-x509-name", "ns-cert-type", "remote-cert-ku", "remote-cert-eku",
    "tls-client", "tls-version-min", "tls-version-max", "tls-cipher",
    "tls-ciphersuites", "tls-cert-profile", "key-direction",
    "cipher", "data-ciphers", "data-ciphers-fallback", "auth", "auth-nocache",
    "comp-lzo", "compress", "allow-compression", "tun-mtu", "tun-mtu-extra",
    "link-mtu", "mssfix", "sndbuf", "rcvbuf", "txqueuelen", "mtu-disc",
    "dhcp-option", "redirect-gateway", "route", "route-delay", "route-metric",
    "route-nopull", "route-noexec", "pull", "pull-filter", "ifconfig",
    "ifconfig-nowarn", "topology", "verb", "mute", "mute-replay-warnings",
    "replay-window", "nice", "fast-io", "machine-readable-output",
    "setenv", "setenv-safe", "ignore-unknown-option", "disable-dco",
    "providers", "provider", "verify-hash", "peer-fingerprint",
    "tls-crypt", "tls-crypt-v2", "tls-auth", "secret",
}
host_re = re.compile(r"^[A-Za-z0-9._:-]+$")
has_remote = False
dns = []
inblock = False
kept = []

def comment(line):
    return ("# " + line + "\n") if not line.lstrip().startswith(("#", ";")) else (line + "\n")

for raw in text.splitlines(keepends=True):
    line = raw.rstrip("\r\n")
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith(";"):
        kept.append(line + "\n")
        continue
    if re.match(r"^<[^/][^>]*>$", stripped):
        inblock = True
        kept.append(line + "\n")
        continue
    if re.match(r"^</[A-Za-z0-9_-]+>$", stripped):
        inblock = False
        kept.append(line + "\n")
        continue
    if inblock:
        kept.append(line + "\n")
        continue
    if stripped.lower() == "<connection>" or stripped.lower().startswith("<connection "):
        raise SystemExit("Profiles with <connection> blocks are not supported.")
    parts = stripped.split()
    key = parts[0].lower()
    if unsafe.match(key) or key.startswith("management"):
        raise SystemExit(f"unsupported or unsafe directive: {stripped}")
    if key == "dev" and len(parts) > 1 and parts[1].lower().startswith("tap"):
        raise SystemExit(f"TAP profiles are unsupported: {stripped}")
    if key == "dev-type" and len(parts) > 1 and parts[1].lower() == "tap":
        raise SystemExit(f"TAP profiles are unsupported: {stripped}")
    if external_cred.match(key):
        if len(parts) < 2 or parts[1] != "[inline]":
            raise SystemExit(
                "Use a self-contained .ovpn profile with inline keys/certificates "
                "and no interactive password prompt."
            )
    # Prose notes often start with Remote/WARNING and break OpenVPN parsing.
    if key == "remote":
        if not (2 <= len(parts) <= 4 and host_re.match(parts[1])):
            kept.append(comment(line))
            continue
        if len(parts) >= 3 and not parts[2].isdigit():
            kept.append(comment(line))
            continue
        has_remote = True
    elif key not in known:
        kept.append(comment(line))
        continue
    # OpenVPN 2.7+ ignores --persist-key and prints a DEPRECATED warning to the
    # controlling terminal before daemonizing; drop it so start stays quiet.
    if key == "persist-key":
        kept.append(comment(line))
        continue
    if key == "dhcp-option" and len(parts) >= 3 and parts[1].lower() == "dns":
        try:
            address = ipaddress.ip_address(parts[2])
        except ValueError as exc:
            raise SystemExit(f"invalid dhcp-option DNS: {parts[2]}") from exc
        if address.version == 4 and not address.is_unspecified and not address.is_multicast:
            dns.append(str(address))
    kept.append(line + "\n")

if not has_remote:
    raise SystemExit("Profile has no 'remote' directive.")
path.write_text("".join(kept), encoding="utf-8")
if dns:
    print(dns[0])
PY
}
profile_ip() {
  local val part
  val=$(profile_value address)
  part=$(printf '%s' "$val" | awk -F, '{for(i=1;i<=NF;i++){gsub(/[ \t]/,"",$i);if ($i ~ /^[0-9.]+\/[0-9]+$/){print $i;exit}}}')
  VPN_IP=${part%%/*}
  valid_ipv4 "$VPN_IP" || fail 'WireGuard [Interface] Address= must contain an IPv4 CIDR.'
}
profile_dns() {
  local raw ip
  raw=$(profile_value dns)
  ip=$(printf '%s\n' "$raw" | awk -F, '{for(i=1;i<=NF;i++){gsub(/[ \t]/,"",$i);if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i;exit}}}')
  if [ -n "$ip" ]; then valid_ipv4 "$ip" || fail 'Invalid DNS IPv4 in profile.'; fi
  printf '%s\n' "$ip"
}
selected_dns() {
  if [ -f "$CFG_DIR/dns_ipv4" ]; then
    cat "$CFG_DIR/dns_ipv4"
  elif [ "$APP_TYPE" = wireguard ] && [ -f "$CONF" ]; then
    profile_dns
  fi
}
ensure_binaries() {
  [ -x "$LIBEXEC/nns-run" ] && [ -r "$LIBEXEC/libnnsbind.dylib" ] ||
    fail 'C tools missing; run ./build.sh && sudo ./install_macos.'
}
# Strictly delete the route we created, not routes owned by another service.
remove_scoped_route() {
  if [ -s "$RUNSTATE/scoped_lan" ]; then
    local ifname cidr
    while read -r ifname cidr; do
      case "$ifname" in utun[0-9]*) ;; *) continue ;; esac
      [ -n "${cidr:-}" ] || continue
      route -q -n delete -ifscope "$ifname" -net "$cidr" >/dev/null 2>&1 || true
    done < "$RUNSTATE/scoped_lan"
    rm -f "$RUNSTATE/scoped_lan"
  fi
  if [ -s "$RUNSTATE/scoped_route" ]; then
    local ifname
    ifname=$(cat "$RUNSTATE/scoped_route")
    case "$ifname" in utun[0-9]*) ;; *) fail 'Corrupt owned route marker.';; esac
    if route -q -n delete -ifscope "$ifname" -inet default -interface "$ifname" >/dev/null 2>&1; then
      rm -f "$RUNSTATE/scoped_route"
    else
      # If the engine died, macOS may have removed the scoped route already.
      if ! route -n get -ifscope "$ifname" 192.0.2.1 2>/dev/null |
           grep -q "interface: $ifname"; then
        rm -f "$RUNSTATE/scoped_route"
      else
        fail "Scoped route still exists on $ifname; retaining state for recovery."
      fi
    fi
  fi
}
list_utuns() {
  ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^utun[0-9]+$' || true
}
utun_ipv4() {
  ifconfig "$1" 2>/dev/null | awk '/inet / { print $2; exit }'
}
openvpn_bin() {
  local candidate
  for candidate in \
    /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn \
    /opt/homebrew/bin/openvpn /usr/local/bin/openvpn; do
    if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  command -v openvpn 2>/dev/null || return 1
}
cleanup_state() {
  # Must remove the scoped route before tearing down the tunnel descriptor.
  remove_scoped_route
  if [ -s "$RUNSTATE/wg_pid" ]; then
    local pid
    pid=$(cat "$RUNSTATE/wg_pid")
    case "$pid" in ''|*[!0-9]*) fail 'Invalid WireGuard engine PID.';; esac
    if ps -p "$pid" -o command= 2>/dev/null | grep -E -q 'wireguard-go.*-f[[:space:]]+utun'; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  if [ -s "$RUNSTATE/ovpn_pid" ]; then
    local pid
    pid=$(cat "$RUNSTATE/ovpn_pid")
    case "$pid" in ''|*[!0-9]*) fail 'Invalid OpenVPN engine PID.';; esac
    if ps -p "$pid" -o command= 2>/dev/null | grep -Eqi 'openvpn'; then
      kill "$pid" 2>/dev/null || true
      # Give OpenVPN a moment to release utun before removing state.
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf -- "$RUNSTATE"
}
prepare_runtime() {
  local default_before=$1
  mkdir -p "$USER_RUNTIME"; chmod 755 "$STATE_BASE" "$USER_RUNTIME"
  mkdir "$RUNSTATE"; chmod 755 "$RUNSTATE"
  printf '%s\n' "$UID_NUM" > "$RUNSTATE/owner_uid"
  printf '%s\n' "$default_before" > "$RUNSTATE/phy"
  printf '%s\n' "$APP_TYPE" > "$RUNSTATE/backend"
  chmod 644 "$RUNSTATE/owner_uid" "$RUNSTATE/phy" "$RUNSTATE/backend"
}
finish_scoped_start() {
  local default_before=$1
  case "$UTUN" in utun[0-9]*) ;; *) fail 'Tunnel interface discovery failed.';; esac
  valid_ipv4 "$VPN_IP" || fail 'Tunnel IPv4 discovery failed.'
  printf '%s\n' "$UTUN" > "$RUNSTATE/utun"
  printf '%s\n' "$VPN_IP" > "$RUNSTATE/vpn_ip"
  chmod 644 "$RUNSTATE/utun" "$RUNSTATE/vpn_ip"
  route -q -n add -ifscope "$UTUN" -inet default -interface "$UTUN" ||
    fail 'Unable to install interface-scoped route.'
  printf '%s\n' "$UTUN" > "$RUNSTATE/scoped_route"; chmod 644 "$RUNSTATE/scoped_route"
  [ "$(default_if)" = "$default_before" ] || fail 'Host default interface changed; aborting.'
  touch "$RUNSTATE/ready"; chmod 644 "$RUNSTATE/ready"
}
start_wireguard() {
  local default_before=$1 pid it ready=0
  command -v wireguard-go >/dev/null 2>&1 || fail 'Missing wireguard-go (brew install wireguard-go wireguard-tools).'
  command -v wg >/dev/null 2>&1 || fail 'Missing wg (brew install wireguard-tools).'
  command -v wg-quick >/dev/null 2>&1 || fail 'Missing wg-quick (brew install wireguard-tools).'
  reject_hooks
  profile_ip
  if ifconfig -a | awk -v ip="$VPN_IP" '$1=="inet" && $2==ip {found=1} END {exit !found}'; then
    fail "VPN address $VPN_IP is already assigned on this Mac; refusing to interfere with an existing tunnel."
  fi
  local other
  for other in "$USER_RUNTIME"/*; do
    [ -f "$other/ready" ] || continue
    if [ "$(cat "$other/vpn_ip")" = "$VPN_IP" ]; then
      fail "VPN address $VPN_IP is already used by another managed tunnel."
    fi
  done
  prepare_runtime "$default_before"
  printf '%s\n' "$VPN_IP" > "$RUNSTATE/vpn_ip"; chmod 644 "$RUNSTATE/vpn_ip"
  WG_TUN_NAME_FILE="$RUNSTATE/new_utun" wireguard-go -f utun </dev/null >"$RUNSTATE/wg.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$RUNSTATE/wg_pid"
  UTUN=''
  for it in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [ -s "$RUNSTATE/new_utun" ]; then UTUN=$(cat "$RUNSTATE/new_utun"); break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  case "$UTUN" in utun[0-9]*) ;; *) tail -25 "$RUNSTATE/wg.log" >&2; fail 'WireGuard failed to allocate utun.';; esac
  for it in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if wg show "$UTUN" >/dev/null 2>&1; then ready=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  [ "$ready" = 1 ] || fail 'WireGuard control socket failed to become ready.'
  wg-quick strip "$CONF" | wg setconf "$UTUN" /dev/stdin || fail 'WireGuard profile configuration failed.'
  ifconfig "$UTUN" inet "$VPN_IP/32" "$VPN_IP" alias || fail 'Cannot assign tunnel IP.'
  ifconfig "$UTUN" mtu 1420 up || fail 'Cannot enable utun.'
  finish_scoped_start "$default_before"
  info "Started $APP (wireguard): $UTUN ($VPN_IP), host default $default_before unchanged."
}
# Best-effort TCP probe of the first remote= in an .ovpn (used before start).
ovpn_tcp_remote() {
  awk 'BEGIN{IGNORECASE=1}
    /^proto[[:space:]]+/ {
      p=tolower($2); if (p ~ /^udp/) udp=1
    }
    /^remote[[:space:]]+/ && host=="" {
      host=$2; port=$3; if (port=="" || port !~ /^[0-9]+$/) port=1194
    }
    END {
      if (host=="" || udp) exit 1
      print host, port
    }' "$1"
}
# OpenVPN "topology subnet" assigns a prefix (e.g. /24) and installs a host-wide
# connected route, so peers are reachable from every process. Narrow to /32,
# drop the global prefix route, and re-add it -ifscope so only IP_BOUND_IF /
# nns-app run traffic can reach the VPN LAN (same model as the scoped default).
confine_openvpn_utun() {
  local utun=$1 ip=$2 net gw mask cidr
  : >"$RUNSTATE/scoped_lan"
  chmod 644 "$RUNSTATE/scoped_lan"
  ifconfig "$utun" inet "$ip" "$ip" netmask 255.255.255.255 up ||
    fail "Cannot narrow $utun to /32 (VPN peers would stay host-reachable)."
  if [ -f "$RUNSTATE/ovpn.log" ]; then
    # Log lines are timestamp-prefixed; locate "-net" rather than using fixed fields.
    awk '/\/sbin\/route add -net / {
      for (i = 1; i <= NF; i++)
        if ($i == "-net" && i + 3 <= NF) { print $(i+1), $(i+2), $(i+3); break }
    }' "$RUNSTATE/ovpn.log" >"$RUNSTATE/ovpn-nets"
    while read -r net gw mask; do
      [ -n "${net:-}" ] && [ -n "${mask:-}" ] || continue
      route -n delete -net "$net" "$gw" "$mask" >/dev/null 2>&1 || true
      route -n delete -net "$net" -netmask "$mask" >/dev/null 2>&1 || true
      cidr=$(NETWORK="$net" MASK="$mask" python3 - <<'PY'
import ipaddress, os
print(ipaddress.IPv4Network((os.environ["NETWORK"], os.environ["MASK"]), strict=False))
PY
) || continue
      route -n add -ifscope "$utun" -net "$cidr" -interface "$utun" >/dev/null 2>&1 ||
        fail "Unable to install interface-scoped VPN LAN route $cidr on $utun."
      printf '%s %s\n' "$utun" "$cidr" >>"$RUNSTATE/scoped_lan"
    done <"$RUNSTATE/ovpn-nets"
    rm -f "$RUNSTATE/ovpn-nets"
  fi
  # Drop any remaining unscoped non-default routes via this utun (keep ifscoped).
  netstat -rn -f inet | awk -v u="$utun" -v ip="$ip" '
    $NF != u { next }
    $3 ~ /I/ { next }  # IFSCOPE
    $1 == "default" { next }
    $1 == ip { next }
    {
      d = $1
      if (d ~ /\//) {
        split(d, a, "/")
        n = split(a[1], o, ".")
        while (n < 4) { n++; o[n] = 0 }
        printf "%d.%d.%d.%d/%s\n", o[1], o[2], o[3], o[4], a[2]
      } else if (d ~ /^[0-9.]+$/) {
        print d
      }
    }' >"$RUNSTATE/ovpn-stale-routes"
  while read -r net; do
    [ -n "${net:-}" ] || continue
    route -n delete -net "$net" >/dev/null 2>&1 || true
  done <"$RUNSTATE/ovpn-stale-routes"
  rm -f "$RUNSTATE/ovpn-stale-routes"
}
start_openvpn() {
  local default_before=$1 pid it before after cand ip ovpn runtime_conf err
  local remote_host remote_port probe
  ovpn=$(openvpn_bin) || fail 'Missing openvpn (brew install openvpn).'
  before=$(list_utuns | tr '\n' ' ')
  prepare_runtime "$default_before"
  # Re-sanitize into runtime copy so export notes / prose cannot break OpenVPN.
  runtime_conf="$RUNSTATE/profile.ovpn"
  cp -- "$CONF" "$runtime_conf"
  chmod 600 "$runtime_conf"
  if ! normalize_ovpn_profile "$runtime_conf" >/dev/null 2>"$RUNSTATE/ovpn-sanitize.err"; then
    err=$(cat "$RUNSTATE/ovpn-sanitize.err" 2>/dev/null || true)
    fail "${err:-OpenVPN profile failed sanitization before start.}"
  fi
  # Fail fast when the TCP peer is unreachable (common with a full-tunnel host VPN).
  if probe=$(ovpn_tcp_remote "$runtime_conf"); then
    remote_host=${probe%% *}
    remote_port=${probe##* }
    if ! nc -z -G 3 "$remote_host" "$remote_port" >/dev/null 2>&1; then
      fail "Cannot reach OpenVPN peer ${remote_host}:${remote_port} via $(default_if). Disconnect any full-tunnel VPN and confirm the endpoint is listening."
    fi
  fi
  # Background ourselves (not --daemon) so stderr cannot attach to the TTY and so
  # connect-retry-max makes a dead peer exit instead of soft-restarting forever.
  : >"$RUNSTATE/ovpn.log"
  "$ovpn" \
    --config "$runtime_conf" \
    --dev-type tun \
    --route-noexec \
    --pull-filter ignore redirect-gateway \
    --pull-filter ignore route \
    --pull-filter ignore route-ipv6 \
    --script-security 1 \
    --verb 3 \
    --connect-timeout 10 \
    --connect-retry 2 \
    --connect-retry-max 3 \
    --setenv NNS_APP_MARK "nns-app:$APP" \
    </dev/null >>"$RUNSTATE/ovpn.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$RUNSTATE/ovpn_pid"
  chmod 644 "$RUNSTATE/ovpn_pid"
  UTUN=''
  VPN_IP=''
  for it in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      tail -40 "$RUNSTATE/ovpn.log" 2>/dev/null >&2 || true
      fail 'OpenVPN exited before the tunnel became ready.'
    fi
    if grep -Eq 'Options error:|Exiting due to fatal error|AUTH_FAILED|AUTHENTICATE_FAILED' \
         "$RUNSTATE/ovpn.log" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      tail -40 "$RUNSTATE/ovpn.log" 2>/dev/null >&2 || true
      fail 'OpenVPN rejected the profile or authentication.'
    fi
    after=$(list_utuns)
    for cand in $after; do
      case " $before " in *" $cand "*) continue ;; esac
      ip=$(utun_ipv4 "$cand")
      if [ -n "$ip" ] && valid_ipv4 "$ip"; then
        UTUN=$cand
        VPN_IP=$ip
        break
      fi
    done
    [ -n "$UTUN" ] && break
    if [ $((it % 5)) -eq 0 ]; then
      info "Waiting for OpenVPN tunnel ($it/40)…"
    fi
    sleep 1
  done
  [ -n "$UTUN" ] && [ -n "$VPN_IP" ] || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    tail -40 "$RUNSTATE/ovpn.log" 2>/dev/null >&2 || true
    fail 'OpenVPN started but no new utun IPv4 address appeared (peer unreachable, auth, or push timeout).'
  }
  if ifconfig -a | awk -v ip="$VPN_IP" -v utun="$UTUN" '
    $1 ~ /^utun[0-9]+:/ { iface=$1; sub(":", "", iface) }
    $1=="inet" && $2==ip && iface != utun { found=1 }
    END { exit !found }'; then
    fail "VPN address $VPN_IP is already assigned on another interface."
  fi
  confine_openvpn_utun "$UTUN" "$VPN_IP"
  finish_scoped_start "$default_before"
  info "Started $APP (openvpn): $UTUN ($VPN_IP), host default $default_before unchanged."
}
start_app() {
  require_admin
  require_profile
  [ ! -e "$RUNSTATE" ] || fail "Runtime state exists for '$APP'; use status, stop or recover."
  ensure_binaries
  local default_before rollback=1
  default_before=$(default_if)
  [ -n "$default_before" ] || fail 'No physical default route detected.'
  case "$default_before" in utun*) fail 'Host default is a VPN; disconnect full-tunnel VPN before starting nns-app.';; esac
  trap 'if [ "${rollback:-0}" -eq 1 ]; then echo "Rolling back incomplete tunnel setup" >&2; cleanup_state || true; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "$APP_TYPE" in
    openvpn) start_openvpn "$default_before" ;;
    *) start_wireguard "$default_before" ;;
  esac
  rollback=0
  trap - EXIT INT TERM
  info "Private DNS: $(selected_dns || true) (empty means no hostname lookup in compatible injected applications)."
}
stop_app() {
  require_admin
  [ -d "$RUNSTATE" ] || fail "No runtime state for '$APP'."
  cleanup_state
  info "Stopped $APP; removed only its scoped route and tunnel engine."
}
run_app() {
  [ "$(id -u)" -ne 0 ] || fail 'Run apps without sudo: nns-app run <app> command.'
  read_runtime
  check_iface || fail "Managed interface $UTUN is absent."
  ensure_binaries
  [ "$#" -gt 0 ] || fail 'Usage: nns-app run app [--] command [args...]'
  [ "$1" != -- ] || shift
  [ "$#" -gt 0 ] || fail 'Missing command.'
  local dns
  dns=$(selected_dns)
  if [ -n "$dns" ]; then valid_ipv4 "$dns" || fail 'Configured DNS server is invalid.'; fi
  export NNS_DNS_IPV4="$dns"
  exec "$LIBEXEC/nns-run" --vpn-ip "$VPN_IP" --vpn-if "$UTUN" --lib "$LIBEXEC/libnnsbind.dylib" -- "$@"
}
# Prefer Homebrew curl because Apple's /usr/bin/curl is SIP-protected.
homebrew_curl() {
  local c
  if [ -n "${NNS_MAC_TEST_CURL:-}" ] && [ -x "$NNS_MAC_TEST_CURL" ]; then
    printf '%s\n' "$NNS_MAC_TEST_CURL"
    return 0
  fi
  for c in /opt/homebrew/opt/curl/bin/curl /usr/local/opt/curl/bin/curl; do
    if [ -x "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# Like run_app, but keeps the shell so command output can be captured.
run_app_output() {
  [ "$(id -u)" -ne 0 ] || fail 'Run apps without sudo: nns-app run <app> command.'
  read_runtime
  check_iface || fail "Managed interface $UTUN is absent."
  ensure_binaries
  [ "$#" -gt 0 ] || fail 'Missing command.'
  local dns
  dns=$(selected_dns)
  if [ -n "$dns" ]; then valid_ipv4 "$dns" || fail 'Configured DNS server is invalid.'; fi
  NNS_DNS_IPV4="$dns" "$LIBEXEC/nns-run" --vpn-ip "$VPN_IP" --vpn-if "$UTUN" \
    --lib "$LIBEXEC/libnnsbind.dylib" -- "$@"
}

# Resolve the fixed public probe hostname on the host, then pass the numeric
# address to curl with --resolve. App-scoped probes must not depend on the
# selected VPN's private resolver being reachable: mlcloud, for example, has
# a private DNS address that is not routed through its 10.253/24 split tunnel.
resolve_host_ipv4() {
  python3 - "$1" <<'PY_RESOLVE'
import socket
import sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None, socket.AF_INET, socket.SOCK_STREAM)
except OSError:
    sys.exit(1)
for info in infos:
    print(info[4][0])
    break
else:
    sys.exit(1)
PY_RESOLVE
}

myloc_format() {
  local format=$1 context=$2
  python3 -c '
import json
import sys
try:
    data = json.load(sys.stdin)
except (ValueError, UnicodeError):
    sys.exit("ERROR: Invalid geolocation response.")
if not isinstance(data, dict):
    sys.exit("ERROR: Invalid geolocation response type.")
if data.get("status") != "success":
    sys.exit("ERROR: IP geolocation query failed: " + str(data.get("message", "unknown")))
if not isinstance(data.get("query"), str) or not data["query"]:
    sys.exit("ERROR: Geolocation response lacks public IP.")
if sys.argv[1] == "json":
    print(json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2))
    sys.exit(0)
print("Context:           " + sys.argv[2])
fields = [
    ("query", "Public IPv4"), ("country", "Country"),
    ("countryCode", "Country code"), ("regionName", "Region"),
    ("city", "City"), ("zip", "Postal code"),
    ("timezone", "Timezone"), ("isp", "ISP"),
    ("org", "Organization"), ("as", "ASN"),
]
for key, label in fields:
    value = data.get(key)
    if value is not None and value != "":
        print(f"{label + chr(58):<19}{value}")
if data.get("lat") is not None and data.get("lon") is not None:
    print("Coordinates:       {}, {}".format(data["lat"], data["lon"]))
print("Provider:          ip-api.com (approximate location; HTTP)")
' "$format" "$context"
}

myloc_query() {
  local mode=$1 curl_bin probe_ip
  curl_bin=$(homebrew_curl) || fail 'Homebrew curl required (brew install curl).'
  local -a cmd=("$curl_bin" -4fsS --noproxy '*' --connect-timeout 3 --max-time 10)
  if [ "$mode" = app ]; then
    probe_ip=$(resolve_host_ipv4 ip-api.com) ||
      fail 'Cannot resolve ip-api.com via host DNS.'
    cmd+=(--resolve "ip-api.com:80:$probe_ip")
  fi
  cmd+=("${NNS_MYLOC_URL:-$MYLOC_URL}")
  if [ "$mode" = app ]; then
    run_app_output "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

myloc_command() {
  local requested='' format=pretty context=host mode=host json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) format=json ;;
      --*) fail "Unknown myloc option '$1'." ;;
      *)
        [ -z "$requested" ] || fail 'Usage: nns-app myloc [<name>] [--json]'
        requested=$1
        ;;
    esac
    shift
  done
  if [ -n "$requested" ]; then
    app_paths "$requested"
    require_profile
    [ -f "$RUNSTATE/ready" ] || fail "App '$APP' not running (use sudo nns-app start $APP)."
    context="app:$APP"
    mode=app
  fi
  json=$(myloc_query "$mode") ||
    fail "IP geolocation unavailable from '$context' (no Internet egress through this profile, DNS/API, or rate limit)."
  printf '%s\n' "$json" | myloc_format "$format" "$context"
}
status_app() {
  if [ ! -f "$RUNSTATE/ready" ]; then
    info "$APP: stopped (type=$(app_type_label), configured profile: $([ -f "$CONF" ] && echo yes || echo no))"
    return 0
  fi
  read_runtime
  local backend=$APP_TYPE
  [ ! -f "$RUNSTATE/backend" ] || backend=$(cat "$RUNSTATE/backend")
  info "$APP: started ($backend); $UTUN $VPN_IP, host default: $(default_if), originally: $PHY"
  if check_iface; then
    info '  interface: online'
  else
    info '  interface: MISSING -- run sudo nns-app recover app'
  fi
  info "  scoped route marker: $([ -f "$RUNSTATE/scoped_route" ] && echo present || echo missing)"
  info "  private DNS: $(selected_dns || true)"
  if [ "$(id -u)" -eq 0 ] && [ "$backend" = wireguard ]; then
    wg show "$UTUN" latest-handshakes 2>/dev/null || true
  fi
}
list_apps_header() {
  # Match Linux `nns-app list` inventory columns (Name/Type/Status/Via/...).
  printf 'Apps:\n'
  printf '%-20s %-18s %-9s %-13s %-42s %s\n' \
    'Name' 'Type' 'Status' 'Via' 'Endpoint / Online' 'Source'
  printf '%-20s %-18s %-9s %-13s %-42s %s\n' \
    '--------------------' '------------------' '---------' '-------------' \
    '------------------------------------------' '----------'
}

list_apps() {
  local dir app status online tun vpn_ip dns found=0

  for dir in "$APP_BASE"/*; do
    [ -d "$dir" ] || continue
    app=${dir##*/}
    app_paths "$app"
    if [ "$found" -eq 0 ]; then
      list_apps_header
      found=1
    fi

    status=stopped
    if [ -f "$CONF" ]; then
      online='profile | -'
    else
      online='none | -'
    fi
    if [ -f "$RUNSTATE/ready" ]; then
      status=started
      tun='-'
      vpn_ip='-'
      [ ! -f "$RUNSTATE/utun" ] || tun=$(cat "$RUNSTATE/utun")
      [ ! -f "$RUNSTATE/vpn_ip" ] || vpn_ip=$(cat "$RUNSTATE/vpn_ip")
      online="profile | $vpn_ip ($tun)"
    fi
    dns=$(selected_dns || true)
    if [ -n "$dns" ]; then
      online="$online; dns $dns"
    fi

    printf '%-20s %-18s %-9s %-13s %-42s %s\n' \
      "$app" "$(app_type_label)" "$status" 'host' "$online" 'local'
  done

  if [ "$found" -eq 0 ]; then
    info 'No apps configured.'
  fi
}
# git-via intentionally modifies only core.sshCommand in this repository.
# Requires a Homebrew SSH binary because Apple-protected /usr/bin/ssh generally
# ignores DYLD_INSERT_LIBRARIES.
git_via() {
  [ "$(id -u)" -ne 0 ] || fail 'Do not run git-via with sudo.'
  [ "$#" -eq 1 ] || fail 'Usage: git-via <app|->'
  command -v git >/dev/null 2>&1 || fail 'Git is required.'
  git rev-parse --git-dir >/dev/null 2>&1 || fail 'Run git-via inside a Git repository.'
  local desired previous state active current num ssh bin
  active=$(git config --local --get nnsGitVia.activeApp 2>/dev/null || true)
  num=$({ git config --local --get-all core.sshCommand 2>/dev/null || true; } | wc -l | tr -d ' ')
  [ "$num" -le 1 ] || fail 'Multiple local core.sshCommand values; refusing changes.'
  current=$(git config --local --get core.sshCommand 2>/dev/null || true)
  if [ "$1" = - ]; then
    [ -n "$active" ] || { info 'No active git-via setting.'; return 0; }
    desired=$(git config --local --get nnsGitVia.installed 2>/dev/null || true)
    [ "$current" = "$desired" ] || fail 'core.sshCommand changed externally; refusing overwrite.'
    state=$(git config --local --get nnsGitVia.previousSet 2>/dev/null || true)
    case "$state" in
      yes) previous=$(git config --local --get nnsGitVia.previousSSHCommand); git config --local --replace-all core.sshCommand "$previous";;
      no) git config --local --unset-all core.sshCommand;;
      *) fail 'Saved git-via state invalid.';;
    esac
    git config --local --unset-all nnsGitVia.activeApp
    git config --local --unset-all nnsGitVia.installed
    git config --local --unset-all nnsGitVia.previousSet
    if [ "$state" = yes ]; then git config --local --unset-all nnsGitVia.previousSSHCommand; fi
    info 'Restored previous repository SSH setting.'
    return 0
  fi
  app_paths "$1"; require_profile
  ssh=''
  for bin in /opt/homebrew/bin/ssh /usr/local/bin/ssh /opt/homebrew/opt/openssh/bin/ssh /usr/local/opt/openssh/bin/ssh; do
    [ -x "$bin" ] && ssh=$bin && break
  done
  [ -n "$ssh" ] || fail 'Install Homebrew OpenSSH: brew install openssh. Apple /usr/bin/ssh is protected.'
  if [ -n "$active" ]; then
    desired=$(git config --local --get nnsGitVia.installed 2>/dev/null || true)
    [ "$current" = "$desired" ] || fail 'core.sshCommand changed externally; refusing overwrite.'
  else
    [ -z "$(git config --local --get nnsGitVia.previousSet 2>/dev/null || true)" ] || fail 'Incomplete git-via state.'
    if [ "$num" -eq 1 ]; then
      git config --local --replace-all nnsGitVia.previousSSHCommand "$current"
      git config --local --replace-all nnsGitVia.previousSet yes
    else
      git config --local --replace-all nnsGitVia.previousSet no
    fi
  fi
  # No space or shell metacharacters in app name and installed binary path.
  desired="/usr/local/bin/nns-app run $APP $ssh"
  git config --local --replace-all core.sshCommand "$desired"
  git config --local --replace-all nnsGitVia.installed "$desired"
  git config --local --replace-all nnsGitVia.activeApp "$APP"
  info "Repository SSH now uses nns-app $APP. Use git-via - to restore."
}
usage() {
  cat <<USAGE
nns-app $VERSION macOS (experimental IPv4 WireGuard/OpenVPN client)
  nns-app install <name>                 Create app configuration
  nns-app add <name> <profile.conf|.ovpn>
                                         Import WireGuard (.conf) or OpenVPN (.ovpn)
  nns-app dns <name> <IPv4|off>          Override private per-app DNS (no host DNS changes)
  sudo nns-app start <name>              Start tunnel (wireguard-go or openvpn) + scoped utun
  nns-app run <name> [--] command...     Run command; auto-bind SIP tools (ping/nc/ssh/curl/wget/…)
  nns-app status <name> | list [apps]
  sudo nns-app stop <name>               Stop tunnel and remove scoped route
  sudo nns-app recover <name>            Cleanup interrupted tunnel start/stop
  nns-app remove <name>                  Remove stopped app profile
  nns-app git-via <name|->               Set/restore repository SSH transport
  nns-app myip [<name>]                  Probe public IP (host, or app via tunnel)
  nns-app myloc [<name>] [--json]        Geolocate host or app egress (ip-api.com)
  nns-app --version

OpenVPN on macOS uses --route-noexec (host default unchanged). Profiles must be
self-contained (inline certs/keys); up/down scripts are rejected.

NOT supported on macOS: AmneziaWG, namespace inheritance, gateway/server, remote
orchestration, arbitrary socket isolation, IPv6, UDP apps.
No PF, Unix group, host default-route, or host DNS settings are changed.
USAGE
}
main() {
  is_darwin || fail 'macOS backend only; Linux uses install_linux.'
  case "${1:-}" in
    -V|--version|version) echo "nns-app $VERSION (macOS)"; return;;
    ''|-h|--help|help) usage; return;;
  esac
  local cmd=$1
  shift
  owner_init
  case "$cmd" in
    install)
      [ "$#" -eq 1 ] || fail 'Usage: nns-app install <name>'
      [ "$(id -u)" -ne 0 ] || fail 'Run nns-app install without sudo.'
      app_paths "$1"
      [ ! -e "$CFG_DIR" ] || fail "App '$APP' already installed."
      mkdir -p "$APP_BASE"; chmod 700 "$(dirname "$APP_BASE")" "$APP_BASE"
      mkdir "$CFG_DIR"; chmod 700 "$CFG_DIR"
      info "Installed app configuration '$APP' (macOS VPN client)."
      ;;
    add)
      [ "$#" -eq 2 ] || fail 'Usage: nns-app add <name> <profile.conf|.ovpn>'
      [ "$(id -u)" -ne 0 ] || fail 'Run nns-app add without sudo.'
      app_paths "$1"; [ -d "$CFG_DIR" ] || fail "First run nns-app install $APP."
      [ ! -e "$RUNSTATE" ] || fail 'Stop the app before replacing its profile.'
      [ -r "$2" ] || fail 'Cannot read profile.'
      local kind hook_dns='' previous_conf err dest
      kind=$(detect_profile_kind "$2")
      cp -- "$2" "$CFG_DIR/.incoming"; chmod 600 "$CFG_DIR/.incoming"
      case "$kind" in
        openvpn)
          if ! hook_dns=$(normalize_ovpn_profile "$CFG_DIR/.incoming" 2>"$CFG_DIR/.hook-err"); then
            err=$(cat "$CFG_DIR/.hook-err" 2>/dev/null || true)
            rm -f "$CFG_DIR/.incoming" "$CFG_DIR/.hook-err"
            fail "${err:-Cannot import OpenVPN profile.}"
          fi
          rm -f "$CFG_DIR/.hook-err"
          dest="$CFG_DIR/profile.ovpn"
          rm -f "$CFG_DIR/profile.conf"
          mv -f "$CFG_DIR/.incoming" "$dest"
          printf 'openvpn\n' > "$TYPE_FILE"
          chmod 600 "$dest" "$TYPE_FILE"
          if [ -n "$hook_dns" ]; then
            printf '%s\n' "$hook_dns" > "$CFG_DIR/dns_ipv4"
            chmod 600 "$CFG_DIR/dns_ipv4"
            info "Imported OpenVPN profile into $APP (DNS $hook_dns from dhcp-option; scripts not executed)."
          else
            info "Imported OpenVPN profile into $APP."
          fi
          ;;
        wireguard)
          if ! hook_dns=$(normalize_wg_profile "$CFG_DIR/.incoming" 2>"$CFG_DIR/.hook-err"); then
            err=$(cat "$CFG_DIR/.hook-err" 2>/dev/null || true)
            rm -f "$CFG_DIR/.incoming" "$CFG_DIR/.hook-err"
            fail "${err:-Cannot import WireGuard profile.}"
          fi
          rm -f "$CFG_DIR/.hook-err"
          previous_conf=$CONF
          CONF="$CFG_DIR/.incoming"
          profile_ip
          CONF=$previous_conf
          dest="$CFG_DIR/profile.conf"
          rm -f "$CFG_DIR/profile.ovpn"
          mv -f "$CFG_DIR/.incoming" "$dest"
          printf 'wireguard\n' > "$TYPE_FILE"
          chmod 600 "$dest" "$TYPE_FILE"
          if [ -n "$hook_dns" ]; then
            printf '%s\n' "$hook_dns" > "$CFG_DIR/dns_ipv4"
            chmod 600 "$CFG_DIR/dns_ipv4"
            info "Imported WireGuard profile into $APP (IP $VPN_IP, DNS $hook_dns from resolvectl hooks; hooks not executed)."
          else
            info "Imported WireGuard profile into $APP (IP $VPN_IP)."
          fi
          ;;
      esac
      ;;
    dns)
      [ "$#" -eq 2 ] || fail 'Usage: nns-app dns <name> <IPv4|off>'
      [ "$(id -u)" -ne 0 ] || fail 'Run nns-app dns without sudo.'
      app_paths "$1"; [ -d "$CFG_DIR" ] || fail 'App not installed.'
      if [ "$2" = off ]; then printf '%s\n' '' > "$CFG_DIR/dns_ipv4"
      else valid_ipv4 "$2" || fail 'Expected DNS IPv4.'; printf '%s\n' "$2" > "$CFG_DIR/dns_ipv4"; fi
      chmod 600 "$CFG_DIR/dns_ipv4"
      info "App $APP DNS: $(selected_dns) (system resolver unchanged)."
      ;;
    start)
      [ "$#" -eq 1 ] || fail 'Usage: sudo nns-app start <name>'
      app_paths "$1"; start_app
      ;;
    stop|recover)
      [ "$#" -eq 1 ] || fail "Usage: sudo nns-app $cmd <name>"
      app_paths "$1"; require_admin; [ -d "$RUNSTATE" ] || fail 'No runtime state.'
      stop_app
      ;;
    run)
      [ "$#" -ge 2 ] || fail 'Usage: nns-app run <name> [--] command args...'
      app_paths "$1"; shift; run_app "$@"
      ;;
    status)
      [ "$#" -eq 1 ] || fail 'Usage: nns-app status <name>'
      app_paths "$1"; status_app
      ;;
    list)
      [ "$#" -le 1 ] || fail 'Usage: nns-app list [apps]'
      [ "$#" -eq 0 ] || [ "$1" = apps ] || fail 'macOS supports list [apps] only.'
      list_apps
      ;;
    remove)
      [ "$#" -eq 1 ] || fail 'Usage: nns-app remove <name>'
      [ "$(id -u)" -ne 0 ] || fail 'Run nns-app remove without sudo.'
      app_paths "$1"; [ -d "$CFG_DIR" ] || fail 'App not installed.'
      [ ! -e "$RUNSTATE" ] || fail 'Stop the app before removing its configuration.'
      rm -rf -- "$CFG_DIR"
      info "Removed $APP."
      ;;
    git-via)
      git_via "$@"
      ;;
    myip)
      local requested='' curl_bin ip probe_ip
      [ "$#" -le 1 ] || fail 'Usage: nns-app myip [<name>]'
      requested=${1:-}
      curl_bin=$(homebrew_curl) || fail 'Homebrew curl required (brew install curl).'
      if [ -n "$requested" ]; then
        app_paths "$requested"; require_profile
        probe_ip=$(resolve_host_ipv4 api.ipify.org) ||
          fail 'Cannot resolve api.ipify.org via host DNS.'
        ip=$(run_app_output "$curl_bin" -4 -fSs --noproxy '*' \
          --resolve "api.ipify.org:443:$probe_ip" \
          --connect-timeout 8 --max-time 15 https://api.ipify.org) ||
          fail "Public-IP probe failed for '$APP' (no Internet egress through this profile or network)."
      else
        ip=$("$curl_bin" -4 -fSs --noproxy '*' \
          --connect-timeout 8 --max-time 15 https://api.ipify.org) ||
          fail 'Public-IP probe failed (DNS or network).'
      fi
      printf '%s\n' "$ip"
      ;;
    myloc)
      myloc_command "$@"
      ;;
    *) fail "Command '$cmd' is not implemented on macOS $VERSION. See README compatibility table.";;
  esac
}
if [ "$(basename "$0")" = git-via ]; then
  # Reuse the public executable for repository SSH transport switching.
  main git-via "$@"
else
  main "$@"
fi
