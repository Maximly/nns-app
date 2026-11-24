#!/bin/bash
# nns-app -- macOS WireGuard/OpenVPN/AnyConnect client (IPv4, opt-in per-process routing).
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
MYLOC_FALLBACK_URLS="https://ipwho.is/"
if [ ! -x "$LIBEXEC/nns-run" ] && [ -x "$(dirname "$SELF")/bin/nns-run" ]; then
  LIBEXEC=$(cd "$(dirname "$SELF")/bin" && pwd -P)
fi
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
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
    anyconnect) CONF="$CFG_DIR/profile.oc" ;;
    wireguard|*) APP_TYPE=wireguard; CONF="$CFG_DIR/profile.conf" ;;
  esac
}
require_profile() {
  [ -f "$CONF" ] || fail "Profile not installed for '$APP'; use nns-app add $APP <profile.conf|.ovpn|.oc>."
}
app_type_label() {
  case "${1:-$APP_TYPE}" in
    openvpn) printf 'vpn-client/ovpn' ;;
    anyconnect) printf 'vpn-client/oc' ;;
    *) printf 'vpn-client/wg' ;;
  esac
}
detect_profile_kind() {
  # Classify an incoming profile path as wireguard, openvpn or anyconnect.
  local path=$1
  case "$path" in
    *.ovpn) printf 'openvpn'; return ;;
    *.oc) printf 'anyconnect'; return ;;
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
  if grep -Eiq '^[[:space:]]*protocol[[:space:]]*=[[:space:]]*(anyconnect|nc|pulse|gp|fortinet|f5|array)[[:space:]]*(#.*)?$' "$path"; then
    printf 'anyconnect'; return
  fi
  fail 'Unrecognized profile; use a WireGuard .conf, OpenVPN .ovpn or AnyConnect .oc file.'
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
  # The engine process recorded at start owns the utun. If it exited, the
  # utun is gone — or, worse, its number has been reused by another app's
  # tunnel. Never route traffic by stale state: refuse both cases.
  if ! engine_alive; then
    fail "The VPN engine for '$APP' exited; its tunnel is gone. Run: sudo nns-app restart $APP"
  fi
  check_iface || fail "Managed interface $UTUN is absent; run: sudo nns-app restart $APP"
  if ! ifconfig "$UTUN" 2>/dev/null |
       awk -v ip="$VPN_IP" '$1=="inet" && $2==ip {found=1} END {exit !found}'; then
    fail "Managed interface $UTUN no longer carries $VPN_IP (reused by another tunnel?); run: sudo nns-app restart $APP"
  fi
}
# The engine process that owns the app's tunnel: the pid recorded at start.
# A macOS utun lives exactly as long as the process holding it, so a dead
# engine means the tunnel is gone and every runtime marker is stale.
engine_state_pidfile() {
  local pidfile
  for pidfile in "$RUNSTATE/ovpn_pid" "$RUNSTATE/oc_pid" "$RUNSTATE/wg_pid"; do
    [ -f "$pidfile" ] || continue
    printf '%s\n' "$pidfile"
    return 0
  done
  return 1
}
engine_pid() {
  local pidfile pid
  pidfile=$(engine_state_pidfile 2>/dev/null || true) || return 1
  pid=$(cat "$pidfile")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid"
  return 0
}
engine_alive() { engine_alive_in "$RUNSTATE"; }
# Identity-aware liveness for an arbitrary runtime dir (used by the start
# sweep, which must not declare an app dead just because its recorded pid
# was recycled by an unrelated process).
engine_alive_in() {
  local dir=$1 pidfile pid recorded current
  for pidfile in "$dir/ovpn_pid" "$dir/oc_pid" "$dir/wg_pid"; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile")
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    if ! kill -0 "$pid" 2>/dev/null; then
      # EPERM (engine owned by another uid) still means the process exists;
      # only a failed ps lookup proves it is gone. Liveness must never
      # depend on who can signal the engine, or the app owner and root
      # disagree about whether a running tunnel exists. ps pads the pid
      # column, so strip whitespace before the exact match.
      ps -o pid= -p "$pid" 2>/dev/null | tr -d ' ' | grep -Fqx "$pid" || return 1
    fi
    # Identity beyond the pid number: macOS recycles pids quickly, so
    # compare the process start time recorded at launch. When times are
    # unavailable, at least require a VPN engine command line.
    recorded=$(cat "${pidfile%_pid}_lstart" 2>/dev/null || true)
    current=$(ps -o lstart= -p "$pid" 2>/dev/null || true)
    if [ -n "$recorded" ] && [ -n "$current" ]; then
      [ "$recorded" = "$current" ] || return 1
    elif [ -z "$current" ]; then
      # Process inspection denied (or the process vanished between checks;
      # kill -0 above catches that on the next round). Err alive rather
      # than starting the restart murder-loop in restricted environments.
      return 0
    else
      # No recorded start time (older state): verify the process is still
      # a VPN engine by its command line, not by the timestamp string.
      ps -o command= -p "$pid" 2>/dev/null |
        grep -Eqi 'openconnect|openvpn|wireguard-go' || return 1
    fi
    return 0
  done
  return 1
}
# Comprehensive staleness for recovery decisions: the engine is dead, OR the
# runtime claims no longer match reality (pid reused by another VPN engine,
# utun gone, or the claimed address no longer on the claimed interface).
app_runtime_stale() {
  if [ "${NNS_DEBUG_STALE:-0}" = 1 ]; then
    printf 'stale-debug: engine_alive=%s (pid files: ovpn=%s oc=%s wg=%s)\n' \
      "$(engine_alive && echo yes || echo no)" \
      "$(cat "$RUNSTATE/ovpn_pid" 2>/dev/null || echo none)" \
      "$(cat "$RUNSTATE/oc_pid" 2>/dev/null || echo none)" \
      "$(cat "$RUNSTATE/wg_pid" 2>/dev/null || echo none)" >&2
    local dbg_pidfile dbg_pid
    for dbg_pidfile in "$RUNSTATE/ovpn_pid" "$RUNSTATE/oc_pid" "$RUNSTATE/wg_pid"; do
      [ -f "$dbg_pidfile" ] || continue
      dbg_pid=$(cat "$dbg_pidfile" 2>/dev/null || true)
      printf 'stale-debug: pid %s kill0=%s lstart(rec)=[%s] lstart(now)=[%s] cmd=[%s]\n' \
        "$dbg_pid" \
        "$(kill -0 "$dbg_pid" 2>/dev/null && echo ok || echo fail)" \
        "$(cat "${dbg_pidfile%_pid}_lstart" 2>/dev/null || true)" \
        "$(ps -o lstart= -p "$dbg_pid" 2>/dev/null || true)" \
        "$(ps -o command= -p "$dbg_pid" 2>/dev/null | head -c 60)" >&2
    done
  fi
  engine_alive || return 0
  local claimed_utun claimed_ip
  claimed_utun=$(cat "$RUNSTATE/utun" 2>/dev/null || true)
  claimed_ip=$(cat "$RUNSTATE/vpn_ip" 2>/dev/null || true)
  [ "${NNS_DEBUG_STALE:-0}" != 1 ] ||
    printf 'stale-debug: utun=[%s] ip=[%s] live=[%s]\n' \
      "$claimed_utun" "$claimed_ip" \
      "$(ifconfig "$claimed_utun" 2>/dev/null | grep 'inet ' | head -n 1)" >&2
  case "$claimed_utun" in
    utun[0-9]*)
      if ifconfig "$claimed_utun" 2>/dev/null |
           awk -v ip="$claimed_ip" '$1=="inet" && $2==ip {found=1} END {exit !found}'; then
        return 1
      fi
      ;;
  esac
  return 0
}
# Interfaces currently carrying an IPv4 address. Interface names are tracked
# from ANY header line so non-utun carriers (bridges, vmenet) are attributed
# correctly instead of inheriting the previous utun's name.
iface_for_address() {
  local ip=$1 exclude=$2
  ifconfig -a 2>/dev/null | awk -v ip="$ip" -v exclude="$exclude" '
    /^[A-Za-z0-9]+[0-9]*:/ { iface=$1; sub(":", "", iface) }
    $1=="inet" && $2==ip && iface != exclude { print iface }'
}
# Resolve a duplicate tunnel address. A carrier owned by another managed app
# is refused by name; an orphaned utun (its engine lost the runtime state)
# is destroyed so the new engine can proceed. Prints the surviving
# conflicting interface on failure, nothing on success.
resolve_conflicting_address() {
  local ip=$1 exclude=$2 iface owner app survivor
  while read -r iface; do
    [ -n "$iface" ] || continue
    owner=''
    for app in "$USER_RUNTIME"/*; do
      [ -f "$app/ready" ] || continue
      [ "$(cat "$app/utun" 2>/dev/null || true)" = "$iface" ] || continue
      owner=$(basename "$app")
      break
    done
    if [ -n "$owner" ]; then
      fail "VPN address $ip is already assigned to the tunnel of managed app '$owner' ($iface); stop it first: sudo nns-app stop $owner"
    fi
    case "$iface" in
      utun[0-9]*)
        warn "Destroying orphaned tunnel '$iface' carrying $ip."
        ifconfig "$iface" destroy 2>/dev/null || true
        if [ -n "${APP:-}" ] && iface_for_address "$ip" "$exclude" | grep -Fqx "$iface"; then
          # Busy: the engine that created it still holds the interface and
          # macOS refuses to destroy a utun in use. Kill processes launched
          # by this app (their command line carries the NNS_APP_MARK); the
          # utun dies with its holder.
          local orphan_pid
          while read -r orphan_pid; do
            [ -n "$orphan_pid" ] || continue
            warn "Killing orphaned engine pid $orphan_pid holding '$iface'."
            kill "$orphan_pid" 2>/dev/null || true
            sleep 1
            iface_for_address "$ip" "$exclude" | grep -Fqx "$iface" || break
          done < <(pgrep -f "nns-app:$APP" 2>/dev/null || true)
        fi
        ;;
    esac
  done < <(iface_for_address "$ip" "$exclude")
  survivor=$(iface_for_address "$ip" "$exclude" | head -n 1)
  [ -z "$survivor" ] || { printf '%s\n' "$survivor"; return 1; }
  return 0
}
# The run/git path self-heals a stale app: if the engine exited (its utun
# is gone, so no scoped-route cleanup is needed), restart it automatically
# instead of failing. Elevation uses passwordless sudo, because run/git-via
# execute without a TTY and cannot prompt.
# Elevate to root and bring the app to a clean running state: `restart`
# converges for every state (stopped apps start fresh, stale state is
# stopped and cleared, a live engine is replaced), so it never hits the
# root-side "Runtime state exists" refusal that `start` can trigger.
# First without a password (cached or NOPASSWD sudo), then with an
# interactive prompt. git children keep the session's controlling terminal,
# so sudo can read the password there even though stdout is the protocol
# pipe.
start_via_sudo() {
  sudo -n "$0" restart "$APP" >&2 2>/dev/null && return 0
  sudo "$0" restart "$APP" >&2
}
# The run/git path self-heals: a stale app (engine exited, or its claims no
# longer match reality) is restarted, and a stopped app is started, instead
# of failing the command. stdout is the caller's channel (app output, or the
# git SSH protocol pipe), so all status output goes to stderr.
ensure_engine_running() {
  local attempt=0 engine_log f
  while :; do
    if [ ! -f "$RUNSTATE/ready" ] || app_runtime_stale; then
      printf 'Auto-restarting %s (its VPN engine exited; the tunnel is gone)...\n' "$APP" >&2
      start_via_sudo || fail "Auto-restart of '$APP' failed; run: sudo nns-app restart $APP"
      sleep 2
      attempt=$((attempt + 1))
      [ "$attempt" -lt 3 ] || {
        engine_log=''
        for f in "$RUNSTATE/ovpn.log" "$RUNSTATE/oc.log" "$RUNSTATE/wg.log"; do
          [ -f "$f" ] || continue
          engine_log=$f
          break
        done
        if [ -n "$engine_log" ]; then
          printf 'Recent engine log (%s):\n' "$engine_log" >&2
          if ! tail -20 "$engine_log" 2>/dev/null; then
            sudo -n tail -20 "$engine_log" >&2 2>/dev/null || true
          fi
        fi
        fail "The VPN engine for '$APP' keeps exiting after restart; see the log above."
      }
      continue
    fi
    return 0
  done
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
domains = []
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
    if key == "dhcp-option":
        # OpenVPN's native macOS DNS integration would rewrite the system
        # resolver from these options. nns-app never touches host DNS: it
        # extracts the policy here and applies it through the per-app
        # interposer instead, so drop the directive from the active profile.
        if len(parts) >= 3:
            if parts[1].lower() == "dns":
                try:
                    address = ipaddress.ip_address(parts[2])
                except ValueError as exc:
                    raise SystemExit(f"invalid dhcp-option DNS: {parts[2]}") from exc
                if address.version == 4 and not address.is_unspecified and not address.is_multicast:
                    dns.append(str(address))
            elif parts[1].lower() == "domain":
                domain = parts[2].lower().rstrip(".")
                if domain and len(domain) <= 253 and all(
                    1 <= len(label) <= 63 and
                    re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", label)
                    for label in domain.split(".")
                ):
                    domains.append(domain)
                else:
                    raise SystemExit(f"invalid dhcp-option DOMAIN: {parts[2]}")
        kept.append(comment(line))
        continue
    kept.append(line + "\n")

if not has_remote:
    raise SystemExit("Profile has no 'remote' directive.")
path.write_text("".join(kept), encoding="utf-8")
print("|".join((dns[0] if dns else "", " ".join(dict.fromkeys(domains)))))
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
  elif [ "$APP_TYPE" = anyconnect ] && [ -f "$RUNSTATE/oc_dns" ]; then
    cat "$RUNSTATE/oc_dns"
  elif [ "$APP_TYPE" = wireguard ] && [ -f "$CONF" ]; then
    profile_dns
  fi
}

# Route-only domains from the imported profile: only these names use the
# per-app VPN resolver; every other name keeps the system resolver.
selected_dns_domains() {
  if [ -f "$CFG_DIR/dns_domains" ]; then
    cat "$CFG_DIR/dns_domains"
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
openconnect_bin() {
  local candidate
  for candidate in \
    /opt/homebrew/sbin/openconnect /usr/local/sbin/openconnect \
    /opt/homebrew/bin/openconnect /usr/local/bin/openconnect; do
    if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  command -v openconnect 2>/dev/null || return 1
}
# The next free utun name, computed the same way wireguard-go allocates them.
next_utun() {
  local max=0 n
  for u in $(list_utuns); do
    n=${u#utun}
    [ "$n" -gt "$max" ] && max=$n
  done
  printf 'utun%d\n' $((max + 1))
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
    local pid waited
    pid=$(cat "$RUNSTATE/ovpn_pid")
    case "$pid" in ''|*[!0-9]*) fail 'Invalid OpenVPN engine PID.';; esac
    if ps -p "$pid" -o command= 2>/dev/null | grep -Eqi 'openvpn'; then
      kill "$pid" 2>/dev/null || true
      # Let OpenVPN exit gracefully: its native macOS down-path restores
      # any system DNS it may have changed. Only force-kill afterwards.
      waited=0
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [ -s "$RUNSTATE/oc_pid" ]; then
    local pid waited
    pid=$(cat "$RUNSTATE/oc_pid")
    case "$pid" in ''|*[!0-9]*) fail 'Invalid OpenConnect engine PID.';; esac
    if ps -p "$pid" -o command= 2>/dev/null | grep -Eqi 'openconnect'; then
      kill "$pid" 2>/dev/null || true
      # openconnect runs its script with reason=disconnect on SIGTERM, which
      # clears the readiness markers; force-kill only if it lingers.
      waited=0
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
      done
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
  local default_before=$1 mode=${2:-full}
  case "$UTUN" in utun[0-9]*) ;; *) fail 'Tunnel interface discovery failed.';; esac
  valid_ipv4 "$VPN_IP" || fail 'Tunnel IPv4 discovery failed.'
  printf '%s\n' "$UTUN" > "$RUNSTATE/utun"
  printf '%s\n' "$VPN_IP" > "$RUNSTATE/vpn_ip"
  chmod 644 "$RUNSTATE/utun" "$RUNSTATE/vpn_ip"
  # The engines' logs are created by root under umask 077; make them
  # readable so the unprivileged run path can diagnose a dying engine.
  chmod 644 "$RUNSTATE/ovpn.log" "$RUNSTATE/oc.log" "$RUNSTATE/wg.log" 2>/dev/null || true
  if [ "$mode" = split ]; then
    # Split-tunnel backends have no default route through the VPN; only the
    # interface-scoped LAN routes recorded by the hook carry traffic.
    rm -f "$RUNSTATE/scoped_route"
  else
    route -q -n add -ifscope "$UTUN" -inet default -interface "$UTUN" ||
      fail 'Unable to install interface-scoped route.'
    printf '%s\n' "$UTUN" > "$RUNSTATE/scoped_route"; chmod 644 "$RUNSTATE/scoped_route"
  fi
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
  ps -o lstart= -p "$pid" 2>/dev/null > "$RUNSTATE/wg_lstart" || true
  chmod 644 "$RUNSTATE/wg_lstart" 2>/dev/null || true
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
    --pull-filter ignore dhcp-option \
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
  ps -o lstart= -p "$pid" 2>/dev/null > "$RUNSTATE/ovpn_lstart" || true
  chmod 644 "$RUNSTATE/ovpn_lstart" 2>/dev/null || true
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
  local conflict
  if ! conflict=$(resolve_conflicting_address "$VPN_IP" "$UTUN"); then
    [ -n "$conflict" ] || conflict=$(iface_for_address "$VPN_IP" "$UTUN" | head -n 1)
    fail "VPN address $VPN_IP is already assigned on another interface (${conflict:-unknown}); an orphaned VPN engine may hold it — stop the owning app or reboot."
  fi
  confine_openvpn_utun "$UTUN" "$VPN_IP"
  finish_scoped_start "$default_before"
  info "Started $APP (openvpn): $UTUN ($VPN_IP), host default $default_before unchanged."
}
# ---- AnyConnect (OpenConnect) backend -------------------------------------
# The profile format is nns-app's own key=value convention (.oc), not a Cisco
# native format. Imported profiles are untrusted: only a fixed allow-list of
# directives is accepted and helper scripts named by the profile are rejected.
oc_profile_value() {
  local file=$1 key=$2
  awk -F= -v wanted="$key" '
    BEGIN { inblock=0 }
    { gsub(/\r/, "") }
    /^[[:space:]]*<(cert|key)>[[:space:]]*$/ { inblock=1; next }
    /^[[:space:]]*<\/(cert|key)>[[:space:]]*$/ { inblock=0; next }
    inblock { next }
    /^[[:space:]]*#/ { next }
    {
      k=$1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k)
      k=tolower(k)
      # `password=` is an accepted alias for `passwd=`.
      if (k == "password") k = "passwd"
      if (k == wanted) {
        v=substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        # Inline comments: `key=value  # note` is allowed. A value containing
        # " #" is therefore not representable (avoid it in passwords).
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/[[:space:]]+$/, "", v)
        print v
        exit
      }
    }' "$file"
}
oc_pem_block() {
  local file=$1 tag=$2
  sed -n "/^[[:space:]]*<$tag>[[:space:]]*$/,/^[[:space:]]*<\/$tag>[[:space:]]*$/p" "$file" |
    tr -d '\r' | sed '1d;$d'
}
oc_pem_valid() {
  local file=$1 tag=$2 body first last middle
  body=$(oc_pem_block "$file" "$tag")
  [ -n "$body" ] || return 1
  first=$(printf '%s\n' "$body" | sed -n '1p')
  last=$(printf '%s\n' "$body" | sed -n '$p')
  printf '%s\n' "$first" | grep -Eq '^-----BEGIN (CERTIFICATE|RSA PRIVATE KEY|EC PRIVATE KEY|ENCRYPTED PRIVATE KEY|PRIVATE KEY)-----$' || return 1
  printf '%s\n' "$last" | grep -Eq '^-----END (CERTIFICATE|RSA PRIVATE KEY|EC PRIVATE KEY|ENCRYPTED PRIVATE KEY|PRIVATE KEY)-----$' || return 1
  middle=$(printf '%s\n' "$body" | sed '1d;$d')
  [ -n "$middle" ] || return 1
  if printf '%s\n' "$middle" | grep -Eqv '^[A-Za-z0-9+/=[:space:]]*$'; then return 1; fi
  return 0
}
oc_validate_values() {
  local conf=$1
  local server proto user passwd authgroup fingerprint tmode tsec rmode mtu ua
  local host port certs keys fp_kind fp_body
  server=$(oc_profile_value "$conf" server)
  [ -n "$server" ] || { echo "AnyConnect profile has no 'server=' entry." >&2; return 1; }
  if ! printf '%s\n' "$server" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$'; then
    echo "Invalid AnyConnect server URL '$server'; use https://host[:port]." >&2
    return 1
  fi
  port=$(printf '%s\n' "$server" | sed -E 's#^https://[^:/]+(:([0-9]{1,5}))?/?$#\2#')
  [ -n "$port" ] || port=443
  case "$port" in ''|*[!0-9]*) echo 'Invalid AnyConnect server port.' >&2; return 1 ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo 'AnyConnect server port must be within 1..65535.' >&2; return 1; }

  proto=$(oc_profile_value "$conf" protocol)
  [ -n "$proto" ] || proto=anyconnect
  case "$proto" in
    anyconnect|nc|pulse|gp|fortinet|f5|array) ;;
    *) echo "Unsupported OpenConnect protocol '$proto'." >&2; return 1 ;;
  esac

  user=$(oc_profile_value "$conf" user)
  if [ -n "$user" ]; then
    printf '%s\n' "$user" | grep -Eq '^[A-Za-z0-9@._-]{1,128}$' ||
      { echo 'Invalid AnyConnect username in profile.' >&2; return 1; }
  fi
  passwd=$(oc_profile_value "$conf" passwd)
  if [ -n "$passwd" ]; then
    # BSD grep caps repetition bounds at 255, so the length is checked
    # separately from the character class.
    if ! printf '%s\n' "$passwd" | grep -Eq '^[[:print:]]+$'; then
      echo 'Invalid AnyConnect password in profile (printable characters only, max 256).' >&2
      return 1
    fi
    if printf '%s\n' "$passwd" | grep -Eq '[[:cntrl:]]' || [ "${#passwd}" -gt 256 ]; then
      echo 'Invalid AnyConnect password in profile (no control characters, max 256).' >&2
      return 1
    fi
  fi
  authgroup=$(oc_profile_value "$conf" authgroup)
  if [ -n "$authgroup" ]; then
    printf '%s\n' "$authgroup" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 ._@/()-]{0,126}$' ||
      { echo 'Invalid AnyConnect auth group in profile.' >&2; return 1; }
  fi
  fingerprint=$(oc_profile_value "$conf" fingerprint)
  if [ -n "$fingerprint" ]; then
    fp_kind=${fingerprint%%:*}
    fp_body=${fingerprint#*:}
    case "$fp_kind" in
      SHA1|sha1)
        printf '%s\n' "$fp_body" | grep -Eq '^([0-9A-Fa-f]{2}:){19}[0-9A-Fa-f]{2}$' ||
          { echo 'Invalid SHA1 fingerprint in profile.' >&2; return 1; } ;;
      SHA256|sha256)
        printf '%s\n' "$fp_body" | grep -Eq '^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$' ||
          { echo 'Invalid SHA256 fingerprint in profile.' >&2; return 1; } ;;
      PIN-SHA256|pin-sha256)
        # The format openconnect itself prints in its certificate error
        # message: a base64-encoded SHA-256 digest.
        printf '%s\n' "$fp_body" | grep -Eq '^[A-Za-z0-9+/]{40,48}={0,2}$' ||
          { echo 'Invalid pin-sha256 fingerprint in profile; use the value shown by openconnect in its certificate error.' >&2; return 1; } ;;
      *) echo "Invalid fingerprint kind '$fp_kind'; use SHA1:, SHA256: or pin-sha256:." >&2; return 1 ;;
    esac
  fi
  tmode=$(oc_profile_value "$conf" token-mode)
  if [ -n "$tmode" ]; then
    case "$tmode" in
      rsa|totp|hotp|oidc|yubioath) ;;
      *) echo "Unsupported token-mode '$tmode'." >&2; return 1 ;;
    esac
  fi
  tsec=$(oc_profile_value "$conf" token-secret)
  if [ -n "$tsec" ]; then
    printf '%s\n' "$tsec" | grep -Eq '^(base32|hotp):[A-Za-z2-7]{16,128}$' ||
      { echo 'Invalid token-secret in profile; use base32:<secret> (TOTP) or hotp:<secret>.' >&2; return 1; }
  fi
  rmode=$(oc_profile_value "$conf" route-mode)
  if [ -n "$rmode" ]; then
    case "$rmode" in
      split|full) ;;
      *) echo "Invalid route-mode '$rmode'; use split or full." >&2; return 1 ;;
    esac
  fi
  mtu=$(oc_profile_value "$conf" mtu)
  if [ -n "$mtu" ]; then
    case "$mtu" in
      ''|*[!0-9]*|0*) echo "Invalid AnyConnect mtu '$mtu'; use 576..9000." >&2; return 1 ;;
    esac
    [ "$mtu" -ge 576 ] && [ "$mtu" -le 9000 ] ||
      { echo "Invalid AnyConnect mtu '$mtu'; use 576..9000." >&2; return 1; }
  fi
  ua=$(oc_profile_value "$conf" useragent)
  if [ -n "$ua" ]; then
    printf '%s\n' "$ua" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 .()/_-]{7,127}$' ||
      { echo 'Invalid AnyConnect useragent in profile.' >&2; return 1; }
  fi

  dtls=$(oc_profile_value "$conf" dtls)
  if [ -n "$dtls" ]; then
    case "$dtls" in
      on|off) ;;
      *) echo "Invalid dtls value '$dtls'; use on or off." >&2; return 1 ;;
    esac
  fi

  dns_key=$(oc_profile_value "$conf" dns)
  if [ -n "$dns_key" ]; then
    printf '%s\n' "$dns_key" | grep -Eq '^[0-9.]+( [0-9.]+){0,3}$' ||
      { echo 'Invalid dns value in profile; use a space-separated IPv4 list (max four).' >&2; return 1; }
    for dns_item in $dns_key; do
      valid_ipv4 "$dns_item" || { echo "Invalid dns entry '$dns_item' in profile; use IPv4 addresses." >&2; return 1; }
    done
  fi

  # grep -c exits 1 on zero matches; the guard keeps set -e from aborting.
  certs=$(grep -Ec '^[[:space:]]*<cert>[[:space:]]*$' "$conf" || true)
  keys=$(grep -Ec '^[[:space:]]*<key>[[:space:]]*$' "$conf" || true)
  if [ "$certs" -ne "$keys" ] || [ "$certs" -gt 1 ]; then
    echo 'AnyConnect client certificates must embed exactly one <cert> and one <key> block.' >&2
    return 1
  fi
  if [ "$certs" -eq 1 ]; then
    oc_pem_valid "$conf" cert || { echo 'AnyConnect <cert> block does not contain a valid PEM certificate.' >&2; return 1; }
    oc_pem_valid "$conf" key || { echo 'AnyConnect <key> block does not contain a valid PEM private key.' >&2; return 1; }
  fi
  return 0
}
# LF-normalize and enforce the directive allow-list, then validate values.
# Writes the normalized profile back to the same path on success.
normalize_oc_profile() {
  local conf=$1 tmp
  [ -f "$conf" ] || { echo 'Profile not found.' >&2; return 1; }
  [ -s "$conf" ] || { echo 'Profile is empty.' >&2; return 1; }
  [ "$(wc -c <"$conf" | tr -d ' ')" -le 65536 ] ||
    { echo 'AnyConnect profile is unexpectedly large (>64 KiB).' >&2; return 1; }
  tmp="$conf.norm.$$"
  if ! awk '
      BEGIN { inblock=0; bad=0
        allowed="^(protocol|server|user|passwd|authgroup|fingerprint|token-mode|token-secret|route-mode|mtu|useragent|dtls|dns)$"
      }
      { gsub(/\r/, "") }
      /^[[:space:]]*#/ { print; next }
      /^[[:space:]]*$/ { print; next }
      /^[[:space:]]*<(cert|key)>[[:space:]]*$/ { inblock=1; print; next }
      /^[[:space:]]*<\/(cert|key)>[[:space:]]*$/ { inblock=0; print; next }
      inblock { print; next }
      {
        key=$1; sub(/=.*/, "", key); key=tolower(key)
        # `password=` is an accepted alias for `passwd=`; declaring both is
        # ambiguous and rejected as a duplicate. Error lines name the key
        # only, never the value (credentials must not leak into output).
        if (key == "password") key = "passwd"
        if (key !~ allowed) {
          print "unsupported directive: " key > "/dev/stderr"; bad=1
        } else if (seen[key]++) {
          print "duplicate directive: " key > "/dev/stderr"; bad=1
        }
        print
      }
      END { exit bad }
    ' "$conf" >"$tmp"; then
    rm -f "$tmp"
    echo 'AnyConnect profile contains unsupported directives (allow-list: protocol, server, user, passwd (alias password), authgroup, fingerprint, token-mode, token-secret, route-mode, mtu, useragent, dtls, dns, inline <cert>/<key>).' >&2
    return 1
  fi
  mv -f "$tmp" "$conf"
  oc_validate_values "$conf" || return 1
}
# The vpnc-script replacement openconnect runs as root: assigns the utun /32
# address, applies MTU, records interface-scoped split routes and the pushed
# DNS hint. openconnect runs the script via `/bin/sh -c` and passes the reason
# in the `reason` environment variable; TUNDEV is set too, and the requested
# utun name is baked in as a fallback. Host DNS and the host default route are
# never modified.
write_oc_hook() {
  local want_utun=$1
  cat >"$RUNSTATE/oc-hook" <<'OC_HOOK'
#!/bin/bash
# Generated by nns-app for an AnyConnect session; replaced on every start.
hook_reason=${1:-}
[ -n "$hook_reason" ] || hook_reason=${reason:-}
dev=${TUNDEV:-}
[ -n "$dev" ] || dev=@UTUN@
runstate=@RUNSTATE@
ip=${INTERNAL_IP4_ADDRESS:-}
mtu=${INTERNAL_IP4_MTU:-}
# Gateway-pushed values are untrusted: shape- and range-check before use.
valid_ip() {
  printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1; exit 0}'
}
case "$hook_reason" in
  connect|reconnect)
    [ -n "$dev" ] || exit 0
    case "$dev" in utun[0-9]*) ;; *) exit 1 ;; esac
    valid_ip "$ip" || exit 1
    # A /32 assignment keeps the connected route from leaking to every
    # process (same model as the managed OpenVPN confinement); traffic is
    # carried by the interface-scoped routes below.
    ifconfig "$dev" inet "$ip" "$ip" netmask 255.255.255.255 up || exit 1
    case "$mtu" in
      ''|*[!0-9]*) ;;
      *) if [ "$mtu" -ge 576 ] && [ "$mtu" -le 9000 ]; then
           ifconfig "$dev" mtu "$mtu" 2>/dev/null || true
         fi ;;
    esac
    : >"$runstate/scoped_lan"
    chmod 644 "$runstate/scoped_lan"
    split=0
    for var in $(env | sed -n 's/^CISCO_SPLIT_INC_\([0-9][0-9]*\)_ADDR=.*/\1/p'); do
      eval "addr=\${CISCO_SPLIT_INC_${var}_ADDR:-}"
      eval "mlen=\${CISCO_SPLIT_INC_${var}_MASKLEN:-}"
      eval "msk=\${CISCO_SPLIT_INC_${var}_MASK:-}"
      valid_ip "$addr" || continue
      p=$mlen
      if [ -z "$p" ]; then
        p=$(printf '%s\n' "$msk" | awk -F. '{p=0; for(i=1;i<=4;i++){v=$i+0; while(v>0){if(v%2)p++; v=int(v/2)}} print p}')
      fi
      case "$p" in ''|*[!0-9]*) p=32 ;; esac
      if [ "$p" -lt 0 ] || [ "$p" -gt 32 ]; then p=32; fi
      route -q -n add -ifscope "$dev" -net "$addr/$p" -interface "$dev" >/dev/null 2>&1 || true
      printf '%s %s\n' "$dev" "$addr/$p" >>"$runstate/scoped_lan"
      split=1
    done
    if [ "$split" = 1 ]; then
      : >"$runstate/oc-split"
      chmod 644 "$runstate/oc-split"
    fi
    dns=$(printf '%s\n' "${INTERNAL_IP4_DNS:-}" | awk '{
      for (i=1;i<=NF;i++) {
        n=split($i, o, ".")
        if (n==4) {
          ok=1
          for (j=1;j<=4;j++) if (o[j] !~ /^[0-9]+$/ || o[j]>255) ok=0
          if (ok) printf "%s ", $i
        }
      }
    }')
    if [ -z "$dns" ]; then
      # Gateways that push no resolvers often answer DNS on their own
      # tunnel address; use it as a fallback resolver.
      gw=${VPNGATEWAY:-}
      if valid_ip "$gw"; then dns="$gw "; fi
    fi
    if [ -n "$dns" ]; then
      printf '%s\n' "$dns" >"$runstate/oc_dns"
      chmod 644 "$runstate/oc_dns"
    fi
    printf '%s %s\n' "$dev" "$ip" >"$runstate/oc-ready"
    chmod 644 "$runstate/oc-ready"
    exit 0
    ;;
    attempt-reconnect)
      # Transport is down and a retry is starting: drop the readiness
      # markers but keep the utun and its routes for the retry.
      rm -f "$runstate/oc-ready" "$runstate/oc-split"
      exit 0
      ;;
  disconnect)
    rm -f "$runstate/oc-ready" "$runstate/oc-split" "$runstate/oc_dns"
    if [ -n "$dev" ]; then ifconfig "$dev" down 2>/dev/null || true; fi
    exit 0
    ;;
esac
exit 0
OC_HOOK
  hook_tmp="$RUNSTATE/oc-hook.tmp"
  sed -e "s#@RUNSTATE@#$RUNSTATE#g" -e "s#@UTUN@#$want_utun#g" \
      "$RUNSTATE/oc-hook" >"$hook_tmp"
  mv -f "$hook_tmp" "$RUNSTATE/oc-hook"
  chmod 700 "$RUNSTATE/oc-hook"
}
# Non-interactive `openconnect --authenticate` for a profile with scriptable
# inline credentials. Stores the session cookie (atomic replace) and prints
# it on success, so `start` can persist sessions without a separate oc-login.
oc_obtain_cookie() {
  local conf=$1 oc server proto user passwd authgroup fp tmode tsec ua output cookie tmpdir
  oc=$(openconnect_bin) || return 1
  server=$(oc_profile_value "$conf" server)
  proto=$(oc_profile_value "$conf" protocol); [ -n "$proto" ] || proto=anyconnect
  user=$(oc_profile_value "$conf" user)
  passwd=$(oc_profile_value "$conf" passwd)
  authgroup=$(oc_profile_value "$conf" authgroup)
  fp=$(oc_profile_value "$conf" fingerprint)
  tmode=$(oc_profile_value "$conf" token-mode)
  tsec=$(oc_profile_value "$conf" token-secret)
  ua=$(oc_profile_value "$conf" useragent)
  [ -n "$user" ] && [ -n "$passwd" ] || return 1
  # An interactive one-time code cannot be answered here.
  [ -z "$tmode" ] || [ -n "$tsec" ] || return 1
  set -- "$oc" --authenticate --quiet --protocol "$proto" --user "$user"
  [ -z "$authgroup" ] || set -- "$@" --authgroup "$authgroup"
  [ -z "$fp" ] || set -- "$@" --servercert "$fp"
  [ -z "$tmode" ] || set -- "$@" --token-mode "$tmode"
  [ -z "$tsec" ] || set -- "$@" --token-secret "$tsec"
  [ -z "$ua" ] || set -- "$@" --useragent "$ua"
  tmpdir=''
  if grep -Eq '^[[:space:]]*<(cert|key)>[[:space:]]*$' "$conf"; then
    tmpdir=$(mktemp -d); chmod 700 "$tmpdir"
    oc_pem_block "$conf" cert >"$tmpdir/cert.pem"
    oc_pem_block "$conf" key >"$tmpdir/key.pem"
    chmod 600 "$tmpdir/cert.pem" "$tmpdir/key.pem"
    set -- "$@" --certificate "$tmpdir/cert.pem" --sslkey "$tmpdir/key.pem"
  fi
  set -- "$@" "$server"
  output=$(printf '%s\n%s\n' "$user" "$passwd" | "$@" 2>/dev/null) || {
    [ -z "$tmpdir" ] || rm -rf "$tmpdir"
    return 1
  }
  [ -z "$tmpdir" ] || rm -rf "$tmpdir"
  cookie=$(printf '%s\n' "$output" | grep -E '^COOKIE=' | tail -n1 | cut -d= -f2-)
  cookie=${cookie#\'}
  cookie=${cookie%\'}
  if ! printf '%s\n' "$cookie" | grep -Eq '^[A-Za-z0-9+/=_-]+$'; then
    return 1
  fi
  [ "${#cookie}" -ge 8 ] && [ "${#cookie}" -le 4096 ] || return 1
  cookie_tmp="$CFG_DIR/.cookie.$$"
  if printf '%s' "$cookie" >"$cookie_tmp" &&
     chmod 600 "$cookie_tmp" &&
     mv -f "$cookie_tmp" "$CFG_DIR/cookie"; then
    :
  else
    rm -f "$cookie_tmp"
    return 1
  fi
  printf '%s\n' "$cookie"
}

start_anyconnect() {
  local default_before=$1 pid it before after cand ip oc runtime_conf err split=0 mode
  local OC_SERVER OC_PROTO OC_USER OC_PASS OC_AUTHGROUP OC_FP OC_TMODE OC_TSEC OC_UA OC_MTU OC_DTLS
  local want_utun ready=0
  oc=$(openconnect_bin) || fail 'Missing openconnect (brew install openconnect).'
  before=$(list_utuns | tr '\n' ' ')
  prepare_runtime "$default_before"
  runtime_conf="$RUNSTATE/profile.oc"
  cp -- "$CONF" "$runtime_conf"
  chmod 600 "$runtime_conf"
  if ! normalize_oc_profile "$runtime_conf" >/dev/null 2>"$RUNSTATE/oc-sanitize.err"; then
    err=$(cat "$RUNSTATE/oc-sanitize.err" 2>/dev/null || true)
    fail "${err:-AnyConnect profile failed validation before start.}"
  fi
  OC_SERVER=$(oc_profile_value "$runtime_conf" server)
  OC_PROTO=$(oc_profile_value "$runtime_conf" protocol); [ -n "$OC_PROTO" ] || OC_PROTO=anyconnect
  OC_USER=$(oc_profile_value "$runtime_conf" user)
  OC_PASS=$(oc_profile_value "$runtime_conf" passwd)
  OC_AUTHGROUP=$(oc_profile_value "$runtime_conf" authgroup)
  OC_FP=$(oc_profile_value "$runtime_conf" fingerprint)
  OC_TMODE=$(oc_profile_value "$runtime_conf" token-mode)
  OC_TSEC=$(oc_profile_value "$runtime_conf" token-secret)
  OC_UA=$(oc_profile_value "$runtime_conf" useragent)
  OC_MTU=$(oc_profile_value "$runtime_conf" mtu)
  OC_DTLS=$(oc_profile_value "$runtime_conf" dtls)

  if [ -s "$CFG_DIR/cookie" ]; then
    info "Using the saved AnyConnect session cookie for '$APP'."
    mode=cookie
  elif oc_obtain_cookie "$runtime_conf"; then
    info "Stored a fresh AnyConnect session cookie for '$APP'; later starts will reuse it."
    mode=cookie
  elif [ -n "$OC_USER" ] && [ -n "$OC_PASS" ]; then
    printf '%s\n%s\n' "$OC_USER" "$OC_PASS" >"$RUNSTATE/oc-creds"
    chmod 600 "$RUNSTATE/oc-creds"
    mode=creds
  else
    fail "No AnyConnect credentials for '$APP'. Run: nns-app oc-login $APP (interactive), or set user=/passwd= in the profile."
  fi

  # Deterministic utun request: the next free index above what exists now.
  # The hook embeds the same name as its TUNDEV fallback.
  want_utun=$(next_utun)
  write_oc_hook "$want_utun"
  if grep -Eq '^[[:space:]]*<(cert|key)>[[:space:]]*$' "$runtime_conf"; then
    oc_pem_block "$runtime_conf" cert >"$RUNSTATE/oc-cert.pem"
    oc_pem_block "$runtime_conf" key >"$RUNSTATE/oc-key.pem"
    chmod 600 "$RUNSTATE/oc-cert.pem" "$RUNSTATE/oc-key.pem"
  fi

  : >"$RUNSTATE/oc.log"
  set -- "$oc" --non-inter --protocol "$OC_PROTO" \
    --interface "$want_utun" \
    --script "$RUNSTATE/oc-hook"
  [ -z "$OC_AUTHGROUP" ] || set -- "$@" --authgroup "$OC_AUTHGROUP"
  [ -z "$OC_FP" ] || set -- "$@" --servercert "$OC_FP"
  [ -z "$OC_TMODE" ] || set -- "$@" --token-mode "$OC_TMODE"
  [ -z "$OC_TSEC" ] || set -- "$@" --token-secret "$OC_TSEC"
  [ -z "$OC_UA" ] || set -- "$@" --useragent "$OC_UA"
  case "$OC_MTU" in ''|*[!0-9]*) ;; *) set -- "$@" --mtu "$OC_MTU" ;; esac
  # DTLS is attempted automatically; allow disabling it when the network
  # blocks UDP (otherwise openconnect retries every minute).
  [ "$OC_DTLS" != off ] || set -- "$@" --no-dtls
  # The macOS backend is IPv4-only; never negotiate an IPv6 tunnel address.
  set -- "$@" --disable-ipv6
  # openconnect >= 9.x enables vhost-net by default (queue >= 16); that path
  # is unreliable for tun/utun, so keep the queue below 16 to disable it.
  set -- "$@" --queue-len 8
  if [ -s "$RUNSTATE/oc-cert.pem" ]; then
    set -- "$@" --certificate "$RUNSTATE/oc-cert.pem" --sslkey "$RUNSTATE/oc-key.pem"
  fi
  if [ "$mode" = cookie ]; then
    set -- "$@" --cookie-on-stdin
  else
    set -- "$@" --user "$OC_USER" --passwd-on-stdin
  fi
  set -- "$@" "$OC_SERVER"
  if [ "$mode" = cookie ]; then
    "$@" <"$CFG_DIR/cookie" >>"$RUNSTATE/oc.log" 2>&1 &
  else
    "$@" <"$RUNSTATE/oc-creds" >>"$RUNSTATE/oc.log" 2>&1 &
  fi
  pid=$!
  printf '%s\n' "$pid" > "$RUNSTATE/oc_pid"
  chmod 644 "$RUNSTATE/oc_pid"
  ps -o lstart= -p "$pid" 2>/dev/null > "$RUNSTATE/oc_lstart" || true
  chmod 644 "$RUNSTATE/oc_lstart" 2>/dev/null || true
  UTUN=''
  VPN_IP=''
  for it in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      tail -40 "$RUNSTATE/oc.log" 2>/dev/null >&2 || true
      fail 'OpenConnect exited before the tunnel became ready.'
    fi
    # Only terminal failures may abort the start. "Login failed." and the
    # trust-check "certificate verification failed"/"signer not found" lines
    # appear on every healthy connection to multi-attempt gateways (first
    # form submission rejected, pin fallback after the system trust check).
    if grep -Eq 'Failed to complete authentication|Failed to obtain WebVPN cookie|Cookie was rejected by server|not authorized|is no longer valid|401 Unauthorized|User input required in non-interactive mode|SSL connection failure|None of the [0-9]+ fingerprint|Error in the certificate' \
       "$RUNSTATE/oc.log" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      tail -40 "$RUNSTATE/oc.log" 2>/dev/null >&2 || true
      fail 'AnyConnect authentication or TLS validation failed (see oc.log).'
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
      info "Waiting for AnyConnect tunnel ($it/40)…"
    fi
    sleep 1
  done
  [ -n "$UTUN" ] && [ -n "$VPN_IP" ] || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    tail -40 "$RUNSTATE/oc.log" 2>/dev/null >&2 || true
    fail 'OpenConnect started but no new utun IPv4 address appeared (gateway unreachable, auth, or push timeout).'
  }
  # The address appears as soon as the hook configures the utun; wait briefly
  # for the hook to finish recording routes and the readiness marker.
  ready=0
  for it in 1 2 3 4 5; do
    if [ -f "$RUNSTATE/oc-ready" ]; then ready=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  [ "$ready" = 1 ] || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    tail -40 "$RUNSTATE/oc.log" 2>/dev/null >&2 || true
    fail 'AnyConnect tunnel hook did not complete configuration.'
  }
  local conflict
  if ! conflict=$(resolve_conflicting_address "$VPN_IP" "$UTUN"); then
    [ -n "$conflict" ] || conflict=$(iface_for_address "$VPN_IP" "$UTUN" | head -n 1)
    fail "VPN address $VPN_IP is already assigned on another interface (${conflict:-unknown}); an orphaned VPN engine may hold it — stop the owning app or reboot."
  fi
  if [ -f "$RUNSTATE/oc-split" ]; then split=1; fi
  if [ "$split" = 1 ]; then
    finish_scoped_start "$default_before" split
  else
    finish_scoped_start "$default_before"
  fi
  info "Started $APP (anyconnect): $UTUN ($VPN_IP), host default $default_before unchanged."
}
# `nns-app oc-login <app>`: interactive or scripted authentication that saves
# the session cookie for later unattended use by start/restart.
oc_login() {
  local oc server proto user passwd authgroup fp tmode tsec ua output cookie tmpdir
  [ "$APP_TYPE" = anyconnect ] || fail "App '$APP' does not use an AnyConnect profile."
  [ -f "$CONF" ] || fail 'Add an AnyConnect profile first: nns-app add '"$APP"' profile.oc'
  oc=$(openconnect_bin) || fail 'Missing openconnect (brew install openconnect).'
  server=$(oc_profile_value "$CONF" server)
  proto=$(oc_profile_value "$CONF" protocol); [ -n "$proto" ] || proto=anyconnect
  user=$(oc_profile_value "$CONF" user)
  passwd=$(oc_profile_value "$CONF" passwd)
  authgroup=$(oc_profile_value "$CONF" authgroup)
  fp=$(oc_profile_value "$CONF" fingerprint)
  tmode=$(oc_profile_value "$CONF" token-mode)
  tsec=$(oc_profile_value "$CONF" token-secret)
  ua=$(oc_profile_value "$CONF" useragent)
  [ -n "$user" ] || fail "AnyConnect profile for '$APP' has no 'user=' entry; add one before oc-login."
  set -- "$oc" --authenticate --quiet --protocol "$proto" --user "$user"
  [ -z "$authgroup" ] || set -- "$@" --authgroup "$authgroup"
  [ -z "$fp" ] || set -- "$@" --servercert "$fp"
  [ -z "$tmode" ] || set -- "$@" --token-mode "$tmode"
  [ -z "$tsec" ] || set -- "$@" --token-secret "$tsec"
  [ -z "$ua" ] || set -- "$@" --useragent "$ua"
  tmpdir=''
  if grep -Eq '^[[:space:]]*<(cert|key)>[[:space:]]*$' "$CONF"; then
    tmpdir=$(mktemp -d); chmod 700 "$tmpdir"
    oc_pem_block "$CONF" cert >"$tmpdir/cert.pem"
    oc_pem_block "$CONF" key >"$tmpdir/key.pem"
    chmod 600 "$tmpdir/cert.pem" "$tmpdir/key.pem"
    set -- "$@" --certificate "$tmpdir/cert.pem" --sslkey "$tmpdir/key.pem"
  fi
  set -- "$@" "$server"
  if [ -n "$passwd" ] && { [ -z "$tmode" ] || [ -n "$tsec" ]; }; then
    output=$(printf '%s\n%s\n' "$user" "$passwd" | "$@" 2>/dev/null) || {
      [ -z "$tmpdir" ] || rm -rf "$tmpdir"
      fail 'openconnect --authenticate failed; check the credentials in the profile.'
    }
  else
    info "Authenticating to $server for '$APP'; answer the prompts shown by openconnect."
    # stderr stays attached to the terminal: openconnect prints password and
    # one-time-code prompts there.
    output=$("$@") || {
      [ -z "$tmpdir" ] || rm -rf "$tmpdir"
      fail 'openconnect --authenticate failed.'
    }
  fi
  [ -z "$tmpdir" ] || rm -rf "$tmpdir"
  cookie=$(printf '%s\n' "$output" | grep -E '^COOKIE=' | tail -n1 | cut -d= -f2-)
  # openconnect prints `COOKIE='<value>'` (single-quoted); accept both the
  # quoted and the legacy unquoted form.
  cookie=${cookie#\'}
  cookie=${cookie%\'}
  if ! printf '%s\n' "$cookie" | grep -Eq '^[A-Za-z0-9+/=_-]+$'; then
    fail 'openconnect did not return a valid session cookie.'
  fi
  [ "${#cookie}" -ge 8 ] && [ "${#cookie}" -le 4096 ] ||
    fail 'openconnect did not return a valid session cookie.'
  # Atomic replacement: an interrupted write must never leave a truncated
  # cookie for the backend to use.
  cookie_tmp="$CFG_DIR/.cookie.$$"
  if printf '%s' "$cookie" >"$cookie_tmp" &&
     chmod 600 "$cookie_tmp" &&
     mv -f "$cookie_tmp" "$CFG_DIR/cookie"; then
    :
  else
    rm -f "$cookie_tmp"
    fail 'Could not store the AnyConnect session cookie.'
  fi
  info "AnyConnect session cookie saved for '$APP'."
  info "The backend uses it until the gateway expires the session; re-authenticate with: nns-app oc-login $APP"
}
start_app() {
  require_admin
  require_profile
  # A utun lives exactly as long as the process that created it. Sweep other
  # apps' runtime state whose engine exited: their markers would otherwise
  # report a tunnel that is gone (or whose utun number was reused), and a
  # stale scoped_lan could be replayed by their cleanup.
  for stale_dir in "$USER_RUNTIME"/*; do
    [ -d "$stale_dir" ] || continue
    [ -f "$stale_dir/ready" ] || continue
    [ "$stale_dir" = "$RUNSTATE" ] && continue
    if ! engine_alive_in "$stale_dir"; then
      warn "Removing stale runtime state for '$(basename "$stale_dir")' (its VPN engine exited)."
      rm -rf -- "$stale_dir"
    fi
  done
  # This app's own state: refuse only when a LIVE engine owns it. Stale
  # markers (engine exited, or a crashed start that never reached ready) are
  # cleared here so `start` recovers the app without stop/recover first.
  if [ -e "$RUNSTATE" ]; then
    if [ -f "$RUNSTATE/ready" ] && ! app_runtime_stale; then
      fail "Runtime state exists for '$APP'; use status, stop or recover."
    fi
    warn "Clearing stale runtime state for '$APP' (its VPN engine is not running)."
    rm -rf -- "$RUNSTATE"
  fi
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
    anyconnect) start_anyconnect "$default_before" ;;
    *) start_wireguard "$default_before" ;;
  esac
  rollback=0
  trap - EXIT INT TERM
  info "Private DNS: $(selected_dns || true), split domains: $(selected_dns_domains || true) (empty DNS means no hostname lookup in compatible injected applications)."
}
stop_app() {
  require_admin
  [ -d "$RUNSTATE" ] || fail "No runtime state for '$APP'."
  cleanup_state
  info "Stopped $APP; removed only its scoped route and tunnel engine."
}
# `restart` without a name: restart every running app (macOS has no gateways).
restart_all() {
  require_admin
  local dir app
  [ -d "$APP_BASE" ] || { info 'No apps installed.'; return 0; }
  for dir in "$APP_BASE"/*; do
    [ -d "$dir" ] || continue
    app=$(basename "$dir")
    [ -d "$USER_RUNTIME/$app" ] && [ -f "$USER_RUNTIME/$app/ready" ] || continue
    info "Restarting $app."
    app_paths "$app"
    stop_app
    start_app
  done
}
run_app() {
  [ "$(id -u)" -ne 0 ] || fail 'Run apps without sudo: nns-app run <app> command.'
  ensure_engine_running
  read_runtime
  check_iface || fail "Managed interface $UTUN is absent."
  ensure_binaries
  [ "$#" -gt 0 ] || fail 'Usage: nns-app run app [--] command [args...]'
  [ "$1" != -- ] || shift
  [ "$#" -gt 0 ] || fail 'Missing command.'
  local dns domains
  dns=$(selected_dns)
  domains=$(selected_dns_domains)
  if [ -n "$dns" ]; then valid_ipv4 "$dns" || fail 'Configured DNS server is invalid.'; fi
  export NNS_DNS_IPV4="$dns" NNS_DNS_DOMAINS="$domains"
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
  ensure_engine_running
  read_runtime
  check_iface || fail "Managed interface $UTUN is absent."
  ensure_binaries
  [ "$#" -gt 0 ] || fail 'Missing command.'
  local dns domains
  dns=$(selected_dns)
  domains=$(selected_dns_domains)
  if [ -n "$dns" ]; then valid_ipv4 "$dns" || fail 'Configured DNS server is invalid.'; fi
  NNS_DNS_IPV4="$dns" NNS_DNS_DOMAINS="$domains" "$LIBEXEC/nns-run" --vpn-ip "$VPN_IP" --vpn-if "$UTUN" \
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
provider = data.get("provider")
if not isinstance(provider, str) or not provider:
    provider = "ip-api.com"
transport = "; HTTP" if provider == "ip-api.com" else ""
print("Provider:          " + provider + " (approximate location" + transport + ")")
' "$format" "$context"
}

# Probe URLs can be overridden for custom or self-hosted endpoints:
# NNS_MYLOC_URL replaces the primary, NNS_MYLOC_FALLBACK_URLS (space-separated,
# empty disables fallback) replaces the fallbacks.
myloc_urls() {
  local u
  printf '%s\n' "${NNS_MYLOC_URL:-$MYLOC_URL}"
  if [ -n "${NNS_MYLOC_FALLBACK_URLS+x}" ]; then
    # shellcheck disable=SC2086
    for u in ${NNS_MYLOC_FALLBACK_URLS:-}; do
      [ -n "$u" ] || continue
      printf '%s\n' "$u"
    done
  else
    # shellcheck disable=SC2086
    for u in $MYLOC_FALLBACK_URLS; do
      printf '%s\n' "$u"
    done
  fi
}

# The provider that last worked is remembered per egress context and tried
# first on later runs, so an unreachable primary does not cost a connect
# timeout on every invocation. Different apps exit through different VPNs,
# so the cache is keyed per app (host mode uses a single "host" entry).
# NNS_MYLOC_CACHE overrides the cache path (tests).
myloc_cache_file() {
  if [ -n "${NNS_MYLOC_CACHE:-}" ]; then
    printf '%s\n' "$NNS_MYLOC_CACHE"
    return 0
  fi
  printf '%s\n' "${HOME_DIR:-$HOME}/Library/Application Support/nns-app/myloc-providers"
}

myloc_cache_key() {
  local mode="$1" app="$2"
  if [ "$mode" = app ] && [ -n "$app" ]; then
    printf 'app:%s\n' "$app"
  else
    printf 'host\n'
  fi
}

myloc_cache_read() {
  local file="$1" key="$2" k url
  [ -f "$file" ] || return 1
  while read -r k url rest; do
    if [ "$k" = "$key" ] && [ -n "$url" ]; then
      printf '%s\n' "$url"
      return 0
    fi
  done < "$file"
  return 1
}

myloc_cache_write() {
  local file="$1" key="$2" url="$3" line tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/nns-myloc-cache.XXXXXX") || return 1
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      [ "${line%%$'\t'*}" = "$key" ] && continue
      printf '%s\n' "$line"
    done < "$file" > "$tmp"
  fi
  # Tab-separated records: keys/URLs never contain tabs.
  printf '%s\t%s\t%s\n' "$key" "$url" "$(date +%s)" >> "$tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Emit the cached provider (if any) followed by the configured providers,
# without duplicates; myloc_query tries them in this order.
myloc_query_urls() {
  local key="$1" file="$2" cached=''
  if [ -n "$file" ]; then
    cached=$(myloc_cache_read "$file" "$key" 2>/dev/null || true)
  fi
  {
    if [ -n "$cached" ]; then
      printf '%s\n' "$cached"
    fi
    myloc_urls
  } | awk 'NF && !seen[$0]++'
}

url_host_port() {
  python3 - "$1" <<'PY_URL_PARSE'
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
host = u.hostname or ""
if not host:
    sys.exit(1)
port = u.port or (443 if u.scheme == "https" else 80)
sys.stdout.write("%s:%d" % (host, port))
PY_URL_PARSE
}

# Normalize a provider response onto the ip-api.com field shape and record
# the originating provider. Exit 0 with normalized JSON on success, exit 1
# with the provider's failure message, exit 2 on an unparseable response.
myloc_normalize() {
  python3 - "$1" "$2" <<'PY_MYLOC_NORM'
import json
import sys
from urllib.parse import urlparse

host = (urlparse(sys.argv[1]).hostname or "").lower()
try:
    data = json.loads(sys.argv[2])
except (ValueError, UnicodeError):
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)

if host.endswith("ipwho.is"):
    ok = data.get("success") is True
    conn = data.get("connection")
    conn = conn if isinstance(conn, dict) else {}
    tz = data.get("timezone")
    tz = tz if isinstance(tz, dict) else {}
    asn = ""
    if conn.get("asn"):
        asn = "AS%d" % conn["asn"]
        if conn.get("org"):
            asn += " " + str(conn["org"])
    out = {
        "status": "success" if ok else "fail",
        "message": "" if ok else str(data.get("message") or "unknown"),
        "query": data.get("ip"),
        "country": data.get("country"),
        "countryCode": data.get("country_code"),
        "regionName": data.get("region"),
        "city": data.get("city"),
        "zip": data.get("postal"),
        "lat": data.get("latitude"),
        "lon": data.get("longitude"),
        "timezone": tz.get("id"),
        "isp": conn.get("isp"),
        "org": conn.get("org"),
        "as": asn or None,
        "provider": "ipwho.is",
    }
else:
    # ip-api.com and any user-supplied ip-api-compatible endpoint pass through.
    out = dict(data)
    out["provider"] = host or "custom"

if out.get("status") == "success" and isinstance(out.get("query"), str) and out["query"]:
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)
print(str(out.get("message") or "unknown"))
sys.exit(1)
PY_MYLOC_NORM
}

myloc_query() {
  local mode="$1" app="$2" curl_bin key file url host_port probe_ip json answer last_msg='' last_err='' errfile
  curl_bin=$(homebrew_curl) || fail 'Homebrew curl required (brew install curl).'
  key=$(myloc_cache_key "$mode" "${app:-}")
  file=$(myloc_cache_file)
  errfile=$(mktemp "${TMPDIR:-/tmp}/nns-myloc.XXXXXX") || return 1
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    local -a cmd=("$curl_bin" -4fsS --noproxy '*' --connect-timeout 3 --max-time 10)
    if [ "$mode" = app ]; then
      host_port=$(url_host_port "$url") || { last_msg='Cannot parse the geolocation probe URL.'; continue; }
      probe_ip=$(resolve_host_ipv4 "${host_port%%:*}") ||
        { last_msg="Cannot resolve ${host_port%%:*} via host DNS."; continue; }
      cmd+=(--resolve "$host_port:$probe_ip")
    fi
    cmd+=("$url")
    if [ "$mode" = app ]; then
      json=$(run_app_output "${cmd[@]}" 2>"$errfile") || {
        last_err=$(cat "$errfile")
        continue
      }
    else
      json=$("${cmd[@]}" 2>"$errfile") || {
        last_err=$(cat "$errfile")
        continue
      }
    fi
    [ -n "$json" ] || continue
    if answer=$(myloc_normalize "$url" "$json"); then
      rm -f "$errfile"
      case "$file" in
        */*) mkdir -p "${file%/*}" 2>/dev/null || true ;;
      esac
      myloc_cache_write "$file" "$key" "$url" 2>/dev/null || true
      printf '%s\n' "$answer"
      return 0
    fi
    [ -z "$answer" ] || last_msg=$answer
  done < <(myloc_query_urls "$key" "$file")
  rm -f "$errfile"
  [ -z "$last_err" ] || printf '%s\n' "$last_err" >&2
  [ -z "$last_msg" ] || printf 'myloc: last provider error: %s\n' "$last_msg" >&2
  return 1
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
  json=$(myloc_query "$mode" "${APP:-}") ||
    fail "IP geolocation unavailable from '$context' (no Internet egress through this profile, DNS/API, or rate limit)."
  printf '%s\n' "$json" | myloc_format "$format" "$context"
}
status_app() {
  if [ ! -f "$RUNSTATE/ready" ]; then
    info "$APP: stopped (type=$(app_type_label), configured profile: $([ -f "$CONF" ] && echo yes || echo no))"
    return 0
  fi
  if app_runtime_stale; then
    info "$APP: STALE (the VPN engine exited; its tunnel is gone). Run: sudo nns-app restart $APP"
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
  # A split-tunnel AnyConnect session intentionally has no scoped default
  # route; its scoped_lan entries carry the pushed routes instead.
  if [ -f "$RUNSTATE/scoped_route" ]; then
    info '  scoped route marker: present'
  elif [ -f "$RUNSTATE/oc-split" ]; then
    info '  scoped route marker: n/a (split tunnel; scoped LAN routes only)'
  else
    info '  scoped route marker: missing'
  fi
  info "  private DNS: $(selected_dns || true), split domains: $(selected_dns_domains || true)"
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
      if ! app_runtime_stale; then
        status=started
        tun='-'
        vpn_ip='-'
        [ ! -f "$RUNSTATE/utun" ] || tun=$(cat "$RUNSTATE/utun")
        [ ! -f "$RUNSTATE/vpn_ip" ] || vpn_ip=$(cat "$RUNSTATE/vpn_ip")
        online="profile | $vpn_ip ($tun)"
      else
        status=stale
        online='profile | engine exited (restart to recover)'
      fi
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
nns-app $VERSION macOS (experimental IPv4 WireGuard/OpenVPN/AnyConnect client)
  nns-app install <name>                 Create app configuration
  nns-app add <name> <profile.conf|.ovpn|.oc>
                                         Import WireGuard (.conf), OpenVPN (.ovpn)
                                         or AnyConnect/OpenConnect (.oc)
  nns-app dns <name> <IPv4|off>          Override private per-app DNS (no host DNS changes)
  nns-app oc-login <name>                Authenticate AnyConnect and save the session cookie
  sudo nns-app start <name>              Start tunnel (wireguard-go, openvpn or openconnect) + scoped utun
  sudo nns-app restart [<name>]          Stop (if running) and start again; no name restarts all running apps
  nns-app run <name> [--] command...     Run command; auto-bind SIP tools (ping/nc/ssh/curl/wget/…)
  nns-app status <name> | list [apps]
  sudo nns-app stop <name>               Stop tunnel and remove scoped route
  sudo nns-app recover <name>            Cleanup interrupted tunnel start/stop
  nns-app remove <name>                  Remove stopped app profile
  nns-app git-via <name|->               Set/restore repository SSH transport
  nns-app myip [<name>]                  Probe public IP (host, or app via tunnel)
  nns-app myloc [<name>] [--json]        Geolocate host or app egress (ip-api.com or ipwho.is)
  nns-app --version

OpenVPN on macOS uses --route-noexec (host default unchanged). Profiles must be
self-contained (inline certs/keys); up/down scripts are rejected.

AnyConnect profiles are nns-app key=value files (.oc) with server=, user=,
passwd=, authgroup=, token-mode=/token-secret=, optional inline <cert>/<key>
blocks, and route-mode=split|full. openconnect's vpnc-script is replaced by a
nns-app hook, so host DNS, PF and the host default route stay untouched.

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
  # start/stop/recover manage kernel interfaces and must run as root. Re-exec
  # with sudo automatically instead of failing with an instruction; after the
  # elevation SUDO_USER still identifies the owning account.
  case "$cmd" in
    start|stop|restart|recover)
      if [ "$(id -u)" -ne 0 ]; then
        exec /usr/bin/sudo "$SELF" "$cmd" "$@"
      fi
      ;;
  esac
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
      [ "$#" -eq 2 ] || fail 'Usage: nns-app add <name> <profile.conf|.ovpn|.oc>'
      [ "$(id -u)" -ne 0 ] || fail 'Run nns-app add without sudo.'
      app_paths "$1"; [ -d "$CFG_DIR" ] || fail "First run nns-app install $APP."
      [ ! -e "$RUNSTATE" ] || fail 'Stop the app before replacing its profile.'
      [ -r "$2" ] || fail 'Cannot read profile.'
      local kind hook_dns='' hook_domains='' hook_info previous_conf err dest
      kind=$(detect_profile_kind "$2")
      cp -- "$2" "$CFG_DIR/.incoming"; chmod 600 "$CFG_DIR/.incoming"
      case "$kind" in
        openvpn)
          if ! hook_info=$(normalize_ovpn_profile "$CFG_DIR/.incoming" 2>"$CFG_DIR/.hook-err"); then
            err=$(cat "$CFG_DIR/.hook-err" 2>/dev/null || true)
            rm -f "$CFG_DIR/.incoming" "$CFG_DIR/.hook-err"
            fail "${err:-Cannot import OpenVPN profile.}"
          fi
          hook_dns=${hook_info%%|*}
          hook_domains=${hook_info#*|}
          rm -f "$CFG_DIR/.hook-err"
          dest="$CFG_DIR/profile.ovpn"
          rm -f "$CFG_DIR/profile.conf" "$CFG_DIR/profile.oc" "$CFG_DIR/cookie"
          mv -f "$CFG_DIR/.incoming" "$dest"
          printf 'openvpn\n' > "$TYPE_FILE"
          chmod 600 "$dest" "$TYPE_FILE"
          if [ -n "$hook_dns" ]; then
            printf '%s\n' "$hook_dns" > "$CFG_DIR/dns_ipv4"
            chmod 600 "$CFG_DIR/dns_ipv4"
          else
            rm -f "$CFG_DIR/dns_ipv4"
          fi
          if [ -n "$hook_domains" ]; then
            printf '%s\n' "$hook_domains" > "$CFG_DIR/dns_domains"
            chmod 600 "$CFG_DIR/dns_domains"
          else
            rm -f "$CFG_DIR/dns_domains"
          fi
          if [ -n "$hook_dns" ] || [ -n "$hook_domains" ]; then
            info "Imported OpenVPN profile into $APP (DNS ${hook_dns:-none}, split domains ${hook_domains:-none}; scripts not executed)."
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
          rm -f "$CFG_DIR/profile.ovpn" "$CFG_DIR/profile.oc" "$CFG_DIR/cookie"
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
        anyconnect)
          if ! normalize_oc_profile "$CFG_DIR/.incoming" 2>"$CFG_DIR/.hook-err"; then
            err=$(cat "$CFG_DIR/.hook-err" 2>/dev/null || true)
            rm -f "$CFG_DIR/.incoming" "$CFG_DIR/.hook-err"
            fail "${err:-Cannot import AnyConnect profile.}"
          fi
          rm -f "$CFG_DIR/.hook-err"
          dest="$CFG_DIR/profile.oc"
          rm -f "$CFG_DIR/profile.conf" "$CFG_DIR/profile.ovpn"
          mv -f "$CFG_DIR/.incoming" "$dest"
          printf 'anyconnect\n' > "$TYPE_FILE"
          chmod 600 "$dest" "$TYPE_FILE"
          # A replaced profile targets a possibly different gateway, and its
          # DNS override comes from the previous backend.
          rm -f "$CFG_DIR/cookie" "$CFG_DIR/dns_ipv4" "$CFG_DIR/dns_domains"
          oc_dns_key=$(oc_profile_value "$dest" dns)
          if [ -n "$oc_dns_key" ]; then
            printf '%s\n' "$oc_dns_key" >"$CFG_DIR/dns_ipv4"
            chmod 600 "$CFG_DIR/dns_ipv4"
          fi
          if grep -Eq '^[[:space:]]*(user|passwd|password|token-secret)[[:space:]]*=' "$dest"; then
            info "Imported AnyConnect profile into $APP (inline credentials; DNS is pushed by the gateway at connect time)."
          else
            info "Imported AnyConnect profile into $APP (no inline credentials; run: nns-app oc-login $APP)."
          fi
          # OpenConnect is not installed by install_macos; say so up front
          # when the backend binary is missing (start would fail anyway).
          if ! openconnect_bin >/dev/null 2>&1; then
            warn "openconnect is not installed; the AnyConnect backend needs it. Install it with: brew install openconnect"
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
    oc-login)
      [ "$#" -eq 1 ] || fail 'Usage: nns-app oc-login <name>'
      [ "$(id -u)" -ne 0 ] || fail 'Run nns-app oc-login without sudo.'
      app_paths "$1"; [ -d "$CFG_DIR" ] || fail 'App not installed.'
      oc_login
      ;;
    start)
      [ "$#" -eq 1 ] || fail 'Usage: sudo nns-app start <name>'
      app_paths "$1"; start_app
      ;;
    restart)
      if [ "$#" -eq 0 ]; then
        restart_all
      else
        [ "$#" -eq 1 ] || fail 'Usage: sudo nns-app restart [<name>]'
        app_paths "$1"
        if [ -d "$RUNSTATE" ]; then
          stop_app
        else
          info "App '$APP' is not running; starting fresh."
        fi
        start_app
      fi
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
