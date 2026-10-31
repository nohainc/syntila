#!/usr/bin/env python3
"""Create a signed, static APT repository. Existing pool versions are retained.

Build into a staging copy and publish the whole tree atomically on the host.
The key must already exist in GNUPGHOME; no private key enters this output.
"""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import gzip
import hashlib
from pathlib import Path
import re
import shutil
import subprocess


# The headless unit and the desktop GUI that installs beside it.
PACKAGES = ('syntila', 'syntila-gui')


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def metadata(path):
    fields = run('dpkg-deb', '--field', str(path))
    parsed = dict(line.split(': ', 1) for line in fields.splitlines()
                  if ': ' in line and not line.startswith(' '))
    if parsed.get('Package') not in PACKAGES or parsed.get('Architecture') not in ('amd64', 'arm64'):
        raise ValueError(f'Unexpected package: {path}')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+([+~.-][A-Za-z0-9.+~-]+)?', parsed['Version']):
        raise ValueError('Invalid package version')
    return fields, parsed


def build(output, packages, key):
    pool = output / 'pool/main/c/syntila'
    pool.mkdir(parents=True, exist_ok=True)
    for source in packages:
        _, info = metadata(source)
        dest = pool / f"{info['Package']}_{info['Version']}_{info['Architecture']}.deb"
        if dest.exists() and dest.read_bytes() != source.read_bytes():
            raise ValueError(f'Refusing to replace immutable package: {dest.name}')
        if source.resolve() != dest.resolve():
            shutil.copyfile(source, dest)
    indexes = {arch: [] for arch in ('amd64', 'arm64')}
    for path in sorted(pool.glob('*.deb')):
        fields, info = metadata(path)
        content = path.read_bytes()
        indexes[info['Architecture']].append(
            f'{fields}\nFilename: {path.relative_to(output).as_posix()}\n'
            f'Size: {len(content)}\nSHA256: {hashlib.sha256(content).hexdigest()}\n\n')
    hashes = []
    for arch, entries in indexes.items():
        relative = Path(f'main/binary-{arch}/Packages')
        path = output / 'dists/stable' / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        raw = ''.join(entries).encode()
        for suffix, content in (('', raw), ('.gz', gzip.compress(raw, mtime=0))):
            target = Path(str(path) + suffix)
            target.write_bytes(content)
            by_hash = target.parent / 'by-hash/SHA256' / hashlib.sha256(content).hexdigest()
            by_hash.parent.mkdir(parents=True, exist_ok=True)
            by_hash.write_bytes(content)
            hashes.append(f' {hashlib.sha256(content).hexdigest()} {len(content)} {relative}{suffix}')
    now = datetime.now(timezone.utc)
    release = output / 'dists/stable/Release'
    # No Valid-Until: a vendor repo can have quiet release periods. HTTPS and
    # signed metadata protect transport; renew metadata on each release.
    release.write_text('Origin: Syntila\nLabel: Syntila Workspace\nSuite: stable\nCodename: stable\n'
                       f'Date: {format_datetime(now, usegmt=True)}\n'
                       'Architectures: amd64 arm64\nComponents: main\nAcquire-By-Hash: yes\n'
                       'Description: Syntila Workspace packages\nSHA256:\n' + '\n'.join(hashes) + '\n')
    public_key = subprocess.check_output(['gpg', '--batch', '--export', key])
    if not public_key:
        raise ValueError('Signing key has no exportable public key')
    (output / 'syntila-archive-keyring.gpg').write_bytes(public_key)
    for mode, target in (('--clearsign', release.with_name('InRelease')),
                         ('--detach-sign', release.with_name('Release.gpg'))):
        subprocess.run(['gpg', '--batch', '--yes', '--local-user', key, '--digest-algo', 'SHA256',
                        '--output', str(target), mode, str(release)], check=True)
    subprocess.run(['gpgv', '--keyring', str((output / 'syntila-archive-keyring.gpg').resolve()),
                    str(release.with_name('InRelease'))], check=True)
    (output / '.nojekyll').touch()
    print(f'Signed APT repository: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--signing-key', required=True, help='Full OpenPGP signing-key fingerprint')
    parser.add_argument('packages', type=Path, nargs='+')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Fa-f0-9]{40,64}', args.signing_key):
        parser.error('Use the full signing-key fingerprint')
    build(args.output, args.packages, args.signing_key)
