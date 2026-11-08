# nns-app source module: portable, root-only full-state backup / restore.
# Archives contain private CA/client keys. Treat them like root credentials.

nns_backup_archive_tool() {
    # All filesystem paths in production are fixed. The test prefix is only
    # accepted when this module is sourced without executing main().
    local test_root=""
    if [[ "${NNS_APP_SOURCE_ONLY:-0}" == 1 ]]; then
        test_root=${NNS_BACKUP_TEST_ROOT:-}
    fi
    python3 - "$@" "$test_root" <<'PY_NNS_ARCHIVE'
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile

operation = sys.argv[1]
arguments = sys.argv[2:-1]
test_root = sys.argv[-1]
BASE = 'nns-backup'
FORMAT = 'nns-app-full-backup-v1'
MAX_PAYLOAD = 8 * 1024**3


def location(absolute):
    if not absolute.startswith('/') or '\0' in absolute:
        raise ValueError('Invalid absolute destination')
    if test_root:
        return Path(test_root) / absolute.lstrip('/')
    return Path(absolute)


def fail(message):
    raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def is_managed_file(path):
    p = PurePosixPath('/' + path)
    parts = p.parts
    if len(parts) < 3:
        return False
    if parts[:3] in (('/', 'etc', 'nns-app'), ('/', 'var', 'lib')):
        # The /var/lib branch is restricted to nns-app below.
        if parts[:3] == ('/', 'etc', 'nns-app'):
            return True
    if parts[:4] in (('/', 'var', 'lib', 'nns-app'), ('/', 'var', 'cache', 'nns-app')):
        return True
    if parts[:3] == ('/', 'etc', 'netns') and len(parts) >= 5 and parts[3].startswith('nns-'):
        return True
    if parts[:3] == ('/', 'etc', 'sudoers.d') and len(parts) == 4 and parts[3].startswith('nns-app-'):
        return True
    if parts[:4] == ('/', 'etc', 'systemd', 'system') and len(parts) >= 6:
        # Custom and generated per-instance unit drop-ins. Unit templates are
        # generated from the archived engine, not copied over from the source.
        return parts[4].startswith('nns-') and parts[4].endswith('.d')
    return False


def read_cfg_assignment(path, name):
    try:
        raw = path.read_text(encoding='utf-8')
    except (OSError, UnicodeDecodeError):
        return ''
    match = re.search(r'^' + re.escape(name) + r'=(.*)$', raw, re.M)
    if not match:
        return ''
    try:
        values = shlex.split(match.group(1), posix=True)
    except ValueError:
        fail(f'Cannot parse {name} in {path}')
    return values[0] if len(values) == 1 else ''


def all_paths():
    base = location('/etc/nns-app')
    state = location('/var/lib/nns-app')
    cache = location('/var/cache/nns-app')
    roots = [base, state, cache]
    for folder, pattern in [
        ('/etc/netns', 'nns-*'),
        ('/etc/sudoers.d', 'nns-app-*'),
        ('/etc/systemd/system', 'nns-*.d'),
    ]:
        root = location(folder)
        if root.is_dir():
            roots += list(root.glob(pattern))
    return roots


def tree_files(roots):
    seen = set()
    for root in roots:
        if not root.exists() and not root.is_symlink():
            continue
        if root.is_symlink():
            fail(f'Symlink is not permitted in managed backup: {root}')
        if root.is_file():
            paths = [root]
        elif root.is_dir():
            paths = []
            for current, dirs, names in os.walk(root, followlinks=False):
                for name in dirs + names:
                    path = Path(current) / name
                    if path.is_symlink():
                        fail(f'Symlink is not permitted in managed backup: {path}')
                    if not (path.is_file() or path.is_dir()):
                        fail(f'Non-regular managed entry: {path}')
                paths.extend(Path(current) / name for name in names)
        else:
            fail(f'Non-regular managed entry: {root}')
        for file in paths:
            relative = '/' + str(file.relative_to(test_root)) if test_root else str(file)
            if not is_managed_file(relative.lstrip('/')):
                fail(f'Unexpected managed path: {relative}')
            if file in seen:
                continue
            seen.add(file)
            if not file.is_file():
                fail(f'Not a regular file: {file}')
            yield relative.lstrip('/'), file


def service_states():
    result = []
    configs = [('/etc/nns-app', re.compile(r'^([A-Za-z0-9][A-Za-z0-9._-]{0,31})$'),
                ['nns-netns@{}.service', 'nns-openvpn@{}.service',
                 'nns-online@{}.service', 'nns-watchdog@{}.timer',
                 'nns-mtu@{}.timer']),
               ('/etc/nns-app/gateways', re.compile(r'^([A-Za-z0-9][A-Za-z0-9._-]{0,31})$'),
                ['nns-gateway@{}.service', 'nns-gateway-crl-refresh@{}.timer'])]
    for base, matcher, units in configs:
        root = location(base)
        if not root.is_dir():
            continue
        for folder in sorted(root.iterdir()):
            if not folder.is_dir() or not matcher.fullmatch(folder.name):
                continue
            if base.endswith('/gateways'):
                config = folder / 'gateway.cfg'
            else:
                config = folder / (folder.name + '.cfg')
            if not config.is_file():
                continue
            for fmt in units:
                unit = fmt.format(folder.name)
                def call(*args):
                    try:
                        return subprocess.run(['systemctl', *args, unit],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=5).returncode == 0
                    except (OSError, subprocess.TimeoutExpired):
                        return False
                result.append({'unit': unit, 'enabled': call('is-enabled', '--quiet'),
                               'active': call('is-active', '--quiet')})
    return result


def allowed_unit(unit):
    return bool(re.fullmatch(
        r'nns-(?:netns|openvpn|online|watchdog|mtu|gateway|gateway-crl-refresh)@'
        r'[A-Za-z0-9][A-Za-z0-9._-]{0,31}\.(?:service|timer)', unit))


def archive_bytes(tar, key, payload, mode=0o600):
    info = tarfile.TarInfo(BASE + '/' + key)
    info.size = len(payload)
    info.mode = mode
    info.uid = 0
    info.gid = 0
    tar.addfile(info, io.BytesIO(payload))


def create(destination, engine):
    dest = Path(destination)
    if dest.is_symlink() or dest.exists():
        fail(f'Backup destination already exists: {dest}')
    if not dest.parent.is_dir():
        fail(f'Backup directory does not exist: {dest.parent}')
    if Path(engine).is_symlink() or not Path(engine).is_file():
        fail('The currently running engine is not a regular file')
    items = {}
    for name, path in tree_files(all_paths()):
        items['files/' + name] = path
    keys = []
    managed_roots = ['/etc/nns-app/', '/var/lib/nns-app/', '/var/cache/nns-app/']
    config_names = ('SSH_IDENTITY', 'TRANSPORT_SSH_IDENTITY')
    for relative, path in tree_files([location('/etc/nns-app')]):
        if not relative.endswith('.cfg'):
            continue
        for field in config_names:
            external = read_cfg_assignment(path, field)
            if not external or external == 'none':
                continue
            if not external.startswith('/'):
                fail(f'Non-absolute SSH key reference in {path}: {external}')
            if any((external + '/').startswith(prefix) for prefix in managed_roots):
                continue
            if any(key['source'] == external for key in keys):
                continue
            key_path = location(external)
            if key_path.is_symlink() or not key_path.is_file():
                fail(f'Referenced external SSH key is missing or unsafe: {external}')
            key_id = sha256(external.encode())[:20]
            key_entry = 'external/' + key_id + '.key'
            items[key_entry] = key_path
            keys.append({'source': external, 'archive': key_entry, 'id': key_id})
    items['engine.sh'] = Path(engine)
    files = {}
    total = 0
    for name, path in sorted(items.items()):
        digest = hashlib.sha256()
        count = 0
        with path.open('rb') as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                count += len(chunk)
                if count + total > MAX_PAYLOAD:
                    fail('Backup payload exceeds the 8 GiB safety limit')
                digest.update(chunk)
        files[name] = {'sha256': digest.hexdigest(), 'size': count,
                       'mode': stat.S_IMODE(path.stat().st_mode)}
        total += count
    manifest = {
        'format': FORMAT, 'engine_version': str(Path(engine).name),
        'files': files,
        'external_keys': keys,
        'services': service_states(),
    }
    import tempfile
    fd, temp_name = tempfile.mkstemp(prefix='.' + dest.name + '.', dir=dest.parent)
    os.fchmod(fd, 0o600)
    os.close(fd)
    try:
        with tarfile.open(temp_name, 'w:gz', compresslevel=6) as tar:
            archive_bytes(tar, 'manifest.json', json.dumps(manifest, indent=2, sort_keys=True).encode())
            for name, path in sorted(items.items()):
                info = tarfile.TarInfo(BASE + '/' + name)
                info.size = files[name]['size']
                info.mode = 0o700 if name == 'engine.sh' else 0o600
                info.uid = info.gid = 0
                class CheckedReader:
                    def __init__(self, source):
                        self.source = source
                        self.digest = hashlib.sha256()
                    def read(self, length):
                        chunk = self.source.read(length)
                        self.digest.update(chunk)
                        return chunk
                with path.open('rb') as source:
                    reader = CheckedReader(source)
                    tar.addfile(info, reader)
                    if reader.digest.hexdigest() != files[name]['sha256']:
                        fail(f'File changed during backup: {path}')
        os.replace(temp_name, dest)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
    print(f'Backup written: {dest}')
    print(f'Entries: {len(items)}; services: {len(manifest["services"])}; external SSH keys: {len(keys)}')
    print('WARNING: Archive contains private VPN keys, certificates and credentials. Keep it encrypted and access-restricted.')


def extract(archive, stage):
    staging = Path(stage)
    staging.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tarfile.open(archive, 'r:gz') as tar:
        members = {}
        for member in tar:
            if not member.isfile() or member.name in members:
                fail(f'Unsafe, duplicate or non-file archive entry: {member.name}')
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or '\\' in member.name:
                fail(f'Unsafe path in archive: {member.name}')
            if member.size < 0 or member.size > MAX_PAYLOAD:
                fail(f'Unsafe archive size: {member.name}')
            members[member.name] = member
        manifest_key = BASE + '/manifest.json'
        if manifest_key not in members or members[manifest_key].size > 16 * 1024 * 1024:
            fail('Missing or oversized backup manifest')
        manifest = json.loads(tar.extractfile(members[manifest_key]).read())
        if manifest.get('format') != FORMAT:
            fail('Unsupported backup format')
        payload = manifest.get('files')
        if not isinstance(payload, dict) or not payload:
            fail('Backup manifest has no payload')
        if set(members) != {manifest_key} | {BASE + '/' + p for p in payload}:
            fail('Archive content does not match the manifest')
        if 'engine.sh' not in payload:
            fail('Backup is missing the self-contained nns-app engine')
        for key in payload:
            if not isinstance(key, str) or (
                not key.startswith('files/') and
                not re.fullmatch(r'external/[0-9a-f]{20}\.key', key) and
                key != 'engine.sh'):
                fail(f'Unrecognized archive entry: {key}')
            if key.startswith('files/') and not is_managed_file(key[6:]):
                fail(f'Unexpected destination inside backup: {key}')
        keys = manifest.get('external_keys', [])
        if not isinstance(keys, list):
            fail('Invalid external key metadata')
        for record in keys:
            if not isinstance(record, dict) or not isinstance(record.get('source'), str):
                fail('Invalid external key record')
            if not record['source'].startswith('/') or record.get('archive') not in payload:
                fail('Invalid external key reference')
        services = manifest.get('services', [])
        if not isinstance(services, list) or any(
            not isinstance(item, dict) or not allowed_unit(item.get('unit', '')) or
            type(item.get('enabled')) is not bool or type(item.get('active')) is not bool
            for item in services):
            fail('Invalid service-state metadata')
        total = 0
        for name, info in sorted(payload.items()):
            member = members[BASE + '/' + name]
            if not isinstance(info, dict) or member.size != info.get('size'):
                fail(f'Incorrect file size: {name}')
            mode = info.get('mode')
            if not isinstance(mode, int) or mode < 0 or mode > 0o777 or (mode & 0o022):
                fail(f'Unsafe or missing file permissions: {name}')
            total += member.size
            if total > MAX_PAYLOAD:
                fail('Backup exceeds 8 GiB extraction limit')
            out = staging / name
            out.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            with tar.extractfile(member) as source, out.open('wb') as target:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                    target.write(chunk)
            if digest.hexdigest() != info.get('sha256'):
                fail(f'Backup checksum mismatch: {name}')
            out.chmod(0o700 if name == 'engine.sh' else 0o600)
    (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(f'Validated backup: {len(payload)} files, {len(services)} services, {len(keys)} external keys')


def apply(stage):
    staging = Path(stage)
    manifest = json.loads((staging / 'manifest.json').read_text())
    files = [name for name in manifest['files'] if name.startswith('files/')]
    roots = [location('/etc/nns-app'), location('/var/lib/nns-app'),
             location('/var/cache/nns-app')]
    # Never silently merge with an existing installation; such a merge can
    # replace the CA/PKI of a live server, invalidating all its clients.
    for root in roots:
        if root.is_symlink():
            fail(f'Symlink destination rejected: {root}')
        if root.is_dir() and any(p.is_file() or p.is_symlink() for p in root.rglob('*')):
            fail(f'Nonempty nns-app state at {root}; restore only to a clean machine')
        if root.exists() and not root.is_dir():
            fail(f'Invalid destination: {root}')
    for name in files:
        relative = name[len('files/'):]
        target = location('/' + relative)
        # The entire destination ancestry must not contain a symlink.
        for parent in (target, *target.parents):
            if parent.is_symlink():
                fail(f'Symlink destination rejected: {parent}')
            if parent == location('/'):
                break
        if target.exists():
            fail(f'Restore would overwrite an existing file: {target}')
    # Apply only after completing ALL destination checks.
    for name in sorted(files):
        relative = name[len('files/'):]
        target = location('/' + relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(staging / name, target)
        target.chown(0, 0) if not test_root else None
        # Mode is part of the backup: CRLs and public certs must remain
        # readable after OpenVPN drops privileges, unlike private key files.
        target.chmod(manifest['files'][name]['mode'])
    for record in manifest['external_keys']:
        key_path = location('/etc/nns-app/restored-keys/' + record['id'] + '.key')
        key_path.parent.mkdir(parents=True, exist_ok=True)
        key_path.write_bytes((staging / record['archive']).read_bytes())
        key_path.chmod(0o600)
        if not test_root:
            key_path.chown(0, 0)
    # Repoint references to root-owned restored copies, not arbitrary paths in
    # the original machine's user home directory.
    for name in files:
        if not name.endswith('.cfg') or not name.startswith('files/etc/nns-app/'):
            continue
        cfg = location('/' + name[len('files/'):])
        source = cfg.read_text()
        for record in manifest['external_keys']:
            destination = '/etc/nns-app/restored-keys/' + record['id'] + '.key'
            for field in ('SSH_IDENTITY', 'TRANSPORT_SSH_IDENTITY'):
                if read_cfg_assignment(cfg, field) == record['source']:
                    source = re.sub(r'^' + field + r'=.*$', field + '=' + shlex.quote(destination),
                                    source, flags=re.M)
        cfg.write_text(source)
    print(f'Restored persistent state and credentials: {len(files)} files')


def restore_system_files(stage):
    # Reapply custom systemd and sudoers overrides after install_engine has
    # regenerated default templates and per-app drop-ins.
    staging = Path(stage)
    manifest = json.loads((staging / 'manifest.json').read_text())
    for name in sorted(manifest['files']):
        if not (name.startswith('files/etc/systemd/system/') or
                name.startswith('files/etc/sudoers.d/')):
            continue
        relative = name[6:]
        target = location('/' + relative)
        if target.is_symlink() or any(p.is_symlink() for p in target.parents):
            fail(f'Unsafe system override destination: {target}')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(staging / name, target)
        target.chmod(0o440 if relative.startswith('etc/sudoers.d/') else 0o644)
        if not test_root:
            target.chown(0, 0)


try:
    if operation == 'create' and len(arguments) == 2:
        create(*arguments)
    elif operation == 'extract' and len(arguments) == 2:
        extract(*arguments)
    elif operation == 'apply' and len(arguments) == 1:
        apply(*arguments)
    elif operation == 'overrides' and len(arguments) == 1:
        restore_system_files(*arguments)
    else:
        fail('Invalid backup tool invocation')
except (OSError, ValueError, KeyError, tarfile.TarError, json.JSONDecodeError) as exc:
    print('ERROR: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY_NNS_ARCHIVE
}

nns_backup() {
    require_root
    local output="" gateway dir
    while (( $# > 0 )); do
        case "$1" in
            --output|-o)
                (( $# >= 2 )) || die "--output requires a .tar.gz filename."
                output=$2; shift 2 ;;
            --output=*) output=${1#--output=}; shift ;;
            *) die "Usage: nns-app backup --output <file.tar.gz>" ;;
        esac
    done
    [[ -n "$output" && "$output" == /* ]] ||
        die "Backup output must be an absolute path, e.g. /var/backups/nns-backup.tar.gz."
    [[ "$output" != /etc/nns-app/* && "$output" != /var/lib/nns-app/* ]] ||
        die "Keep backup archives outside managed state."
    acquire_lock global
    # Use the gateway locks that protect CA/PKI/client modification, so the
    # archive cannot mix an old index with newly issued certificates.
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" ]] || continue
        gateway=${dir##*/}
        acquire_lock "gateway-$gateway"
    done
    nns_backup_archive_tool create "$output" "$(readlink -f "$0")"
}

nns_restore_missing_users() {
    local cfg user
    shopt -s nullglob
    for cfg in "$BASE_DIR"/*/*.cfg; do
        [[ -f "$cfg" ]] || continue
        user=$(sed -nE 's/^APP_USER="?([a-z_][a-z0-9_-]*)"?$/\1/p' "$cfg" | head -n1)
        [[ -n "$user" ]] || die "Unsupported APP_USER in restored configuration: $cfg"
        if ! id "$user" >/dev/null 2>&1; then
            [[ "$user" != root ]] || die "Missing root account."
            useradd --create-home --user-group --shell /bin/bash \
                --password '!' "$user" || die "Cannot create account '$user'."
            warn "Created locked local account '$user'; configure its login credentials separately if needed."
        fi
    done
}

nns_restore_services() {
    local stage=$1 no_start=$2 line unit enabled active
    local -a first=() next=() last=()
    # Read the already validated manifest using JSON rather than sourcing
    # arbitrary shell commands from the archive.
    while IFS=$'\t' read -r unit enabled active; do
        [[ -n "$unit" ]] || continue
        if [[ "$enabled" == true ]]; then
            systemctl enable "$unit" >/dev/null || warn "Could not enable $unit"
        else
            systemctl disable "$unit" >/dev/null 2>&1 || true
        fi
        [[ "$active" == true && "$no_start" != on ]] || continue
        case "$unit" in
            nns-netns@*.service) first+=("$unit") ;;
            nns-openvpn@*.service|nns-online@*.service|nns-gateway@*.service)
                next+=("$unit") ;;
            *) last+=("$unit") ;;
        esac
    done < <(python3 - "$stage/manifest.json" <<'PY_NNS_SERVICES'
import json, sys
for service in json.load(open(sys.argv[1]))['services']:
    print(service['unit'] + '\t' + str(service['enabled']).lower() + '\t' + str(service['active']).lower())
PY_NNS_SERVICES
    )
    if [[ "$no_start" == on ]]; then
        log "Services restored but not started (--no-start). Enabled-state is preserved."
        return 0
    fi
    local errors=0
    for unit in "${first[@]}" "${next[@]}" "${last[@]}"; do
        if ! systemctl start "$unit"; then
            warn "Restored service did not start: $unit"
            errors=$((errors + 1))
        fi
    done
    (( errors == 0 )) || die "Restored state, but $errors service(s) failed to start. Check journalctl and nns-app status."
}

nns_restore() {
    require_root
    local archive=${1:-} no_start=off stage
    [[ -n "$archive" && "$archive" != --* ]] ||
        die "Usage: nns-app restore <backup.tar.gz> [--no-start]"
    shift
    while (( $# > 0 )); do
        case "$1" in
            --no-start) no_start=on; shift ;;
            *) die "Usage: nns-app restore <backup.tar.gz> [--no-start]" ;;
        esac
    done
    [[ -f "$archive" && ! -L "$archive" ]] || die "Backup archive is missing or a symlink: $archive"
    acquire_lock global
    stage=$(mktemp -d /tmp/nns-restore.XXXXXXXX)
    chmod 0700 "$stage"
    NNS_RESTORE_TEMP_PATH=$stage
    trap '[[ -z "${NNS_RESTORE_TEMP_PATH:-}" ]] || rm -rf -- "$NNS_RESTORE_TEMP_PATH"' EXIT
    # The archive is fully validated and checksummed before any host changes.
    if ! nns_backup_archive_tool extract "$archive" "$stage"; then
        rm -rf -- "$stage"
        die "Backup validation failed; no system configuration was changed."
    fi
    # Check for existing nns state before installing packages or unit files.
    if [[ -d "$BASE_DIR" ]] && find "$BASE_DIR" -mindepth 1 \( -type f -o -type l \) -print -quit | grep -q .; then
        rm -rf -- "$stage"
        die "Existing nns-app configuration found. Restore is supported on a clean machine only."
    fi
    if [[ -d "$STATE_DIR" ]] && find "$STATE_DIR" -mindepth 1 \( -type f -o -type l \) -print -quit | grep -q .; then
        rm -rf -- "$stage"
        die "Existing nns-app state found. Restore is supported on a clean machine only."
    fi
    ensure_dependencies
    nns_backup_archive_tool apply "$stage" || die "Restore failed while copying managed data."
    nns_restore_missing_users
    NNS_RESTORE_IN_PROGRESS=on install_engine off
    nns_backup_archive_tool overrides "$stage"
    systemctl daemon-reload
    nns_restore_services "$stage" "$no_start"
    rm -rf -- "$stage"
    NNS_RESTORE_TEMP_PATH=""
    trap - EXIT
    log "Restored nns-app configuration, gateways, client certificates, fixed IPs, remote state, and startup policy."
    warn "Review public endpoints, uplink interfaces, SSH remote access, and firewall rules after migrating to different hardware/network."
    warn "The backup covers this host; managed peer machines must be backed up separately."
}
