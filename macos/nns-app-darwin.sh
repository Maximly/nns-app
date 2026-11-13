#!/bin/bash
# nns-app 2.1.0 -- macOS WireGuard backend (IPv4 TCP, opt-in per-process routing).
# Unlike the Linux backend: no netns, PF, user/group changes or host DNS edits.
# The only kernel networking additions are one utun and its -ifscope route.
set -euo pipefail
umask 077
PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:/opt/homebrew/bin:/usr/local/bin"
export PATH
VERSION=2.1.0
SELF=$0
STATE_BASE=/var/run/nns-app-macos
LIBEXEC=/usr/local/libexec/nns-app
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
  CONF="$CFG_DIR/profile.conf"
  RUNSTATE="$USER_RUNTIME/$APP"
}
require_profile() { [ -f "$CONF" ] || fail "Profile not installed for '$APP'; use nns-app add $APP profile.conf."; }
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
  elif [ -f "$CONF" ]; then
    profile_dns
  fi
}
ensure_binaries() {
  [ -x "$LIBEXEC/nns-run" ] && [ -r "$LIBEXEC/libnnsbind.dylib" ] ||
    fail 'C tools missing; run ./build.sh && sudo ./install_macos.'
}
# Strictly delete the route we created, not routes owned by another service.
remove_scoped_route() {
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
cleanup_state() {
  # Must remove the route before terminating wireguard-go's utun descriptor.
  remove_scoped_route
  if [ -s "$RUNSTATE/wg_pid" ]; then
    local pid
    pid=$(cat "$RUNSTATE/wg_pid")
    case "$pid" in ''|*[!0-9]*) fail 'Invalid engine PID.';; esac
    # Never kill a reused PID if it is not our type of wireguard-go engine.
    if ps -p "$pid" -o command= 2>/dev/null | grep -E -q 'wireguard-go.*-f[[:space:]]+utun'; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf -- "$RUNSTATE"
}
start_app() {
  require_admin
  require_profile
  reject_hooks
  [ ! -e "$RUNSTATE" ] || fail "Runtime state exists for '$APP'; use status, stop or recover."
  ensure_binaries
  command -v wireguard-go >/dev/null 2>&1 || fail 'Missing wireguard-go (brew install wireguard-go wireguard-tools).'
  command -v wg >/dev/null 2>&1 || fail 'Missing wg (brew install wireguard-tools).'
  command -v wg-quick >/dev/null 2>&1 || fail 'Missing wg-quick (brew install wireguard-tools).'
  profile_ip
  local expected default_before pid it ready=0 other
  default_before=$(default_if)
  [ -n "$default_before" ] || fail 'No physical default route detected.'
  case "$default_before" in utun*) fail 'Host default is a VPN; disconnect full-tunnel VPN before starting nns-app.';; esac
  # Never reuse an IP already present on *any* system interface: macOS
  # has a single global network stack, even if the interface route is scoped.
  if ifconfig -a | awk -v ip="$VPN_IP" '$1=="inet" && $2==ip {found=1} END {exit !found}'; then
    fail "VPN address $VPN_IP is already assigned on this Mac; refusing to interfere with an existing tunnel."
  fi
  for other in "$USER_RUNTIME"/*; do
    [ -f "$other/ready" ] || continue
    if [ "$(cat "$other/vpn_ip")" = "$VPN_IP" ]; then
      fail "VPN address $VPN_IP is already used by another managed tunnel."
    fi
  done
  mkdir -p "$USER_RUNTIME"; chmod 755 "$STATE_BASE" "$USER_RUNTIME"
  mkdir "$RUNSTATE"; chmod 755 "$RUNSTATE"
  printf '%s\n' "$UID_NUM" > "$RUNSTATE/owner_uid"
  printf '%s\n' "$VPN_IP" > "$RUNSTATE/vpn_ip"
  printf '%s\n' "$default_before" > "$RUNSTATE/phy"
  chmod 644 "$RUNSTATE/owner_uid" "$RUNSTATE/vpn_ip" "$RUNSTATE/phy"
  local rollback=1
  trap 'if [ "${rollback:-0}" -eq 1 ]; then echo "Rolling back incomplete tunnel setup" >&2; cleanup_state || true; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
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
  printf '%s\n' "$UTUN" > "$RUNSTATE/utun"; chmod 644 "$RUNSTATE/utun"
  for it in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if wg show "$UTUN" >/dev/null 2>&1; then ready=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  [ "$ready" = 1 ] || fail 'WireGuard control socket failed to become ready.'
  wg-quick strip "$CONF" | wg setconf "$UTUN" /dev/stdin || fail 'WireGuard profile configuration failed.'
  ifconfig "$UTUN" inet "$VPN_IP/32" "$VPN_IP" alias || fail 'Cannot assign tunnel IP.'
  ifconfig "$UTUN" mtu 1420 up || fail 'Cannot enable utun.'
  # Only scoped routing: do not change the unscoped host default or per-destination routes.
  route -q -n add -ifscope "$UTUN" -inet default -interface "$UTUN" || fail 'Unable to install interface-scoped route.'
  printf '%s\n' "$UTUN" > "$RUNSTATE/scoped_route"; chmod 644 "$RUNSTATE/scoped_route"
  [ "$(default_if)" = "$default_before" ] || fail 'Host default interface changed; aborting.'
  touch "$RUNSTATE/ready"; chmod 644 "$RUNSTATE/ready"
  rollback=0
  trap - EXIT INT TERM
  info "Started $APP: $UTUN ($VPN_IP), host default $default_before unchanged."
  info "Private DNS: $(selected_dns || true) (empty means no hostname lookup in compatible injected applications)."
}
stop_app() {
  require_admin
  [ -d "$RUNSTATE" ] || fail "No runtime state for '$APP'."
  cleanup_state
  info "Stopped $APP; removed only its scoped route and WireGuard engine."
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
status_app() {
  if [ ! -f "$RUNSTATE/ready" ]; then
    info "$APP: stopped (configured profile: $([ -f "$CONF" ] && echo yes || echo no))"
    return 0
  fi
  read_runtime
  info "$APP: started; $UTUN $VPN_IP, host default: $(default_if), originally: $PHY"
  if check_iface; then
    info '  interface: online'
  else
    info '  interface: MISSING -- run sudo nns-app recover app'
  fi
  info "  scoped route marker: $([ -f "$RUNSTATE/scoped_route" ] && echo present || echo missing)"
  info "  private DNS: $(selected_dns || true)"
  if [ "$(id -u)" -eq 0 ]; then wg show "$UTUN" latest-handshakes 2>/dev/null || true; fi
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
      "$app" 'vpn-client/wg' "$status" 'host' "$online" 'local'
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
  num=$(git config --local --get-all core.sshCommand 2>/dev/null | wc -l | tr -d ' ')
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
  cat <<'USAGE'
nns-app 2.1.0 macOS (experimental IPv4 TCP WireGuard backend)
  nns-app install <name>               Create app configuration
  nns-app add <name> <profile.conf>    Import a WireGuard client profile
  nns-app dns <name> <IPv4|off>        Override private per-app DNS (no host DNS changes)
  sudo nns-app start <name>            Start wireguard-go and owned utun
  nns-app run <name> [--] command...   Run compatible binary with tunnel source binding
  nns-app status <name> | list [apps]
  sudo nns-app stop <name>             Stop tunnel and remove scoped route
  sudo nns-app recover <name>          Cleanup interrupted tunnel start/stop
  nns-app remove <name>               Remove stopped app profile
  nns-app git-via <name|->             Set/restore repository SSH transport
  nns-app myip <name>                  Probe public IP (requires full-tunnel AllowedIPs)
  nns-app --version

NOT supported on macOS: OpenVPN, AmneziaWG, namespace inheritance, gateway/
server, remote orchestration, arbitrary socket isolation, IPv6, UDP apps.
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
      info "Installed app configuration '$APP' (macOS WireGuard)."
      ;;
    add)
      [ "$#" -eq 2 ] || fail 'Usage: nns-app add <name> <profile.conf>'
      [ "$(id -u)" -ne 0 ] || fail 'Run nns-app add without sudo.'
      app_paths "$1"; [ -d "$CFG_DIR" ] || fail "First run nns-app install $APP."
      [ ! -e "$RUNSTATE" ] || fail 'Stop the app before replacing its profile.'
      [ -r "$2" ] || fail 'Cannot read profile.'
      case "$2" in *.conf) ;; *) fail 'Only WireGuard .conf profiles supported on macOS.';; esac
      cp -- "$2" "$CFG_DIR/.incoming"; chmod 600 "$CFG_DIR/.incoming"
      local hook_dns='' previous_conf err
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
      mv -f "$CFG_DIR/.incoming" "$CONF"
      if [ -n "$hook_dns" ]; then
        printf '%s\n' "$hook_dns" > "$CFG_DIR/dns_ipv4"
        chmod 600 "$CFG_DIR/dns_ipv4"
        info "Imported WireGuard profile into $APP (IP $VPN_IP, DNS $hook_dns from resolvectl hooks; hooks not executed)."
      else
        info "Imported WireGuard profile into $APP (IP $VPN_IP)."
      fi
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
      [ "$#" -eq 1 ] || fail 'Usage: nns-app myip <name>'
      app_paths "$1"; require_profile
      local curl_bin=''
      for curl_bin in /opt/homebrew/opt/curl/bin/curl /usr/local/opt/curl/bin/curl; do
        [ ! -x "$curl_bin" ] || break
      done
      [ -x "$curl_bin" ] || fail 'Homebrew curl required (brew install curl).'
      run_app "$curl_bin" -4 -fSs --connect-timeout 8 --max-time 15 https://api.ipify.org
      ;;
    *) fail "Command '$cmd' is not implemented on macOS 2.1.0. See README compatibility table.";;
  esac
}
if [ "$(basename "$0")" = git-via ]; then
  # Reuse the public executable for repository SSH transport switching.
  main git-via "$@"
else
  main "$@"
fi
