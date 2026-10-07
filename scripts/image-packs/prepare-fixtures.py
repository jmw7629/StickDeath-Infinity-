#!/usr/bin/env python3
"""Fetch only publisher-pinned test ZIPs; never extract or execute their contents."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request

DESCRIPTOR_SHA256 = '1dd09bdc3deedc749a0a82900238f353b1c7febadc9a4112feba138ae40ef967'
MAXIMUM_TOTAL = 10_000_000

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Publisher redirect rejected')

def checked(path, size, digest):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != size:
        return False
    return hashlib.sha256(path.read_bytes()).hexdigest() == digest

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('descriptor', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--legacy-archive', type=Path)
    args = parser.parse_args()
    data = args.descriptor.read_bytes()
    if hashlib.sha256(data).hexdigest() != DESCRIPTOR_SHA256:
        raise ValueError('Unapproved descriptor resource')
    packs = json.loads(data)
    if len(packs) != 5 or sum(p['archiveBytes'] for p in packs) > MAXIMUM_TOTAL:
        raise ValueError('Fixture download budget exceeded')
    if args.output.is_symlink():
        raise ValueError('Fixture output cannot be a symlink')
    args.output.mkdir(parents=True, exist_ok=True)
    mapping = {}
    opener = urllib.request.build_opener(NoRedirect())
    for pack in packs:
        size, digest = pack['archiveBytes'], pack['archiveSHA256']
        source = args.legacy_archive
        if source is not None and checked(source, size, digest):
            mapping[pack['id']] = str(source.resolve())
            continue
        destination = args.output / (digest + '.zip')
        if not checked(destination, size, digest):
            if destination.exists() or destination.is_symlink():
                raise ValueError('Existing corrupt fixture preserved for diagnosis')
            url = pack['archiveURL']; parsed = urllib.parse.urlsplit(url)
            if parsed.scheme != 'https' or parsed.netloc != 'kenney.nl' or parsed.query or parsed.fragment:
                raise ValueError('Unapproved publisher URL')
            with opener.open(url, timeout=30) as response:
                if response.status != 200 or response.url != url:
                    raise ValueError('Unexpected publisher response')
                archive = response.read(size + 1)
            if len(archive) != size or hashlib.sha256(archive).hexdigest() != digest:
                raise ValueError('Publisher ZIP differs from approved fixture')
            with destination.open('xb') as output:
                output.write(archive)
        mapping[pack['id']] = str(destination.resolve())
    manifest = args.output / 'archive-paths.json'
    encoded = json.dumps(mapping, sort_keys=True, indent=2) + '\n'
    if manifest.exists():
        if manifest.read_text() != encoded:
            raise ValueError('Existing fixture mapping preserved for diagnosis')
    else:
        with manifest.open('x') as output:
            output.write(encoded)
    print(manifest)

if __name__ == '__main__':
    main()
