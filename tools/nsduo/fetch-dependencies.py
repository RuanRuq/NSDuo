#!/usr/bin/env python3
"""Fetch pinned upstream dependencies into this checkout, never global paths."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / '.toolchain/downloads'
CORE_COMMIT = 'f925129209afd55927a0201d82285b8fa4b7ba30'
CORE_SHA256 = 'd346679ee89427c9594ea711428393e9b4b0298329e00f0a628d1458ec7b8152'
DEPENDENCIES = 'src/MeloNX/MeloNX/Dependencies/'


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def fetch(url, destination, expected):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and sha256(destination) == expected:
        return destination
    partial = destination.with_name(destination.name + '.partial')
    subprocess.run(['curl', '--fail', '--location', '--proto', '=https',
                    '--tlsv1.2', '--retry', '2', '--connect-timeout', '30',
                    '--max-time', '600', url, '--output', str(partial)], check=True)
    if sha256(partial) != expected:
        partial.unlink(missing_ok=True)
        raise SystemExit(f'SHA-256 mismatch: {destination.name}')
    partial.replace(destination)
    return destination


def main():
    archive = fetch(f'https://codeload.github.com/nurtrino/MeloNX/tar.gz/{CORE_COMMIT}',
                    CACHE / f'MeloNX-{CORE_COMMIT}.tar.gz', CORE_SHA256)
    count = 0
    with tarfile.open(archive, 'r:gz') as bundle:
        for member in bundle:
            # Only copy this fixed dependency subtree. Ignore all upstream work,
            # workflows, repository metadata and unrelated documentation.
            parts = PurePosixPath(member.name).parts
            if len(parts) < 2 or parts[0] != f'MeloNX-{CORE_COMMIT}':
                continue
            relative = PurePosixPath(*parts[1:])
            if not str(relative).startswith(DEPENDENCIES):
                continue
            if '..' in relative.parts or relative.is_absolute():
                raise SystemExit('Unsafe path in dependency archive')
            if member.isdir():
                continue
            if not member.isfile():
                raise SystemExit(f'Unexpected archive entry: {relative}')
            destination = ROOT / relative
            # Do not follow a locally substituted directory/file symlink.
            if any(p.is_symlink() for p in [destination, *destination.parents] if p != ROOT.parent):
                raise SystemExit(f'Symlink in dependency destination: {relative}')
            destination.parent.mkdir(parents=True, exist_ok=True)
            with bundle.extractfile(member) as source, destination.open('wb') as output:
                shutil.copyfileobj(source, output)
            destination.chmod(member.mode & 0o777)
            count += 1
    if not count:
        raise SystemExit('No native dependencies found in pinned archive')
    legal = ROOT / 'distribution/legal/StikJIT'
    provenance = json.loads((legal / 'provenance.json').read_text())
    fetch(provenance['sourceURL'], legal / 'StikJIT-1.9.0-source.tar.gz',
          provenance['sourceArchiveSHA256'])
    print(f'Native dependencies ready ({count} files); pinned StikJIT source verified.')


if __name__ == '__main__':
    main()
