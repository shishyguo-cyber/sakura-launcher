#!/usr/bin/env python3
"""Sign an update ZIP offline using the macOS system OpenSSL; never prints key material."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--key', type=Path, required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--platform', choices=['macOS', 'windows-x64'], required=True)
    p.add_argument('archive', type=Path)
    a = p.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', a.version):
        p.error('invalid version')
    supplied_key = a.key.expanduser()
    if supplied_key.is_symlink(): p.error("private key must not be a symlink")
    key = supplied_key.resolve()
    repo = Path(__file__).resolve().parents[1]
    if key.is_relative_to(repo) or key.stat().st_mode & 0o077 or key.is_symlink():
        p.error('private key must be outside repository, owner access only (chmod 600)')
    if a.archive.name != f'Sakura-{a.version}-{a.platform}.zip':
        p.error('archive name does not match version/platform')
    digest = hashlib.sha256()
    with a.archive.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): digest.update(block)
    manifest = dict(format=1, version=a.version, platform=a.platform, bytes=a.archive.stat().st_size, sha256=digest.hexdigest())
    message = f"Sakura Update v1\n{a.version}\n{a.platform}\n{manifest['bytes']}\n{manifest['sha256']}\n".encode()
    # Ensure the chosen private key corresponds to the public trust root committed with the app.
    public = subprocess.run(['/usr/bin/openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'], check=True, capture_output=True).stdout
    expected = (repo / 'launcher-spec/update-public-key.txt').read_text().strip()
    if base64.b64encode(public).decode() != expected:
        p.error('private key does not match the embedded public key')
    signature = subprocess.run(['/usr/bin/openssl', 'dgst', '-sha256', '-sign', str(key)], input=message, check=True, capture_output=True).stdout
    manifest['signature'] = base64.b64encode(signature).decode()
    a.archive.with_suffix('.zip.sig').write_text(json.dumps(manifest, sort_keys=True) + '\n')

if __name__ == '__main__': main()
