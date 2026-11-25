#!/usr/bin/env bash
# TP-Link SG management CLI. Authentication reused from the AX80-tested probe.
# Update payload structure: TP-Link-Archer-C6U, client/c6u.py (public reference).
set -euo pipefail
set +x
export LC_ALL=C
umask 077
usage() { cat <<'EOF'
tplink-ctl.sh v0.1.18 — TP-Link SG / classic LuCI; experimental MER read-only
Usage: tplink-ctl.sh [options] COMMAND [arguments]
  probe                    Pre-login firmware/API diagnostics (no password)
  collect-mer              Archive MER manifests and prioritized login/device scripts
  collect-vpn              Collect static VPN frontend resources (read-only)
  info                     Router and VPN capabilities
  list                     VPN profiles
  status [PROFILE]         VPN state and profile status
  devices                  Connected devices and VPN whitelist
  start PROFILE            Enable an existing VPN profile
  stop PROFILE             Disable an existing VPN profile
  remove PROFILE           Delete a disabled VPN profile
  attach PROFILE DEVICE    Add a disabled global VPN device entry
  remove PROFILE DEVICE    Delete a disconnected global VPN device entry
  connect PROFILE DEVICE   Enable VPN access for an attached device
  disconnect PROFILE DEVICE Disable VPN access without deleting the entry
  bind [PROFILE] DEVICE    Alias for connect (legacy MAC-only form also accepted)
  unbind [PROFILE] DEVICE  Alias for disconnect (legacy MAC-only form also accepted)
                           DEVICE: exact name, IPv4 address, or MAC address
                           Named profile must be the sole enabled VPN profile.
  enable | disable         Toggle the global VPN client subsystem
  inspect                  Show API field names (not values) for investigation
  add NAME FILE            Import .ovpn or WireGuard .conf (SG firmware; disabled)
Options (before or after command):
  --router HOST            Default: system IPv4 gateway
  --insecure               Accept untrusted TLS certificate (default; trusted LAN only)
  --secure                 Require a trusted TLS certificate
  --cacert FILE            Verify with supplied CA certificate
  --pinnedpubkey PIN       Verify pinned public key (sha256//... or PEM file)
  --auth auto|sg|classic|mer  Auto selects certified SG, known classic key sizes, or MER
  --user USER              Local username (default admin)
  --password PASSWORD      Skip password prompt (visible in process args/history)
  --verbose                Show authentication and API diagnostics
  --dry-run                Read state and describe writes without applying
  --switch                 Allow start to replace another active profile
  --json                   JSON output for read commands
  --help | --version
Password is prompted once unless --password is supplied. No credentials stored.
Default TLS mode accepts untrusted certificates; MER uses HTTP. Trusted LAN only.
EOF
}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
router=''; user=admin; auth_mode=auto; tls=(); insecure=yes; pinned=no; dry=no; switch=no; json=no; verbose=no; supplied_password=no; password=''; args=()
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0;;
    --version) echo 'tplink-ctl 0.1.18'; exit 0;;
    --insecure) insecure=yes; shift;;
    --secure) insecure=no; shift;;
    --cacert|--pinnedpubkey) (( $# >= 2 )) || fail "Missing argument for $1"; tls+=("$1" "$2"); if [[ $1 == --pinnedpubkey ]]; then pinned=yes; else insecure=no; fi; shift 2;;
    --router|--user) (( $# >= 2 )) || fail "Missing argument for $1"; if [[ $1 == --router ]]; then router=$2; else user=$2; fi; shift 2;;
    --auth) (( $# >= 2 )) || fail "Missing authentication mode"; case "$2" in auto|sg|classic|mer) auth_mode=$2;; *) fail "Unknown authentication mode: $2";; esac; shift 2;;
    --dry-run) dry=yes; shift;;
    --switch) switch=yes; shift;;
    --experimental) shift;; # legacy compatibility; no longer required
    --json) json=yes; shift;;
    --verbose|-v) verbose=yes; shift;;
    --password) (( $# >= 2 )) || fail "Missing password argument"; password=$2; supplied_password=yes; shift 2;;
    --password=*) password=${1#*=}; supplied_password=yes; shift;;
    --) shift; while (( $# )); do args+=("$1"); shift; done;;
    -*) fail "Unknown option: $1";;
    *) args+=("$1"); shift;;
  esac
done
if [[ $insecure == yes ]]; then tls+=(-k); fi
(( ${#args[@]} )) || { usage; exit 0; }
cmd=${args[0]}; argc=$(( ${#args[@]} - 1 )); arg1=${args[1]-}; arg2=${args[2]-}
case "$cmd" in
  probe|collect-mer|collect-vpn|info|list|devices|inspect|enable|disable) (( argc == 0 )) || fail "$cmd takes no arguments";;
  status) (( argc <= 1 )) || fail 'status [PROFILE]';;
  start|stop) (( argc == 1 )) && [[ -n $arg1 ]] || fail "$cmd PROFILE";;
  attach|connect|disconnect) (( argc == 2 )) && [[ -n $arg1 && -n $arg2 ]] || fail "$cmd PROFILE DEVICE";;
  remove) (( argc == 1 || argc == 2 )) && [[ -n $arg1 ]] && { (( argc == 1 )) || [[ -n $arg2 ]]; } || fail 'remove PROFILE [DEVICE]';;
  bind|unbind) (( argc == 1 || argc == 2 )) && [[ -n $arg1 ]] && { (( argc == 1 )) || [[ -n $arg2 ]]; } || fail "$cmd [PROFILE] DEVICE";;
  add) (( argc == 2 )) && [[ -n $arg1 && -n $arg2 ]] || fail 'add NAME FILE'; [[ -f $arg2 && -r $arg2 && -s $arg2 ]] || fail 'VPN file missing, unreadable or empty'; case "$arg2" in *.ovpn|*.conf) ;; *) fail 'Use an .ovpn or WireGuard .conf file';; esac;;
  *) fail "Unknown command: $cmd (see --help)";;
esac
for dependency in curl jq openssl od tr awk mktemp; do command -v "$dependency" >/dev/null || fail "Missing $dependency"; done
if [[ -z $router ]]; then
  if [[ $(uname -s) == Darwin ]]; then router=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'); else router=$(ip -4 route show default | awk '/via/{print $3; exit}'); fi
fi
[[ $router =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || fail 'Specify a router IPv4 address or hostname'
base="https://$router"; api="$base/cgi-bin/luci/;stok="
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tplink-sg.XXXXXXXX")
chmod 700 "$tmp"
stok=''; key=''; iv=''; seq=''; success=0; errors=0
# Keep normal output clean while retaining diagnostics on failure.
exec 3>&2
quiet_output=no
if [[ $verbose == no ]]; then
  quiet_output=yes
  exec 2>"$tmp/diagnostics"
fi
get_password() {
  if [[ $supplied_password == no ]]; then
    [[ -t 0 ]] || fail 'Interactive terminal required for password (or use --password)'
    printf 'Router password: ' >&3
    IFS= read -r -s password || fail 'Password input failed'
    printf '\n' >&3
  fi
  [[ -n $password ]] || fail 'Empty password'
}
# Normalized presentation shared by all info backends.
render_info() {
  if [[ $json == yes ]]; then jq .; return; fi
  jq -r '
    def clean: tostring | gsub("[[:cntrl:]]"; "");
    def line($name;$value): if $value==null or $value=="" then empty else "\($name):" + (" " * (23-($name|length))) + ($value|clean) end;
    def pct: if type=="number" then ((.*1000|round)/10|tostring)+"%" else . end;
    def protocols: if type=="array" then if length==0 then "None advertised" else map(if .=="wireguard" then "WireGuard" elif .=="openvpn" then "OpenVPN" elif .=="pptpvpn" then "PPTP" elif .=="l2tpvpn" then "L2TP" else . end)|join(", ") end else "Not confirmed" end;
    def enabled: if .=="on" then "Enabled" elif .=="off" then "Disabled" else . end;
    "TP-Link Router", "",
    line("Address";.address), line("Model";.model//"Unknown"), line("Hardware";.hardware_version), line("Firmware";.firmware_version),
    line("Backend";.authentication), line("CPU usage";(.cpu_usage|pct)), line("Memory usage";(.mem_usage|pct)),
    line("VPN client";(.vpn_client|protocols)), line("VPN server";(.vpn_server|protocols)),
    line("VPN kill switch";(if .kill_switch_supported==true then "Supported" elif .kill_switch_supported==false then "Not supported" else null end)),
    line("VPN client state";(.global_enable|enabled)), line("VPN profiles";.profile_count), line("VPN device policies";.policy_count),
    line("VPN management";.vpn_management)
  '
}
# Shared presentation helpers; JSON mode emits only machine-readable results.
render_table() {
  awk -F '\t' '{n=NF>n?NF:n; for(i=1;i<=NF;i++){a[NR,i]=$i; if(length($i)>w[i])w[i]=length($i)}} END {for(r=1;r<=NR;r++){for(i=1;i<=n;i++){if(i<n)printf "%-*s  ",w[i],a[r,i];else printf "%s",a[r,i]}printf "\n"}}'
}
render_profiles() {
  if [[ $json == yes ]]; then jq .; return; fi
  local data; data=$(cat)
  printf 'VPN profiles (%s)\n\n' "$(printf %s "$data" | jq length)"
  if [[ $(printf %s "$data" | jq length) == 0 ]]; then printf "No VPN profiles configured.\n"; return; fi
  printf %s "$data" | jq -r '(["NAME","PROTOCOL","ENABLED","STATUS","ID"]|@tsv),(.[]|[.name,.protocol,.enabled,.status,.id]|map((.//"-")|tostring|gsub("[[:cntrl:]]";" "))|@tsv)' | render_table
}
render_status() {
  if [[ $json == yes ]]; then jq .; return; fi
  local data; data=$(cat)
  printf 'VPN client: %s\n\n' "$(printf %s "$data" | jq -r '.global_enable|if .=="on" then "Enabled" elif .=="off" then "Disabled" else "Unknown" end')"
  printf %s "$data" | jq '.profiles' | render_profiles
}
render_devices() {
  if [[ $json == yes ]]; then jq .; return; fi
  local data group title count
  data=$(cat)
  printf 'Connected devices — %s\n' "$router"
  for group in wired wifi guest vpn_whitelist; do
    case "$group" in wired) title='Wired';; wifi) title='Wi-Fi';; guest) title='Guest';; vpn_whitelist) title='VPN device policies';; esac
    count=$(printf %s "$data" | jq -r --arg g "$group" '.[$g]|if type=="array" then length else "unavailable" end')
    printf '\n%s (%s)\n' "$title" "$count"
    [[ $count != unavailable && $count != 0 ]] || continue
    if [[ $group == vpn_whitelist ]]; then
      printf %s "$data" | jq -r '(["NAME","MAC ADDRESS","VPN ACCESS","TYPE"]|@tsv),(.vpn_whitelist[]|[.name,.mac,.access,.client_type]|map((.//"-")|tostring|gsub("[[:cntrl:]]";" "))|@tsv)' | render_table
    else
      printf %s "$data" | jq -r --arg g "$group" '(["NAME","IP ADDRESS","MAC ADDRESS"]|@tsv),(.[$g][]|[.name,.ip,.mac]|map((.//"-")|tostring|gsub("[[:cntrl:]]";" "))|@tsv)' | render_table
    fi
  done
}
render_fields() {
  if [[ $json == yes ]]; then jq .; return; fi
  jq -r 'to_entries[] | (.key|gsub("_";" ")|ascii_upcase) + ": " + (.value|if .==null then "Unavailable" elif type=="array" then map(tostring)|join(", ") else tostring end | gsub("[[:cntrl:]]";" "))'
}
render_action() {
  if [[ $json == yes ]]; then jq .; return; fi
  render_fields
}
action_notice() { printf '%s\n' "$*" >&3; }
# MER stores URL-encoded display strings; decode only allowlisted info fields.
uri_decode() {
  local rest=$1 result='' byte
  while [[ $rest == *%* ]]; do
    result+=${rest%%\%*}; rest=${rest#*%}
    if [[ ${rest:0:2} =~ ^[0-9A-Fa-f]{2}$ && ${rest:0:2} != 00 ]]; then
      printf -v byte '%b' "\\x${rest:0:2}"; result+=$byte; rest=${rest:2}
    else result+='%'; fi
  done
  printf '%s' "$result$rest"
}
hex() { od -An -v -tx1 | tr -d ' \n'; }
sha() { openssl dgst -sha256 -binary | hex; }
md5hex() { openssl dgst -md5 -binary | hex; }
# Pipe data to curl so credentials, ciphertext and signatures are not in argv.
post() {
  local url=$1; shift
  curl -q -sS --noproxy '*' --proto '=https' --connect-timeout 4 --max-time 12 \
    "${tls[@]+${tls[@]}}" -b "$tmp/cookies" -c "$tmp/cookies" \
    -H 'Content-Type: application/x-www-form-urlencoded' -H "Referer: $base/webpages/index.html" \
    -H "Origin: $base" --data-binary @- "$@" "$url"
}
# Build a PKCS#1 public key from the router's hexadecimal modulus and exponent.
make_pub() {
  local n=$1 e=$2 dest=$3
  [[ $n =~ ^[0-9a-fA-F]+$ && $e =~ ^[0-9a-fA-F]+$ ]] || return 1
  (( ${#n} >= 128 && ${#n} <= 2048 && ${#n} % 2 == 0 && ${#e} <= 16 )) || return 1
  printf 'asn1=SEQUENCE:pub\n[pub]\nn=INTEGER:0x%s\ne=INTEGER:0x%s\n' "$n" "$e" > "$tmp/asn1"
  openssl asn1parse -genconf "$tmp/asn1" -noout -out "$tmp/pub.der" &&
    openssl rsa -RSAPublicKey_in -inform DER -in "$tmp/pub.der" -pubout -out "$dest" 2>/dev/null
}
rsa() { openssl pkeyutl -encrypt -pubin -inkey "$1" -pkeyopt "rsa_padding_mode:$2" | hex; }
# Generate 16 independent decimal digits as used by TP-Link's web client.
digits() { local x; x=$(openssl rand -hex 32) || return 1; x=$(printf %s "$x" | tr -cd '0-9'); while (( ${#x} < 16 )); do x+=$(openssl rand -hex 16 | tr -cd '0-9'); done; printf %.16s "$x"; }
enc() { openssl enc -aes-128-cbc -K "$keyhex" -iv "$ivhex" -nosalt -base64 -A; }
dec() { openssl enc -d -aes-128-cbc -K "$keyhex" -iv "$ivhex" -nosalt -base64 -A; }
body() { local escaped; escaped=$(printf %s "$2" | jq -sRr @uri) || return 1; printf 'sign=%s&data=%s' "$1" "$escaped"; }
unwrap() {
  local raw=$1 data
  data=$(printf %s "$raw" | jq -er '.data | select(type=="string")') || return 1
  printf %s "$data" | dec | jq -ce .
}
request() {
  local path=$1 plain=$2 cipher hash signstr sign='' chunk part raw i
  cipher=$(printf %s "$plain" | enc) || return 1
  if [[ $auth_mode == classic ]]; then hash=$credential_hash; else hash=$(printf %s "$cipher" | sha) || return 1; fi
  signstr="h=$hash&s=$((seq + ${#cipher}))"
  for ((i=0;i<${#signstr};i+=53)); do
    chunk=${signstr:i:53}
    if [[ $auth_mode == classic ]]; then
      part=$(printf %s "$chunk" | rsa "$tmp/auth.pem" pkcs1) || return 1
    else
      part=$(printf %s "$chunk" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$hmachex" -binary | hex) || return 1
    fi
    sign+=$part
  done
  raw=$(body "$sign" "$cipher" | post "$api$stok/$path") || return 1
  unwrap "$raw"
}
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n ${mer_token:-} ]]; then mer_logout; fi
  if [[ -n $stok ]]; then
    local logout
    if logout=$(request 'admin/system?form=logout' 'operation=write' 2>/dev/null) && printf %s "$logout" | jq -e '.success == true' >/dev/null 2>&1; then note 'Logout: confirmed'; else printf '%s\n' 'WARNING: Logout not confirmed; session may expire automatically.' >&3; fi
  fi
  if [[ $quiet_output == yes && $rc != 0 ]]; then
    # Failure summaries are kept visible; full trace remains opt-in.
    grep '^ERROR:' "$tmp/diagnostics" >&3 || printf 'ERROR: Router command failed.\n' >&3
    printf 'Run with --verbose for diagnostics.\n' >&3
  fi
  rm -rf -- "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
note "TP-LINK CTL v0.1.18 — $base"
if [[ $insecure == yes ]]; then
  if [[ $pinned == yes ]]; then note 'TLS certificate verification disabled; public key pin enforced.'; else note 'WARNING: TLS certificate verification disabled; use only on a trusted LAN.'; fi
fi
note 'Login may replace an open router admin session.'
# Pre-login diagnostics: no passwords, keys, session tokens or raw HTML printed.
preflight() {
  local label=$1 path=$2 data=$3 code rc=0
  probe_body=''; probe_code='000'
  rm -f -- "$tmp/probe-body"
  code=$(printf '%s' "$data" | post "$api/$path" -o "$tmp/probe-body" -w '%{http_code}') || rc=$?
  probe_code=${code:-000}
  if (( rc != 0 )); then note "$label: HTTPS transport failure (curl=$rc, HTTP $probe_code)"; return 1; fi
  probe_body=$(cat "$tmp/probe-body")
  note "$label: HTTP $probe_code"
  if printf '%s' "$probe_body" | jq -e 'type=="object"' >/dev/null 2>&1; then
    printf '%s' "$probe_body" | jq -c '{success,errorcode:(.errorcode//.error_code//null),data_type:(.data|type),data_fields:(if (.data|type)=="object" then (.data|keys) else [] end)}' >&2
  elif printf '%s' "$probe_body" | grep -Eiq '<(!doctype[[:space:]]+html|html|head|body)'; then
    note '  Response is HTML, not a TP-Link JSON API object.'
  elif [[ -z $probe_body ]]; then note '  Empty response.'
  elif [[ $probe_body =~ ^[0-9]{5}$ ]]; then
    note "  Raw firmware code: $probe_body (not a JSON API object)"
  elif printf '%s' "$probe_body" | jq -e 'type=="number" or type=="boolean" or type=="null"' >/dev/null 2>&1; then
    note "  JSON scalar: $(printf '%s' "$probe_body" | jq -c . | cut -c1-80) (not an API object)"
  elif [[ $probe_body == null || $probe_body == false ]]; then note "  JSON scalar: $probe_body (not an API object)"
  else note '  Response is not a JSON object (body suppressed).'; fi
  [[ $probe_code == 2[0-9][0-9] ]]
}
# Only accept well-formed pre-login responses; no credentials sent here.
valid_keys() {
  printf '%s' "$1" | jq -e 'type=="object" and .success==true and (.data|type=="object") and (.data.password|type=="array" and length>=2 and all(.[0:2][]; type=="string" and test("^[0-9a-fA-F]+$")))' >/dev/null 2>&1
}
valid_auth() {
  printf '%s' "$1" | jq -e 'type=="object" and .success==true and (.data|type=="object") and (.data|has("seq")) and (.data.key|type=="array" and length>=2 and all(.[0:2][]; type=="string" and test("^[0-9a-fA-F]+$")))' >/dev/null 2>&1
}
web_fingerprint() {
  local scheme path report title markers code
  note 'WEB INTERFACE FINGERPRINT (no authentication)'
  for scheme in https http; do
    # Do not follow redirects or send session cookies to other endpoints.
    for path in / /webpages/index.html; do
      rm -f -- "$tmp/web-body"
      if report=$(curl -q -sS --noproxy '*' --proto "=$scheme" --connect-timeout 3 --max-time 6           "${tls[@]+${tls[@]}}" -o "$tmp/web-body" -w '%{http_code} %{content_type}' "$scheme://$router$path" 2>/dev/null); then
        note "  $scheme://$router$path: $report"
        title=$(LC_ALL=C tr '\r\n' '  ' < "$tmp/web-body" | grep -Eio '<title[^>]*>[^<]{0,160}</title>' | head -n 1 | sed -E 's/<[^>]*>//g' | tr -cd '[:print:]' || true)
        [[ -z $title ]] || note "    HTML title: $title"
        markers=$(grep -Eio 'tplink|tp-link|mercusys|openwrt|ubus|luci|cgi_gdpr|cgi/getGDPRParm|userRpm|deco|omada|Archer[[:space:]]+[A-Za-z0-9-]+' "$tmp/web-body" | sort -fu | head -n 15 | tr '\n' ' ' || true)
        [[ -z $markers ]] || note "    UI markers: $markers"
      else
        note "  $scheme://$router$path: transport failure"
      fi
    done
  done
}
# MER detection uses only public static frontend files, without authentication.
# Never follow a redirect or downgrade a credential-bearing request to HTTP.
mer_get() {
  curl -q -fsS --noproxy '*' --proto '=http' --connect-timeout 4 --max-time 12 \
    --max-filesize 4000000 -H "Referer: http://$router/" \
    "http://$router/$1" -o "$2"
}
mer_detect() {
  if [[ ${mer_detected:-no} == yes ]]; then return 0; fi
  if [[ $insecure != yes || $pinned == yes ]]; then return 1; fi
  mer_get '' "$tmp/mer-root" 2>/dev/null || return 1
  grep -Fq 'tpEncrypt.new.js' "$tmp/mer-root" || return 1
  grep -Fq 'js/su/frame2.js' "$tmp/mer-root" || return 1
  mer_tag=$(grep -Eo 'js/su/frame2\.js\?t=[a-zA-Z0-9_-]+' "$tmp/mer-root" | head -n 1 | cut -d= -f2 || true)
  mer_query=''; [[ -z $mer_tag ]] || mer_query="?t=$mer_tag"
  mer_get "js/su/frame2.js$mer_query" "$tmp/mer-frame2" 2>/dev/null || return 1
  grep -Fq 'MERProxy' "$tmp/mer-frame2" || return 1
  grep -Fq 'EINVCODE=5' "$tmp/mer-frame2" || return 1
  mer_detected=yes
  note 'MER API detected: numeric ?code= operations, plain-text block requests.'
  note 'Firmware code 00005 = EINVCODE (invalid operation code).'
  note 'MER read-only login backend is experimental; native VPN management is not implemented.'
  return 0
}
mer_collect() {
  command -v zip >/dev/null || fail 'Missing zip'
  mer_detect || fail 'MER frontend not detected, or HTTP probing disabled by TLS options'
  local dir="$tmp/mer-public" item manifest endpoint localfile out count=0
  mkdir -p "$dir"
  # Fixed paths come from the supplied firmware JavaScript.
  for item in config/device.json config/classes.json config/models.json config/modules.json config/src.js config/navigator.json config/navigator.ap.json config/navigator.re.json config/navigator.wisp.json config/navigator.client.json config/navigator.ssid.json; do
    mkdir -p "$dir/${item%/*}"
    if mer_get "$item$mer_query" "$dir/$item" 2>/dev/null; then
      note "Collected $item"
    else
      rm -f "$dir/$item"; note "Unavailable $item"
    fi
  done
  # Login bootstrap must come first: the old alphabetical 40-file limit
  # collected advanced configuration modules before the login modules.
  # Use explicit firmware manifest entries rather than generic "proxy" matches.
  {
    printf '%s\n' js/app/url.js js/libs/tpEncrypt.new.js js/su/frame1.js js/su/frame2.js
    if [[ -f $dir/config/modules.json ]]; then
      jq -r '. as $m | ["main","login","localLogin","index","utils","basicDevice","networkMap","tpLogin"][] as $k | $m[$k] | .. | strings' "$dir/config/modules.json"
    fi
    if [[ -f $dir/config/models.json ]]; then
      jq -r '. as $m | ["systemDataM","firmwareModel","localLoginControl","tpLoginControl","tpLoginModel","connectedClientsStore","allClientsStore"][] as $k | $m[$k] | strings' "$dir/config/models.json"
    fi
    if [[ -f $dir/config/classes.json ]]; then
      jq -r '. as $m | ["checkIsDefaultProxy","deviceDataProxy","deviceModeProxy","gdprProxy","tokenProxyIndex","tokenInstr","getStatusProxy","logoutProxy","connectedClientsProxy","allClientsProxy","getRemoteProxy","getFuncSupportProxy","checkGdprCloudLoginSt"][] as $k | $m[$k] | strings' "$dir/config/classes.json"
    fi
    # These exact paths were also confirmed in the uploaded manifests.
    printf '%s\n' modules/main/models.js modules/main/main.js modules/login/controllers.js modules/login/models.js modules/login/localLogin/controllers.js modules/login/localLogin/models.js modules/index/script.js modules/basicDevice/models.js
  } | awk '!seen[$0]++' > "$tmp/mer-paths"
  while IFS= read -r item; do
    endpoint=${item#./}; endpoint=${endpoint#/}; endpoint=${endpoint%%\?*}
    [[ $endpoint =~ ^[A-Za-z0-9_./-]+\.(js|json|html)$ ]] || continue
    [[ $endpoint != *..* && $endpoint != //* ]] || continue
    [[ $endpoint == js/* || $endpoint == config/* || $endpoint == modules/* || $endpoint == models/* || $endpoint == views/* || $endpoint == pages/* || $endpoint == webpages/* ]] || continue
    [[ ! -f $dir/$endpoint ]] || continue
    (( count < 60 )) || break
    count=$((count+1))
    mkdir -p "$dir/${endpoint%/*}"
    if mer_get "$endpoint$mer_query" "$dir/$endpoint" 2>/dev/null && [[ -s $dir/$endpoint ]] && ! grep -Eq '^[[:space:]]*[0-9]{1,8}[[:space:]]*$' "$dir/$endpoint"; then
      note "Collected $endpoint"
    else
      rm -f "$dir/$endpoint"; note "Unavailable $endpoint"
    fi
  done < "$tmp/mer-paths"
  local missing=0
  for endpoint in modules/main/models.js modules/main/main.js modules/login/controllers.js modules/login/localLogin/controllers.js modules/login/localLogin/models.js; do
    if [[ ! -s $dir/$endpoint ]]; then
      note "WARNING: essential authentication resource missing: $endpoint"
      missing=$((missing+1))
    fi
  done
  printf 'Essential login resources missing: %s/5\n' "$missing"
  if [[ -f $dir/config/modules.json ]]; then
    note 'VPN-specific module keys (absence is not proof of unsupported functionality):'
    jq -r '[keys[]|select(test("vpn|wireguard|openvpn";"i"))] | if length == 0 then "  none" else .[] end' "$dir/config/modules.json" >&2
  fi
  # No request bodies, cookies, passwords or authenticated configuration archived.
  printf '%s\n' 'Static frontend resources only; no login performed.' > "$dir/README.txt"
  out="$PWD/tplink-mer-${router}-$(date +%Y%m%d-%H%M%S).zip"
  (cd "$dir" && zip -qr "$out" .) || fail 'Archive creation failed'
  printf 'Archive: %s\n' "$out"
  note 'Review archive before sharing. No credentials requested or configuration changed.'
}
# MER backend derived from the router's own localLogin/main/MERProxy frontend.
# Plain HTTP login has reversible password obfuscation, not TLS protection.
mer_token=''; mer_gdpr=no; mer_ready=no
mer_post() {
  local query=$1 payload=$2 url="http://$router/?$1" allow401=${3:-no} http first
  # Session credential stays out of curl argv; no redirects, no proxy.
  printf 'url = "%s"\n' "$url" > "$tmp/mer-curl.conf"
  # MERProxy handles HTTP 401 by parsing the firmware error and challenge body.
  # Keep the body separately from the status; never print raw challenge data.
  http=$(printf '%s' "$payload" | curl -q --config "$tmp/mer-curl.conf" -sS --noproxy '*' --proto '=http' \
    --connect-timeout 4 --max-time 12 --max-filesize 2000000 \
    -b "$tmp/mer-cookies" -c "$tmp/mer-cookies" \
    -H "Origin: http://$router" -H "Referer: http://$router/" \
    -H 'Content-Type: text/plain;charset=UTF-8' -H 'X-Requested-With: XMLHttpRequest' --data-binary @- \
    -o "$tmp/mer-response" -w '%{http_code}') || return 1
  case "$http" in
    200) ;;
    401)
      [[ $allow401 == yes ]] || { note 'MER HTTP 401: request unauthorized'; return 1; }
      first=$(head -n 1 "$tmp/mer-response" | tr -d '\r')
      # 401 must carry a nonzero firmware error, not HTML or a success code.
      if [[ ! $first =~ ^[0-9]{1,5}$ ]] || ((10#$first == 0)); then
        note 'MER HTTP 401: missing valid firmware error code (body suppressed)'; return 1
      fi
      note "MER HTTP 401: firmware code $((10#$first)); response retained for authentication processing"
      ;;
    *) note "MER HTTP $http: unexpected response (body suppressed)"; return 1;;
  esac
  cat "$tmp/mer-response"
}
mer_split() {
  # Preserve internal CRLF; only normalize line endings for parsing.
  local v=$1 first
  v=${v//$'\r'/}; first=${v%%$'\n'*}
  [[ $first =~ ^[0-9]{1,5}$ ]] || return 1
  mer_code=$((10#$first)); mer_data=''
  if [[ $v == *$'\n'* ]]; then mer_data=${v#*$'\n'}; fi
}
# Firmware emits zero-padded decimal client states; never interpret as octal.
# States 0/1 are full/locked; 5 leads the browser to password recovery.
mer_check_login_state() {
  local raw=$1 phase=$2 state label
  [[ $raw =~ ^[0-9]{1,5}$ ]] || fail "MER $phase: malformed login state; no login attempted"
  state=$((10#$raw))
  case "$state" in
    0) label='client/session limit reached';;
    1) label='locked';;
    2) label='session timeout';;
    3) label='previous password error';;
    4) label='normal';;
    5) label='invalid client state / password recovery';;
    6) label='illegal password';;
    *) label='unknown';;
  esac
  note "MER $phase: $state ($label; raw $raw)"
  case "$state" in
    2|3|4) return 0;;
    *) fail "MER $phase: $label; no login attempted";;
  esac
}
mer_transform() {
  local a=$1 b=$2 alphabet=$3 i x y n len=${#1}
  [[ -n $alphabet ]] || return 1
  (( ${#b} <= len )) || len=${#b}
  for ((i=0;i<len;i++)); do
    x=187; y=187
    if ((i<${#a})); then printf -v x '%d' "'${a:i:1}"; fi
    if ((i<${#b})); then printf -v y '%d' "'${b:i:1}"; fi
    n=$(( (x ^ y) % ${#alphabet} )); printf '%s' "${alphabet:n:1}"
  done
}
# Match the browser's CRLF field parsing and UTF-16 charCodeAt/charAt semantics.
# Keep the challenge in a private file, not in argv or diagnostic output.
mer_parse_challenge() {
  jq -Rse '
    (if contains("\r\n") then split("\r\n") else split("\n") end) as $f
    | if ($f|length) < 4 or ($f[3]|length) == 0 then error("missing challenge field") else
      {challenge:$f[3],alphabet:($f[4] // "")}
    end
    | if (.challenge|length)>65536 or (.alphabet|length)>65536 then error("challenge field too large") else . end
  ' "$tmp/mer-response" > "$tmp/mer-challenge.json" || return 1
  note "$(jq -r '"MER challenge fields: challenge=\(.challenge|length) characters; alphabet=\(.alphabet|length) characters, \(.alphabet|utf8bytelength) bytes; non-ASCII/control characters=\([.alphabet|explode[]|select(.<32 or .>126)]|length)"' "$tmp/mer-challenge.json")"
}
mer_session_token() {
  # jq has no bitwise XOR; implement the 16-bit operation used by JS.
  jq -Rrs --slurpfile ch "$tmp/mer-challenge.json" '
    def utf16: explode | map(if .>65535 then (.-65536) as $x | [55296+($x/1024|floor),56320+($x%1024)] else [.] end) | flatten;
    def xor16($a;$b): reduce range(0;16) as $i ({a:$a,b:$b,p:1,v:0}; .v += ((.a%2 + .b%2)%2)*.p | .a=(.a/2|floor) | .b=(.b/2|floor) | .p*=2) | .v;
    def unicode: reduce .[] as $u ({out:[],high:null};
      if .high!=null then
        if $u>=56320 and $u<=57343 then .out += [65536+(.high-55296)*1024+$u-56320] | .high=null else error("unpaired UTF-16 surrogate") end
      elif $u>=55296 and $u<=56319 then .high=$u
      elif $u>=56320 and $u<=57343 then error("unpaired UTF-16 surrogate")
      else .out += [$u] end)
      | if .high!=null then error("unpaired UTF-16 surrogate") else .out|implode end;
    . as $password | $ch[0] as $c
    | ($c.challenge|utf16) as $a | ($password|utf16) as $b
    | (if $c.alphabet=="" then "yLwVl0zKqws7LgKPRQ84Mdt708T1qQ3Ha7xv3H7NyU84p21BriUWBU43odz3iP4rBL3cD02KZciXTysVXiV8ngg6vL48rPJyAUw0HurW20xqxv9aYb4M9wK1Ae0wlro510qXeU07kV57fQMc8L6aLgMLwygtc0F10a0Dg70TOoouyFhdysuRMO51yY5ZlOZZLEal1h0t9YQW0Ko7oBwmCAHoic4HYbUyVeU3sfQ1xtXcPcf1aT303wAQhv66qzW" else $c.alphabet end | utf16) as $alpha
    | [range(0;([($a|length),($b|length)]|max)) as $i | $alpha[xor16(($a[$i]//187);($b[$i]//187))%($alpha|length)]] | unicode | @uri
  '
}
mer_request() {
  local code=$1 asyn=$2 plain=$3 query raw cipher signstr sign='' i part
  query="code=$code&asyn=$asyn&id=$mer_token"
  if [[ $mer_gdpr == yes ]]; then
    [[ $mer_ready == yes ]] || return 1
    cipher=$(printf '%s' "$plain" | enc) || return 1
    signstr="k=$key&i=$iv&s=$((seq + ${#cipher}))"
    for ((i=0;i<${#signstr};i+=53)); do
      part=$(printf '%s' "${signstr:i:53}" | rsa "$tmp/mer-rsa.pem" pkcs1) || return 1
      sign+=$part
    done
    plain=$(printf 'sign=%s\r\ndata=%s' "$sign" "$cipher")
  fi
  raw=$(mer_post "$query" "$plain") || return 1
  if [[ $mer_gdpr == yes ]]; then
    raw=$(printf '%s' "$raw" | dec 2>/dev/null) || return 1
  fi
  printf '%s' "$raw"
}
mer_logout() {
  local raw
  if raw=$(mer_request 11 0 '' 2>/dev/null) && mer_split "$raw" && ((mer_code==0)); then
    note 'MER logout: confirmed'
  else printf '%s\n' 'WARNING: MER logout not confirmed; session may expire automatically.' >&3; fi
  mer_token=''
}
mer_login() {
  local raw mode challenge status alphabet pwd transformed token params e n s encoded
  local default_alphabet='yLwVl0zKqws7LgKPRQ84Mdt708T1qQ3Ha7xv3H7NyU84p21BriUWBU43odz3iP4rBL3cD02KZciXTysVXiV8ngg6vL48rPJyAUw0HurW20xqxv9aYb4M9wK1Ae0wlro510qXeU07kV57fQMc8L6aLgMLwygtc0F10a0Dg70TOoouyFhdysuRMO51yY5ZlOZZLEal1h0t9YQW0Ko7oBwmCAHoic4HYbUyVeU3sfQ1xtXcPcf1aT303wAQhv66qzW'
  [[ $user == admin ]] || fail 'MER local login supports the local admin password only'
  raw=$(mer_post 'code=16&asyn=0' enable) || fail 'MER GDPR discovery transport failure'
  mer_split "$raw" || fail 'Invalid MER GDPR discovery response'
  if ((mer_code==0)); then mer_gdpr=yes; else mer_gdpr=no; fi
  note "MER application encryption: $mer_gdpr (firmware response code $mer_code)"
  raw=$(mer_post 'code=7&asyn=1' '' yes) || fail 'MER login discovery failed'
  mer_split "$raw" || fail 'Invalid MER login discovery response'
  if ((mer_code==0)); then fail 'MER reports an existing authenticated session; close it and retry'; fi
  ((mer_code==7)) || fail "MER login discovery rejected (firmware code $mer_code); no login attempted"
  status=${mer_data%%$'\n'*}
  mer_check_login_state "$status" "login state"
  note 'WARNING: MER uses HTTP and reversible password obfuscation; use only on a trusted isolated LAN.'
  get_password
  pwd=$password; unset password
  [[ -n $pwd && ${#pwd} -le 32 && $pwd =~ ^[[:print:]]+$ ]] || fail 'MER requires 1–32 printable ASCII characters in this implementation'
  transformed=$(mer_transform "$pwd" RDpbLfCPsJZ7fiv "$default_alphabet") || fail 'MER password transform failed'
  unset pwd
  raw=$(mer_post 'code=2&asyn=1' '' yes) || fail 'MER temporary challenge request failed'
  mer_split "$raw" || fail 'Invalid MER temporary challenge response'
  ((mer_code==7)) || fail "MER temporary challenge rejected (firmware code $mer_code); no login attempted"
  status=$(printf '%s\n' "$mer_data" | sed -n '1p')
  mer_check_login_state "$status" "temporary challenge state"
  mer_parse_challenge || fail 'MER temporary challenge structure invalid; no login attempted'
  if [[ $mer_gdpr == yes ]]; then
    raw=$(mer_post 'code=16&asyn=0' get) || fail 'MER encryption parameters request failed'
    mer_split "$raw" && ((mer_code==0)) || fail 'MER encryption parameters rejected'
    e=$(printf '%s\n' "$mer_data" | sed -n '1p'); n=$(printf '%s\n' "$mer_data" | sed -n '2p'); s=$(printf '%s\n' "$mer_data" | sed -n '3p')
    [[ $s =~ ^[0-9]{1,16}$ ]] || fail 'Invalid MER sequence'
    seq=$((10#$s))
    make_pub "$n" "$e" "$tmp/mer-rsa.pem" || fail 'Invalid MER RSA key'
    key=$(digits); iv=$(digits); keyhex=$(printf '%s' "$key" | hex); ivhex=$(printf '%s' "$iv" | hex)
    encoded=$(printf 'k=%s&i=%s' "$key" "$iv" | rsa "$tmp/mer-rsa.pem" pkcs1) || fail 'MER AES key wrapping failed'
  fi
  token=$(printf '%s' "$transformed" | mer_session_token) || fail 'MER session transform failed'
  unset transformed challenge alphabet
  rm -f "$tmp/mer-challenge.json"
  [[ -n $token && $token =~ ^[a-zA-Z0-9._~%!-]+$ ]] || fail 'Unexpected MER session encoding'
  note 'MER authentication: attempting once...'
  raw=$(mer_post "code=7&asyn=0&id=$token" '' yes) || fail 'MER login transport failed; no retry'
  mer_split "$raw" || fail 'Invalid MER login response; no retry'
  ((mer_code==0)) || fail "MER login rejected (firmware code $mer_code); no retry"
  mer_token=$token; unset token
  note 'MER authentication: SUCCESS'
  if [[ $mer_gdpr == yes ]]; then
    raw=$(mer_post "code=16&asyn=0&id=$mer_token" "set $encoded") || fail 'MER encryption synchronization failed'
    unset encoded
    mer_split "$raw" && ((mer_code==0)) || fail 'MER encryption synchronization rejected'
  fi
  mer_ready=yes
}
mer_device_info() {
  local raw
  raw=$(mer_request 2 1 '0|1,0,0') || fail 'MER device information transport/decryption failed'
  mer_split "$raw" && ((mer_code==0)) || fail 'MER device information read rejected'
  # Device block schema from frame2.js; allowlist only nonsecret fields.
  printf '%s\n' "$mer_data" | jq -Rn '[inputs | capture("^(?<k>modelName|modelVer|softVer|hardVer|fullName|facturer) +(?<v>.*)$") | {key:.k,value:.v}] | from_entries' > "$tmp/mer-info.json"
  [[ $(jq 'length' "$tmp/mer-info.json") != 0 ]] || fail 'MER device block returned no recognized fields'
  jq '. + {backend:"mer",vpn_client:null,vpn_server:null, vpn_management:"not implemented"}' "$tmp/mer-info.json"
}
mer_dispatch() {
  case "$cmd" in
    info|inspect) ;;
    *) fail "MER command '$cmd' is not implemented; only info and inspect are supported. No login attempted.";;
  esac
  mer_login
  if [[ $cmd == info ]]; then
    local raw model hardware firmware
    raw=$(mer_device_info) || fail 'Cannot read MER device information'
    model=$(uri_decode "$(printf %s "$raw" | jq -r '.modelName//""')")
    hardware=$(uri_decode "$(printf %s "$raw" | jq -r '.hardVer//.modelVer//""')")
    firmware=$(uri_decode "$(printf %s "$raw" | jq -r '.softVer//""')")
    jq -n --arg address "$router" --arg model "$model" --arg hardware "$hardware" --arg firmware "$firmware" '{address:$address,authentication:"mer",model:$model,hardware_version:$hardware,firmware_version:$firmware,cpu_usage:null,mem_usage:null,vpn_client:null,vpn_server:null,kill_switch_supported:null,certification:null,global_enable:null,profile_count:null,policy_count:null,vpn_management:"Not implemented"}' | render_info
  else
    mer_device_info | render_fields
  fi
}

if [[ $cmd == collect-mer ]]; then mer_collect; exit 0; fi
probe_keys() {
  local kp=no ap=no
  if preflight 'RSA password key' 'login?form=keys&operation=read' '' && valid_keys "$probe_body"; then
    kp=yes
    probe_password_bits=$(printf %s "$probe_body" | jq -r ".data.password[0]|length*4")
    printf '%s' "$probe_body" | jq -c '.data | {password_key_bits:(.password[0]|length*4),mode_type:(.mode|type),mode:(.mode|if type=="string" or type=="number" or type=="boolean" then . else null end),username_field_type:(.username|type)}' >&2
  fi
  if preflight 'Auth challenge' 'login?form=auth&operation=read' '' && valid_auth "$probe_body"; then
    ap=yes
    probe_auth_bits=$(printf %s "$probe_body" | jq -r ".data.key[0]|length*4")
    printf '%s' "$probe_body" | jq -c '.data | {auth_key_bits:(.key[0]|length*4),sequence_type:(.seq|type)}' >&2
  fi
  probe_keys_ok=$kp; probe_auth_ok=$ap
  note "TP-Link RSA key API: $kp; challenge API: $ap"
  if [[ $kp == yes && $ap == yes ]]; then
    note 'TP-Link encrypted API detected; authentication variant still requires confirmation.'
  else
    # Some variants put operation in POST data instead of URL parameters.
    note 'ALTERNATIVE READ REQUEST FORMAT'
    if preflight 'RSA password key (POST body)' 'login?form=keys' 'operation=read' && valid_keys "$probe_body"; then note '  Valid password RSA key found with body format.'; fi
    if preflight 'Auth challenge (POST body)' 'login?form=auth' 'operation=read' && valid_auth "$probe_body"; then note '  Valid authentication challenge found with body format.'; fi
    web_fingerprint
    mer_detect || true
  fi
  note 'No login attempted. No router configuration changed.'
  if [[ $kp == yes && $ap == yes ]]; then return 0; else return 1; fi
}
config=null; config_ok=no; sg_ok=no
if preflight 'Firmware capability query' 'device_config?form=config' 'operation=read'; then
  config=$probe_body
  if printf '%s' "$config" | jq -e '.success==true and (.data|type=="object")' >/dev/null 2>&1; then
    config_ok=yes
    printf '%s' "$config" | jq -c '.data | {certification,supportVpnClientType,supportVpnServerType,supportVpnKillSwitch,supportOperationMode}' >&2
    if printf '%s' "$config" | jq -e '.data.certification | arrays | any(. == "SG CLS L1 STAGE2" or . == "EU CE RED")' >/dev/null 2>&1; then sg_ok=yes; fi
  fi
fi
if [[ $config_ok != yes ]]; then config=null; fi
if [[ $cmd == probe ]]; then
  probe_keys || true
  jq -n --arg address "$router" --arg firmware "$config_ok" --arg keys "${probe_keys_ok:-no}" --arg challenge "${probe_auth_ok:-no}" --arg sg "$sg_ok" --arg mer "${mer_detected:-no}" --arg pb "${probe_password_bits:-}" --arg ab "${probe_auth_bits:-}" '{address:$address,firmware_api:$firmware,rsa_key_api:$keys,auth_challenge_api:$challenge,sg_certification:$sg,mer_detected:$mer,password_key_bits:(try ($pb|tonumber) catch null),auth_key_bits:(try ($ab|tonumber) catch null)}' | render_fields
  exit 0
fi
if [[ $auth_mode == mer ]]; then mer_detect || fail 'MER frontend not detected or HTTP disabled by TLS options'; mer_dispatch; exit 0; fi
if [[ $auth_mode == auto ]]; then
  if [[ $sg_ok == yes ]]; then auth_mode=sg; else
    if probe_keys; then
      # Only auto-select classic for the exact key sizes observed on the
      # successfully authenticated classic device. Never retry another login.
      if [[ ${probe_password_bits:-0} == 1024 && ${probe_auth_bits:-0} == 512 ]]; then
        auth_mode=classic
      else
        fail 'Authentication variant not confirmed. For classic LuCI firmware try --auth classic info; no automatic login fallback.'
      fi
    else
      if mer_detect; then mer_dispatch; exit 0; fi
      fail 'Required LuCI key endpoints not detected; MER not detected. No login attempted.'
    fi
  fi
fi
if [[ $sg_ok == yes && $auth_mode == classic ]]; then fail 'Router advertises SG certification; use --auth sg or auto'; fi
note "Authentication mode: $auth_mode"
keys=$(printf '' | post "$api/login?form=keys&operation=read") || fail 'Password key request failed'
auth=$(printf '' | post "$api/login?form=auth&operation=read") || fail 'Authentication key request failed'
if ! valid_keys "$keys" || ! valid_auth "$auth"; then
  note 'Selected authentication mode requires valid LuCI key and challenge objects.'
  probe_keys || true
  fail 'Unsupported or unexpected pre-login response; no password requested or login attempted.'
fi
pn=$(printf %s "$keys" | jq -er '.data.password[0] | strings') || fail 'Missing password modulus'
pe=$(printf %s "$keys" | jq -er '.data.password[1] | strings') || fail 'Missing password exponent'
an=$(printf %s "$auth" | jq -er '.data.key[0] | strings') || fail 'Missing authentication modulus'
ae=$(printf %s "$auth" | jq -er '.data.key[1] | strings') || fail 'Missing authentication exponent'
seq=$(printf %s "$auth" | jq -er '.data.seq | tostring') || fail 'Missing sequence'
[[ $seq =~ ^(0|[1-9][0-9]{0,15})$ ]] || fail 'Unexpected sequence number'
make_pub "$pn" "$pe" "$tmp/password.pem" || fail 'Cannot construct password RSA key'
make_pub "$an" "$ae" "$tmp/auth.pem" || fail 'Cannot construct auth RSA key'
printf 'RSA key sizes: password=%s bits, auth=%s bits\n' "$(( ${#pn}*4 ))" "$(( ${#an}*4 ))" >&2
# Refresh challenge after reading password, so do not prompt too long before login.
get_password
# Fetch fresh challenge after interactive prompt.
auth=$(printf '' | post "$api/login?form=auth&operation=read") || fail 'Fresh authentication key request failed'
valid_auth "$auth" || fail 'Fresh challenge is invalid; no login attempted'
an=$(printf %s "$auth" | jq -er '.data.key[0] | strings') || fail 'Missing auth key'
ae=$(printf %s "$auth" | jq -er '.data.key[1] | strings') || fail 'Missing auth exponent'
seq=$(printf %s "$auth" | jq -er '.data.seq | tostring') || fail 'Missing sequence'
[[ $seq =~ ^(0|[1-9][0-9]{0,15})$ ]] || fail 'Unexpected sequence number'
make_pub "$an" "$ae" "$tmp/auth.pem" || fail 'Cannot construct auth RSA key'
key=$(digits); iv=$(digits); keyhex=$(printf %s "$key" | hex); ivhex=$(printf %s "$iv" | hex)
km="k=$key&i=$iv"; hmachex=$(printf %s "$km" | hex)
if [[ $auth_mode == classic ]]; then
  credential_hash=$(printf '%s%s' "$user" "$password" | md5hex) || fail 'MD5 unavailable in local OpenSSL'
  hash=$credential_hash
else
  hash=$(printf '%s%s' "$user" "$password" | sha)
fi
epwd=$(printf %s "$password" | rsa "$tmp/password.pem" pkcs1) || fail 'Password RSA encryption failed'
unset password
cipher=$(printf 'operation=login&password=%s&confirm=true' "$epwd" | enc)
unset epwd
signstr="$km&h=$hash&s=$((seq + ${#cipher}))"
if [[ $auth_mode == classic ]]; then
  padding=pkcs1; step=$(( ${#an}/2 - 11 ))
else
  padding=oaep; step=$(( ${#an}/2 - 42 ))
fi
(( step > 0 )) || fail 'Auth RSA key too short'; if ((step > 53)); then step=53; fi
sign=''
for ((i=0;i<${#signstr};i+=step)); do
  part=$(printf %s "${signstr:i:step}" | rsa "$tmp/auth.pem" "$padding") || fail 'RSA login signature encryption failed'
  sign+=$part
done
unset hash signstr km part
note 'Authentication: attempting once...'
raw=$(body "$sign" "$cipher" | post "$api/login?form=login") || fail 'Login transport failed; no retry'
unset sign cipher
if ! login=$(unwrap "$raw" 2>/dev/null); then
  printf %s "$raw" | jq -c 'if type=="object" then {success,errorcode} else {} end' >&2 2>/dev/null || true
  fail 'Login response was not encrypted JSON for selected mode; no retry'
fi
unset raw
if ! printf %s "$login" | jq -e '.success == true' >/dev/null; then
  printf %s "$login" | jq '{success,errorcode:(.errorcode // .data.errorcode // "unknown"),failureCount:.data.failureCount,attemptsAllowed:.data.attemptsAllowed}' >&2
  fail 'Login rejected; no retry'
fi
stok=$(printf %s "$login" | jq -er '.data.stok | strings | select(test("^[A-Za-z0-9_-]+$"))') || fail 'Missing session token'
unset login
note 'Authentication: SUCCESS'
# Download only frontend resources (GET, no API calls or configuration writes).
# Candidate paths are deliberately probes; exact assets vary between firmware.
collect_vpn() {
  command -v zip >/dev/null || fail 'Missing zip'
  local dir="$tmp/vpn-frontend" out endpoint code count=0 hits=0 item name ref prefix
  mkdir -p "$dir"
  : > "$tmp/vpn-seen"
  {
    printf '%s\n' webpages/index.html webpages/login.html
    for prefix in webpages/pages/userrpm webpages/pages webpages/js webpages/js/app webpages/js/su webpages/js/pages webpages/js/views; do
      for name in vpnClient vpn_client vpnclient vpn openvpnClient openvpn_client wireguardClient wireguard_client; do
        case "$prefix" in *pages/userrpm|webpages/pages) printf '%s/%s.html\n' "$prefix" "$name";; *) printf '%s/%s.js\n' "$prefix" "$name";; esac
      done
    done
    printf '%s\n' webpages/js/su/su.js webpages/js/su/proxy.js webpages/js/su/store.js webpages/js/su/form.js webpages/js/su/widget.js webpages/js/app/app.js webpages/js/app/url.js webpages/js/libs/tpEncrypt.js webpages/js/libs/tpEncrypt.new.js
  } > "$tmp/vpn-queue"
  # Index resources may reveal the actual filenames. Limit discovery to same-host
  # static HTML/JS paths; never request a session URL or query an admin endpoint.
  while IFS= read -r endpoint; do
    [[ $endpoint =~ ^webpages/[A-Za-z0-9_./-]+\.(html|js)$ && $endpoint != *..* && $endpoint != *//* ]] || continue
    if grep -Fxq "$endpoint" "$tmp/vpn-seen"; then continue; fi
    printf '%s\n' "$endpoint" >> "$tmp/vpn-seen"
    (( count < 95 )) || break
    count=$((count+1))
    mkdir -p "$dir/${endpoint%/*}"
    code=$(curl -q -sS --noproxy '*' --proto '=https' --connect-timeout 3 --max-time 5 --max-filesize 8388608 \
      "${tls[@]+${tls[@]}}" -b "$tmp/cookies" -H "Referer: $base/webpages/index.html" \
      -o "$dir/$endpoint" -w '%{http_code}' "$base/$endpoint" 2>/dev/null) || code=000
    if [[ $code != 200 || ! -s $dir/$endpoint ]] || grep -Eq '^[[:space:]]*[0-9]{1,8}[[:space:]]*$' "$dir/$endpoint"; then
      rm -f "$dir/$endpoint"; continue
    fi
    if [[ $endpoint == *.js ]] && grep -Eiq '^[[:space:]]*<(!doctype|html)' "$dir/$endpoint"; then rm -f "$dir/$endpoint"; continue; fi
    # Do not archive a document containing this login's actual session token.
    if [[ -n $stok ]] && grep -Fq "$stok" "$dir/$endpoint"; then rm -f "$dir/$endpoint"; continue; fi
    note "Collected $endpoint"
    if grep -Eiq 'form[=:][[:space:]]*[^a-zA-Z0-9_]*(ovpn|wireguard)|vpn_user_list|vpnClient|vpn_client|openvpn' "$dir/$endpoint"; then
      hits=$((hits+1))
      printf '%s\n' "$endpoint" >> "$dir/vpn-source-files.txt"
    fi
    # Extract references in static scripts/HTML (relative to /webpages/ or /).
    while IFS= read -r ref; do
      ref=${ref#./}; ref=${ref#/}
      case "$ref" in webpages/*) item=$ref;; js/*|pages/*) item=webpages/$ref;; *) continue;; esac
      if [[ $item =~ ^webpages/[A-Za-z0-9_./-]+\.(html|js)$ && $item != *..* && $item != *//* ]]; then
        if ! grep -Fxq "$item" "$tmp/vpn-queue"; then printf '%s\n' "$item" >> "$tmp/vpn-queue"; fi
      fi
    done < <(grep -Eo '([./]*webpages/|[./]*js/|[./]*pages/)[A-Za-z0-9_./-]+\.(html|js)' "$dir/$endpoint" | sort -u || true)
  done < "$tmp/vpn-queue"
  if (( hits == 0 )); then
    fail 'VPN frontend not found at candidate static paths. Open Advanced > VPN Client in your browser and use the companion browser collector.'
  fi
  out="$PWD/tplink-vpn-$router-$(date +%Y%m%d-%H%M%S).zip"
  (cd "$dir" && zip -qr "$out" .) || fail 'Cannot create archive'
  printf 'VPN-related resources: %s\nArchive: %s\nNo VPN settings changed.\n' "$hits" "$out"
}

# Management operations; never print full VPN records (may contain secrets).
P='admin/vpn?form=server'; D='admin/vpn?form=vpn_user_list'; E='admin/vpn?form=enable'
api_data() {
  local r
  r=$(request "$1" "$2") || { note "Request failed: $1; transport or response error."; return 1; }
  if ! printf %s "$r" | jq -e '.success == true' >/dev/null; then
    note "API rejected $1: $(printf %s "$r" | jq -c '{success,errorcode}')"; return 1
  fi
  printf %s "$r" | jq -c '.data'
}
# Empty tables may be encoded as [] / {} / null. Only normalize explicit
# successful envelopes with a data field, never failed or missing responses.
api_table() {
  local path=$1 r result
  r=$(request "$path" operation=load) || { note "Request failed: $path; transport or response error."; return 1; }
  if ! printf %s "$r" | jq -e 'type=="object" and .success==true' >/dev/null; then
    note "API rejected $path (table load)"; return 1
  fi
  # Schema diagnostics only: profile records may contain VPN credentials.
  note "Table response $path: $(printf %s "$r" | jq -c '{success,has_data:has("data"),data_type:(.data|type),data_length:(.data|if type=="array" or type=="object" or type=="string" then length else null end),envelope_fields:keys,data_fields:(.data|if type=="object" then keys else null end)}')"
  if ! result=$(printf %s "$r" | jq -ce '
    if has("data")|not then error("Missing table data")
    elif (.data|type)=="array" then
      if all(.data[];type=="object") then .data else error("Invalid table rows") end
    elif .data==null or .data=={} then []
    else error("Unexpected table data shape") end' 2>/dev/null); then
    note "Unsupported table response: $path; not treated as empty."; return 1
  fi
  printf '%s\n' "$result"
}
profiles() { api_table "$P"; }
policies() { api_table "$D"; }
state() { local r; r=$(api_data "$E" operation=read) || return 1; printf %s "$r" | jq -ce 'select(type=="object" and (.enable=="on" or .enable=="off"))'; }
profile() {
  printf %s "$1" | jq -ce --arg name "$2" '[.[]|select(.des==$name or (.key|tostring)==$name)] | if length==1 then .[0] else error("Profile missing or ambiguous") end'
}
policy() {
  printf %s "$1" | jq -ce --arg mac "$2" 'def norm: ascii_downcase|gsub("[:-]";""); [.[]|select((.mac//""|norm)==($mac|norm))] | if length==1 then .[0] else error("Device missing or ambiguous in VPN whitelist") end'
}
profile_view() { jq 'map({name:.des, id:.key, protocol:.type, enabled:.enable,status})'; }
policy_view() { jq 'map({name,mac,access,client_type})'; }
# Encode full old/new records, preserving all unknown fields; only one property changes.
update_payload() {
  printf '%s\n%s\n' "$2" "$3" | jq -sr --arg key "$1" '"operation=update&key="+($key|@uri)+"&new="+(.[1]|tojson|@uri)+"&old="+(.[0]|tojson|@uri)'
}
set_profile() {
  local name=$1 desired=$2 all old new id other payload after
  all=$(profiles) || fail 'Cannot load VPN profiles'
  old=$(profile "$all" "$name") || fail 'Select exactly one profile from list'
  id=$(printf %s "$old" | jq -er '.key|select(type=="string" or type=="number")|tostring|select(length>0)') || fail 'Profile ID missing'
  [[ $(printf %s "$old" | jq -r '.enable') != "$desired" ]] || { action_notice "Profile already $desired (connection status may differ)"; printf %s "$old" | jq '{name:.des,enabled:.enable,status}' | render_action; return; }
  if [[ $desired == on ]]; then
    [[ $(state | jq -r .enable) == on ]] || fail 'Global VPN client is disabled; run enable explicitly first'
    other=$(printf %s "$all" | jq -r --arg id "$id" '[.[]|select((.key|tostring)!=$id and .enable=="on")|.des]|join(", ")')
    [[ -z $other || $switch == yes ]] || fail "Another VPN is enabled ($other); use --switch to allow replacement"
  fi
  new=$(printf %s "$old" | jq -c --arg v "$desired" '.enable=$v')
  if [[ $dry == yes ]]; then jq -n --arg name "$name" --arg enabled "$desired" '{dry_run:true,name:$name,requested_enabled:$enabled}' | render_action; return; fi
  action_notice 'WARNING: VPN routing for selected LAN devices may change.'
  payload=$(update_payload "$id" "$old" "$new") || fail 'Cannot encode update'
  api_data "$P" "$payload" >/dev/null || fail 'Profile update not confirmed; inspect list before retrying'
  after=$(profiles) || fail 'Update accepted but readback failed; inspect list'
  after=$(profile "$after" "$id") || fail 'Updated profile not found'
  [[ $(printf %s "$after" | jq -r .enable) == "$desired" ]] || fail 'Readback does not match requested state'
  printf %s "$after" | jq '{name:.des,protocol:.type,enabled:.enable,status}' | render_action
  action_notice 'Configuration verified; tunnel connectivity is not guaranteed.'
}
# The LuCI VPN whitelist is shared by all profiles. Never silently switch tunnels.
require_active_profile() {
  local name=$1 all selected active global
  all=$(profiles) || fail 'Cannot load profiles'
  selected=$(profile "$all" "$name") || fail 'Profile missing or ambiguous'
  active=$(printf %s "$all" | jq '[.[]|select(.enable=="on")]|length')
  [[ $active == 1 && $(printf %s "$selected" | jq -r .enable) == on ]] || fail 'Named profile must be the only enabled profile; device policy is global (use start PROFILE first)'
  global=$(state) || fail 'Cannot read global VPN state'
  [[ $(printf %s "$global" | jq -r .enable) == on ]] || fail 'Global VPN client is disabled'
}
# Resolve exact name/IP or canonical MAC; deduplicate only by MAC, never by name.
resolve_device() {
  local selector=$1 all=$2 r kind=label normalized='' result
  if [[ $selector =~ ^([[:xdigit:]]{2}[:-]){5}[[:xdigit:]]{2}$ || $selector =~ ^[[:xdigit:]]{12}$ ]]; then
    kind=mac; normalized=$(printf %s "$selector" | tr -d ':-' | tr '[:lower:]' '[:upper:]')
  elif [[ $selector =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then kind=ip; fi
  r=$(optional_read read_object "$status_path")
  if [[ $r == null && $kind != mac ]]; then fail 'Cannot resolve name/IP: connected-device API unavailable; use MAC'; fi
  result=$(printf '%s\n%s\n' "$r" "$all" | jq -ce -s --arg q "$selector" --arg kind "$kind" --arg mac "$normalized" '
    def norm: tostring|ascii_upcase|gsub("[:-]";"");
    def device: {name:(.name//.hostname//.host_name//""),mac:(.mac//.macaddr//.mac_addr//""),ip:(.ip//.ipaddr//.ip_addr//""),client_type:(.client_type//null)} | .canonical=(.mac|norm);
    (.[0]//{}) as $s | (([$s.access_devices_wired,$s.access_devices_wireless_host,$s.access_devices_wireless_guest]|map(if type=="array" then . else [] end)|add) + .[1]) | map(device|select(.canonical|test("^[0-9A-F]{12}$"))) |
    map(select(if $kind=="mac" then .canonical==$mac elif $kind=="ip" then .ip==$q else (.name|ascii_downcase)==($q|ascii_downcase) end)) | group_by(.canonical) |
    if length>1 then error("Ambiguous device; use MAC") elif length==1 then .[0][0] elif $kind=="mac" then {canonical:$mac,name:$q,ip:"",client_type:null} else error("Device not found") end |
    .mac=(.canonical|[scan("..")]|join(":")) | del(.canonical)') || fail "Cannot uniquely resolve device '$selector'; use MAC or check devices"
  printf '%s' "$result"
}
policy_matches() {
  printf %s "$1" | jq -c --arg mac "$2" 'def norm: tostring|ascii_downcase|gsub("[:-]";""); [.[]|select((.mac//""|norm)==($mac|norm))]'
}
remove_payload() { jq -nr --arg key "$1" --arg index "$2" '"operation=remove&key="+($key|@uri)+"&index="+($index|@uri)'; }
# Ensure all non-target row identities remain unchanged after a deletion.
verify_removal() {
  printf '%s\n%s\n' "$1" "$2" | jq -es --arg field "$3" --arg key "$4" '
    def norm: tostring | if $field=="mac" then ascii_downcase|gsub("[:-]";"") else . end;
    def ids: map(.[$field]|norm)|sort;
    ((.[0]|ids|map(select(.!=($key|norm)))) == (.[1]|ids)) and ((.[0]|length)==((.[1]|length)+1))' >/dev/null
}
remove_profile() {
  local name=$1 all old id idx after current
  all=$(profiles) || fail 'Cannot load VPN profiles'
  old=$(profile "$all" "$name") || fail 'Profile missing or ambiguous'
  [[ $(printf %s "$old" | jq -r .enable) == off ]] || fail 'Stop profile before removing it'
  id=$(printf %s "$old" | jq -er '.key|select(type=="string" or type=="number")|tostring|select(length>0)') || fail 'Missing profile ID'
  idx=$(printf %s "$all" | jq -er --arg id "$id" '[to_entries[]|select((.value.key|tostring)==$id)|.key]|if length==1 then .[0] else error("Ambiguous ID") end') || fail 'Ambiguous profile ID'
  if [[ $dry == yes ]]; then jq -n --arg name "$name" --arg id "$id" '{dry_run:true,operation:"Remove profile",profile:$name,id:$id}' | render_action; return; fi
  current=$(profiles) || fail 'Cannot recheck profiles'
  [[ $current == "$all" ]] || fail 'Profile table changed; retry after checking list'
  api_data "$P" "$(remove_payload "$id" "$idx")" >/dev/null || fail 'Removal not confirmed; inspect list before retrying'
  after=$(profiles) || fail 'Removal acknowledged; final state unconfirmed. Run list --verbose; do not repeat removal.'
  verify_removal "$all" "$after" key "$id" || fail 'Unexpected profile table after removal; inspect list immediately'
  jq -n --arg name "$name" '{profile:$name,result:"Removed"}' | render_action
}
manage_device() {
  local op=$1 name=$2 selector=$3 all dev mac matches count old id idx payload after current record
  [[ -z $name ]] || require_active_profile "$name"
  all=$(policies) || fail 'Cannot read VPN whitelist'
  dev=$(resolve_device "$selector" "$all") || fail 'Device resolution failed'
  mac=$(printf %s "$dev" | jq -er .mac) || fail 'Missing device MAC'
  matches=$(policy_matches "$all" "$mac") || fail 'Cannot check VPN whitelist'
  count=$(printf %s "$matches" | jq length)
  (( count <= 1 )) || fail 'Duplicate MAC in VPN whitelist; inspect devices'
  case "$op" in
    connect|disconnect)
      (( count == 1 )) || fail 'Device not attached; run attach first'
      if [[ $op == connect ]]; then set_policy on "$mac" "$name"; else set_policy off "$mac" "$name"; fi
      return;;
    attach)
      if ((count == 1)); then printf %s "$matches" | jq '.[0]|{name,mac,access,result:"Already attached"}' | render_action; return; fi
      record=$(printf %s "$dev" | jq -c '{name:(if .name=="" then .mac else .name end),mac,access:"off"} + (if .client_type==null then {} else {client_type} end)')
      if [[ $dry == yes ]]; then printf %s "$record" | jq --arg profile "$name" '.+{dry_run:true,operation:"Attach (disabled)",profile:$profile,scope:"global"}' | render_action; return; fi
      current=$(policies) || fail 'Cannot recheck VPN whitelist'
      [[ $current == "$all" ]] || fail 'VPN whitelist changed; inspect devices before retrying'
      payload=$(jq -nr --arg row "$record" '"operation=insert&new="+($row|@uri)')
      api_data "$D" "$payload" >/dev/null || fail 'Attach not confirmed; inspect devices before retrying'
      after=$(policies) || fail 'Attach accepted but readback failed'
      old=$(policy "$after" "$mac") || fail 'Attached device missing or duplicated'
      [[ $(printf %s "$old" | jq -r .access) == off ]] || fail 'Attached device access not disabled; inspect devices immediately'
      printf '%s\n%s\n' "$all" "$after" | jq -es --arg mac "$mac" 'def ids: map(.mac|ascii_downcase|gsub("[:-]";""))|sort; ((.[0]|ids)+[($mac|ascii_downcase|gsub("[:-]";""))]|sort)==(.[1]|ids)' >/dev/null || fail 'Unexpected VPN whitelist after attach; inspect devices'
      printf %s "$old" | jq '{name,mac,access,result:"Attached (disconnected)"}' | render_action;;
    remove)
      (( count == 1 )) || fail 'Device is not attached'
      old=$(printf %s "$matches" | jq -c '.[0]')
      [[ $(printf %s "$old" | jq -r .access) == off ]] || fail 'Disconnect device before removing it'
      id=$(printf %s "$old" | jq -er .mac)
      idx=$(printf %s "$all" | jq -er --arg id "$id" '[to_entries[]|select(.value.mac==$id)|.key]|if length==1 then .[0] else error("Ambiguous MAC") end') || fail 'Ambiguous MAC'
      if [[ $dry == yes ]]; then jq -n --arg mac "$mac" --arg profile "$name" '{dry_run:true,operation:"Remove device",profile:$profile,mac:$mac,scope:"global"}' | render_action; return; fi
      current=$(policies) || fail 'Cannot recheck VPN whitelist'
      [[ $current == "$all" ]] || fail 'VPN whitelist changed; inspect devices before retrying'
      api_data "$D" "$(remove_payload "$id" "$idx")" >/dev/null || fail 'Device removal not confirmed; inspect devices before retrying'
      after=$(policies) || fail 'Remove accepted but readback failed'
      verify_removal "$all" "$after" mac "$id" || fail 'Unexpected VPN whitelist after removal; inspect devices immediately'
      jq -n --arg mac "$mac" '{mac:$mac,result:"Removed",scope:"global"}' | render_action;;
  esac
}
set_policy() {
  local desired=$1 mac=$2 name=$3 all old new id payload after
  if [[ -n $name ]]; then require_active_profile "$name"; fi
  all=$(policies) || fail 'Cannot read VPN whitelist'
  old=$(policy "$all" "$mac") || fail 'Add device to VPN whitelist in router UI first'
  id=$(printf %s "$old" | jq -er '.mac|strings|select(length>0)') || fail 'Missing device MAC'
  [[ $(printf %s "$old" | jq -r .access) != "$desired" ]] || { action_notice "Device policy already $desired"; printf %s "$old" | jq '{name,mac,access}' | render_action; return; }
  new=$(printf %s "$old" | jq -c --arg v "$desired" '.access=$v')
  if [[ $dry == yes ]]; then jq -n --arg mac "$mac" --arg access "$desired" '{dry_run:true,mac:$mac,requested_access:$access}' | render_action; return; fi
  action_notice 'WARNING: device policy is global, not a profile-specific binding.'
  payload=$(update_payload "$id" "$old" "$new") || fail 'Cannot encode update'
  api_data "$D" "$payload" >/dev/null || fail 'Device update not confirmed; inspect devices before retrying'
  after=$(policies) || fail 'Update accepted but readback failed'
  after=$(policy "$after" "$mac") || fail 'Device missing after update'
  [[ $(printf %s "$after" | jq -r .access) == "$desired" ]] || fail 'Device policy readback mismatch'
  printf %s "$after" | jq '{name,mac,access}' | render_action
}
set_global() {
  local desired=$1 before after
  before=$(state) || fail 'Cannot read global VPN state'
  [[ $(printf %s "$before" | jq -r .enable) != "$desired" ]] || { action_notice "Global VPN already $desired"; printf %s "$before" | jq '{enable}' | render_action; return; }
  if [[ $dry == yes ]]; then jq -n --arg enable "$desired" '{dry_run:true,requested_enable:$enable}' | render_action; return; fi
  action_notice 'WARNING: global VPN change can affect every selected device.'
  api_data "$E" "operation=write&enable=$desired" >/dev/null || fail 'Global VPN update not confirmed'
  after=$(state) || fail 'Update accepted but readback failed'
  [[ $(printf %s "$after" | jq -r .enable) == "$desired" ]] || fail 'Global VPN readback mismatch'
  printf %s "$after" | jq '{enable}' | render_action
}
# AX80 frontend index-DMehFI4W.js: z.file(..., encrypt:false), then
# z.insert(server, record, {index:0}). Multipart response envelope is inferred
# from the common API; reject any unknown format without retrying writes.
vpn_upload() {
  local proto=$1 file=$2 endpoint raw
  local -a fields
  if [[ $proto == openvpn ]]; then
    endpoint='admin/vpn?form=ovpn'
    fields=(--form-string "file_name=${file##*/}" --form-string 'file_type=ovpn')
  else
    endpoint='admin/vpn?form=wireguard'
    fields=(--form-string 'operation=upload_file')
  fi
  # file is a controlled temporary filename, not a user-supplied curl expression.
  raw=$(curl -q -sS --fail --noproxy '*' --proto '=https' --connect-timeout 4 --max-time 15 \
    "${tls[@]+${tls[@]}}" -b "$tmp/cookies" -c "$tmp/cookies" \
    -H "Referer: $base/webpages/index.html" -H "Origin: $base" \
    -H 'X-Requested-With: XMLHttpRequest' "${fields[@]}" \
    --form "file=@$file;type=application/octet-stream" "$api$stok/$endpoint") || return 1
  if ! printf '%s' "$raw" | jq -e 'type=="object" and .success==true' >/dev/null 2>&1; then
    note "Upload response schema: $(printf '%s' "$raw" | jq -c 'if type=="object" then {success,errorcode,fields:keys} else {type:type} end' 2>/dev/null || printf 'non-JSON')"
    return 1
  fi
  printf '%s' "$raw" | jq -c '.data'
}
add_profile() {
  local name=$1 file=$2 proto all upload row id after result payload filename
  [[ $auth_mode == sg && $sg_ok == yes ]] || fail 'Profile import is currently implemented only for SG firmware with advertised VPN support'
  case "$file" in *.ovpn) proto=openvpn;; *.conf) proto=wireguard;; *) fail 'Use an .ovpn or WireGuard .conf file';; esac
  [[ -f $file && -r $file && -s $file ]] || fail 'VPN file missing, unreadable or empty'
  [[ -n $name && ${#name} -le 64 && ! $name =~ [[:cntrl:]] ]] || fail 'Profile name must be 1–64 bytes without control characters'
  printf '%s' "$config" | jq -e --arg p "$proto" '.data.supportVpnClientType|arrays|index($p)!=null' >/dev/null || fail 'Router does not advertise this VPN protocol'
  all=$(profiles) || fail 'Cannot load VPN profiles'
  printf '%s' "$all" | jq -e --arg n "$name" 'all(.[]; .des!=$n and (.key|tostring)!=$n)' >/dev/null || fail 'Profile name or ID already exists'
  if [[ $dry == yes ]]; then
    jq -n --arg n "$name" --arg p "$proto" '{dry_run:true,operation:"Import profile",name:$n,protocol:$p,enabled:"off",upload:false}' | render_action
    return
  fi
  # Preserve a safe original basename for the file_name parameter; sanitize only
  # unsafe names rather than passing curl multipart metacharacters from the user.
  filename=${file##*/}
  if [[ ! $filename =~ ^[A-Za-z0-9_.-]+$ ]]; then filename="profile.${file##*.}"; fi
  cp -- "$file" "$tmp/$filename" || fail 'Cannot stage VPN file locally'
  id=$(openssl rand -hex 11) || fail 'Cannot generate profile ID'
  id=${id:0:21}
  upload=$(vpn_upload "$proto" "$tmp/$filename") || fail 'VPN upload not confirmed; no profile insert attempted (use --verbose)'
  if [[ $proto == openvpn ]]; then
    # Browser reads staged certificates and checks the file before saving.
    api_data 'admin/vpn?form=ovpn' 'operation=read&key=add' >/dev/null || fail 'Uploaded OpenVPN file but staged certificate read failed; no profile inserted'
    api_data "$P" 'operation=file_check&type=openvpn' >/dev/null || fail 'Router rejected OpenVPN configuration; no profile inserted'
    row=$(jq -cn --arg key "$id" --arg name "$name" '{key:$key,des:$name,type:"openvpn",enable:"off",server:"",username:"",password:"",manual:false}') || fail 'Cannot build OpenVPN profile'
  else
    # The browser copies parsed configuration fields from the upload response.
    # Do not print the response: it contains the private key.
    row=$(printf '%s' "$upload" | jq -ce --arg key "$id" --arg name "$name" '
      if type!="object" or ([(.private_key),(.address),(.public_key),(.allowed_ips),(.endpoint_address),(.endpoint_port)]|any(.==null or .=="")) then error("Incomplete WireGuard configuration") else
      {key:$key,des:$name,type:"wireguard",enable:"off",server:"",nat:(if has("nat") then .nat else true end),private_key,address,wg_dns:(.wg_dns//""),wg_dns_bk:(.wg_dns_bk//""),mtu:(.mtu//1420),public_key,preshared_key:(.preshared_key//""),allowed_ips,endpoint_address,endpoint_port,persistent_keepalive:(.persistent_keepalive//25)} end' 2>/dev/null) || fail 'WireGuard upload did not return all required fields; no profile inserted'
  fi
  unset upload
  if printf '%s' "$config" | jq -e '.data.supportVpnKillSwitch==true' >/dev/null; then
    row=$(printf '%s' "$row" | jq -c '.+{kill_switch:"off"}') || fail 'Cannot encode kill switch setting'
  fi
  # No secrets in the jq command line. Match the frontend insert at index 0.
  payload=$(printf '%s' "$row" | jq -sr '"operation=insert&index=0&new="+ (.[0]|tojson|@uri)') || fail 'Cannot encode profile insertion'
  api_data "$P" "$payload" >/dev/null || fail 'Profile creation not confirmed; inspect list before retrying'
  unset row payload
  after=$(profiles) || fail 'Profile insert accepted but readback failed; inspect list before retrying'
  result=$(profile "$after" "$id" 2>/dev/null) || fail 'Profile insert accepted but generated ID not found; inspect list before retrying'
  printf '%s' "$result" | jq -e --arg n "$name" --arg p "$proto" '.des==$n and .type==$p and .enable=="off"' >/dev/null || fail 'Profile readback differs from request; inspect list'
  printf '%s' "$result" | jq '{name:.des,protocol:.type,enabled:.enable,status,result:"Imported"}' | render_action
}

# Classic encrypted LuCI uses the operation in the encrypted body. Try the
# query-string form only for read operations when the first response fails.
read_object() {
  local path=$1 r
  if r=$(api_data "$path" operation=read) && printf %s "$r" | jq -e 'type=="object"' >/dev/null; then printf %s "$r"; return 0; fi
  if [[ $auth_mode == classic ]]; then
    if r=$(api_data "$path&operation=read" operation=read) && printf %s "$r" | jq -e 'type=="object"' >/dev/null; then printf %s "$r"; return 0; fi
  fi
  return 1
}
status_path='admin/status?form=all'; firmware_path='admin/firmware?form=upgrade'
# Optional reads preserve unknown values as null, not empty lists or false.
optional_read() { "$@" || printf 'null'; }
case "$cmd" in
  collect-vpn) collect_vpn;;
  info)
    f=$(optional_read read_object "$firmware_path")
    r=$(optional_read read_object "$status_path")
    a=$(optional_read profiles); b=$(optional_read policies); g=$(optional_read state)
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$f" "$r" "$config" "$a" "$b" "$g" | jq -s --arg auth "$auth_mode" --arg address "$router" 'def check: if .==null then "unconfirmed" else "ok" end; def count: if type=="array" then length else null end; {address:$address,authentication:$auth,model:(.[0].model//.[1].model),hardware_version:(.[0].hardware_version//.[1].hardware_version),firmware_version:(.[0].firmware_version//.[1].firmware_version),cpu_usage:.[1].cpu_usage,mem_usage:.[1].mem_usage,vpn_client:.[2].data.supportVpnClientType,vpn_server:.[2].data.supportVpnServerType,kill_switch_supported:.[2].data.supportVpnKillSwitch,certification:.[2].data.certification,global_enable:.[5].enable,profile_count:(.[3]|count),policy_count:(.[4]|count),api_reads:{firmware:(.[0]|check),status:(.[1]|check),capabilities:(.[2]|check),profiles:(.[3]|check),policies:(.[4]|check),vpn_enable:(.[5]|check)}}' | render_info
    if [[ $f == null && $r == null && $a == null && $b == null && $g == null ]]; then fail 'Authenticated, but no management endpoint was confirmed'; fi ;;
  list)
    a=$(profiles) || fail 'Cannot load profiles'
    printf %s "$a" | profile_view | render_profiles ;;
  status)
    a=$(profiles) || fail 'Cannot load profiles'; g=$(state) || fail 'Cannot read global VPN state'
    if [[ -n $arg1 ]]; then a=$(profile "$a" "$arg1" | jq -c '[.]') || fail 'Profile missing or ambiguous'; fi
    a=$(printf %s "$a" | profile_view)
    printf '%s\n%s\n' "$g" "$a" | jq -s '{global_enable:.[0].enable,profiles:.[1]}' | render_status ;;
  devices)
    r=$(optional_read read_object "$status_path")
    a=$(optional_read policies); if [[ $a != null ]]; then a=$(printf %s "$a" | policy_view); fi
    printf '%s\n%s\n' "$r" "$a" | jq -s 'def dev: {name:(.name//.hostname//.host_name),mac:(.mac//.macaddr//.mac_addr),ip:(.ip//.ipaddr//.ip_addr)}; def clients: if type=="array" then map(dev) else null end; {wired:(.[0].access_devices_wired|clients),wifi:(.[0].access_devices_wireless_host|clients),guest:(.[0].access_devices_wireless_guest|clients),vpn_whitelist:.[1]}' | render_devices
    if [[ $a == null ]] && ! printf %s "$r" | jq -e '[.access_devices_wired,.access_devices_wireless_host,.access_devices_wireless_guest]|any(type=="array")' >/dev/null; then fail 'No device endpoint confirmed'; fi ;;
  add) add_profile "$arg1" "$arg2";;
  start) set_profile "$arg1" on;;
  stop) set_profile "$arg1" off;;
  attach|connect|disconnect) manage_device "$cmd" "$arg1" "$arg2";;
  remove) if (( argc == 1 )); then remove_profile "$arg1"; else manage_device remove "$arg1" "$arg2"; fi;;
  bind|unbind) op=disconnect; [[ $cmd != bind ]] || op=connect; if (( argc == 2 )); then manage_device "$op" "$arg1" "$arg2"; else manage_device "$op" '' "$arg1"; fi;;
  enable) set_global on;;
  disable) set_global off;;
  inspect)
    f=$(optional_read read_object "$firmware_path"); r=$(optional_read read_object "$status_path")
    a=$(optional_read profiles); b=$(optional_read policies); g=$(optional_read state)
    printf '%s\n%s\n%s\n%s\n%s\n' "$a" "$b" "$g" "$f" "$r" | jq -s 'def schema: if type=="array" then (map(keys)|add//[]|unique) elif type=="object" then keys else null end; {profile_fields:(.[0]|schema),policy_fields:(.[1]|schema),global_fields:(.[2]|schema),firmware_fields:(.[3]|schema),status_fields:(.[4]|schema)}' | render_fields
    if [[ $f == null && $r == null && $a == null && $b == null && $g == null ]]; then fail 'No management endpoint confirmed'; fi ;;
esac
