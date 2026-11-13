#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_BACKUP_TEST_ROOT="$TMP/source"
export NNS_APP_LOCK_DIR="$TMP/locks"
source "$ROOT/install_linux"

mkdir -p "$NNS_BACKUP_TEST_ROOT/etc/nns-app/gateways/server1/pki/private" \
 "$NNS_BACKUP_TEST_ROOT/etc/nns-app/gateways/server1/clients/phone" \
 "$NNS_BACKUP_TEST_ROOT/etc/nns-app/gateways/server1/ccd" \
 "$NNS_BACKUP_TEST_ROOT/etc/nns-app/client1/profiles" \
 "$NNS_BACKUP_TEST_ROOT/etc/nns-app/remotes/example" \
 "$NNS_BACKUP_TEST_ROOT/etc/systemd/system/nns-gateway@server1.service.d" \
 "$NNS_BACKUP_TEST_ROOT/etc/sudoers.d" \
 "$NNS_BACKUP_TEST_ROOT/var/lib/nns-app/remote-auto" \
 "$NNS_BACKUP_TEST_ROOT/var/cache/nns-app" \
 "$NNS_BACKUP_TEST_ROOT/home/sample/.ssh"
cat > "$NNS_BACKUP_TEST_ROOT/etc/nns-app/client1/client1.cfg" <<'EOF'
APP_NAME="client1"
APP_USER="sample"
TRANSPORT_SSH_IDENTITY=""
EOF
cat > "$NNS_BACKUP_TEST_ROOT/etc/nns-app/gateways/server1/gateway.cfg" <<'EOF'
GATEWAY_NAME="server1"
CLIENT_TO_CLIENT="on"
EOF
cat > "$NNS_BACKUP_TEST_ROOT/etc/nns-app/remotes/example/remote.cfg" <<'EOF'
SSH_IDENTITY=/home/sample/.ssh/remote-id
EOF
printf 'PRIVATECA\0KEY\n' > "$NNS_BACKUP_TEST_ROOT/etc/nns-app/gateways/server1/pki/private/ca.key"
printf 'CERT-KEY' > "$NNS_BACKUP_TEST_ROOT/etc/nns-app/gateways/server1/clients/phone/key.pem"
printf 'ifconfig-push 10.253.1.128 255.255.255.0\n' > "$NNS_BACKUP_TEST_ROOT/etc/nns-app/gateways/server1/ccd/phone"
printf 'OVPN-CLIENT' > "$NNS_BACKUP_TEST_ROOT/etc/nns-app/client1/profiles/base.ovpn"
printf 'AUTOPOOL' > "$NNS_BACKUP_TEST_ROOT/var/lib/nns-app/remote-auto/owner.cfg"
printf 'CACHE' > "$NNS_BACKUP_TEST_ROOT/var/cache/nns-app/data"
printf 'SUDORULE' > "$NNS_BACKUP_TEST_ROOT/etc/sudoers.d/nns-app-client1"
printf '[Service]\nEnvironment=TEST=1\n' > "$NNS_BACKUP_TEST_ROOT/etc/systemd/system/nns-gateway@server1.service.d/90-test.conf"
printf 'SSHPRIVATE' > "$NNS_BACKUP_TEST_ROOT/home/sample/.ssh/remote-id"
chmod 0600 "$NNS_BACKUP_TEST_ROOT/etc/nns-app/gateways/server1/pki/private/ca.key"
archive="$TMP/backup.tar.gz"
nns_backup_archive_tool create "$archive" "$ROOT/install_linux"
[[ $(stat -c '%a' "$archive") == 600 ]]
python3 - "$archive" <<'PY'
import json,sys,tarfile
with tarfile.open(sys.argv[1]) as t:
    m=json.load(t.extractfile('nns-backup/manifest.json'))
    assert m['format']=='nns-app-full-backup-v1'
    assert len(m['external_keys'])==1, m['external_keys']
    assert any(s['unit']=='nns-gateway@server1.service' for s in m['services'])
    assert 'files/etc/nns-app/gateways/server1/ccd/phone' in m['files']
PY
nns_backup_archive_tool extract "$archive" "$TMP/stage"
[[ $(cat "$TMP/stage/files/etc/nns-app/gateways/server1/ccd/phone") == *10.253.1.128* ]]
export NNS_BACKUP_TEST_ROOT="$TMP/target"
nns_backup_archive_tool apply "$TMP/stage"
nns_backup_archive_tool overrides "$TMP/stage"
[[ $(stat -c '%a' "$TMP/target/etc/nns-app/gateways/server1/pki/private/ca.key") == 600 ]]
[[ $(stat -c '%a' "$TMP/target/etc/nns-app/gateways/server1/gateway.cfg") == 644 ]]
[[ $(stat -c '%a' "$TMP/target/etc/sudoers.d/nns-app-client1") == 440 ]]
[[ $(cat "$TMP/target/etc/nns-app/gateways/server1/clients/phone/key.pem") == CERT-KEY ]]
[[ $(cat "$TMP/target/etc/nns-app/client1/profiles/base.ovpn") == OVPN-CLIENT ]]
[[ $(cat "$TMP/target/var/lib/nns-app/remote-auto/owner.cfg") == AUTOPOOL ]]
[[ $(cat "$TMP/target/var/cache/nns-app/data") == CACHE ]]
# Preserve service enabled/running state; --no-start never starts units.
python3 - "$TMP/stage/manifest.json" <<'PY_STATE'
import json,sys
f=sys.argv[1]
m=json.load(open(f))
for entry in m['services']:
    entry['enabled'] = True
    entry['active'] = entry['unit'].endswith('.service')
with open(f,'w') as out: json.dump(m,out)
PY_STATE
systemctl() { printf "%s " "$@" >>"$TMP/systemctl.log"; printf "\n" >>"$TMP/systemctl.log"; }
nns_restore_services "$TMP/stage" on >/dev/null
! grep -q '^start ' "$TMP/systemctl.log"
grep -Fq 'enable nns-gateway@server1.service' "$TMP/systemctl.log"
: >"$TMP/systemctl.log"
nns_restore_services "$TMP/stage" off >/dev/null
grep -Fq 'start nns-gateway@server1.service' "$TMP/systemctl.log"
grep -q '/etc/nns-app/restored-keys/' "$TMP/target/etc/nns-app/remotes/example/remote.cfg"
[[ $(find "$TMP/target/etc/nns-app/restored-keys" -type f | wc -l) == 1 ]]
# Existing persistent state is never silently overwritten.
if nns_backup_archive_tool apply "$TMP/stage" >"$TMP/merge.log" 2>&1; then
  echo 'unexpectedly allowed merge over existing configuration' >&2
  exit 1
fi
# Malicious archive entries are rejected before any write.
python3 - "$TMP/evil.tar.gz" <<'PY'
import tarfile,sys
with tarfile.open(sys.argv[1], 'w:gz') as t:
    item=tarfile.TarInfo('nns-backup/files/etc/nns-app/evil')
    item.type=tarfile.SYMTYPE
    item.linkname='/etc/shadow'
    t.addfile(item)
PY
if nns_backup_archive_tool extract "$TMP/evil.tar.gz" "$TMP/evil-stage" >"$TMP/evil.log" 2>&1; then
  echo 'unexpectedly accepted symlink entry' >&2
  exit 1
fi
# Byte corruption is rejected by sha256 validation.
python3 - "$archive" "$TMP/corrupt.tar.gz" <<'PY'
import io,tarfile,sys
with tarfile.open(sys.argv[1]) as src, tarfile.open(sys.argv[2], 'w:gz') as dst:
    for m in src:
        data=src.extractfile(m).read()
        if m.name.endswith('key.pem'):
            data=b'CORRUPT!'
        m.size=len(data)
        dst.addfile(m, io.BytesIO(data))
PY
if nns_backup_archive_tool extract "$TMP/corrupt.tar.gz" "$TMP/corrupt-stage" >"$TMP/corrupt.log" 2>&1; then
  echo 'unexpectedly accepted corrupt backup' >&2
  exit 1
fi
printf 'PASS: full state, server/client PKI, fixed IPs, external keys, mode, overwrite and tamper guards\n'
