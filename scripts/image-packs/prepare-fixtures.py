#!/usr/bin/env python3
"""Fetch only publisher-pinned test ZIPs; never extract or execute their contents."""
import argparse
import hashlib
import json
import re
import time
import urllib.error
from pathlib import Path
import urllib.parse
import urllib.request

DESCRIPTOR_SHA256 = '1dd09bdc3deedc749a0a82900238f353b1c7febadc9a4112feba138ae40ef967'
MAXIMUM_TOTAL = 10_000_000

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Surface the response; never follow a publisher redirect.

# Legacy media links now redirect to a public landing page. Resolve only these
# release-approved asset IDs through Kenney's same-origin, short-lived flow.
PUBLISHER_PAGES = {
    'kenney.1-bit-scenery.v1': '1-bit-pack',
    'kenney.1-bit-expansion.v1': '1-bit-pack',
    'kenney.1-bit-platformer.v1': '1-bit-platformer-pack',
    'kenney.monochrome-rpg.v1': 'monochrome-rpg',
    'kenney.micro-roguelike.v1': 'micro-roguelike',
    'kenney.smoke-particles.v1': 'smoke-particles',
}
LEGACY_MEDIA = {
    '1-bit-pack': 'aa867a1f37-1677578516/kenney_1-bit-pack.zip',
    '1-bit-platformer-pack': '7c1e5f05a4-1677693072/kenney_1-bit-platformer-pack.zip',
    'monochrome-rpg': '03f49efc13-1674742619/kenney_monochrome-rpg.zip',
    'micro-roguelike': 'bbcaf50993-1677578239/kenney_micro-roguelike.zip',
    'smoke-particles': '23249a0d35-1677695171/kenney_smoke-particles.zip',
}
MAXIMUM_METADATA = 16 * 1024

def publisher_route(pack):
    slug = PUBLISHER_PAGES.get(pack.get('id'))
    if slug is None or pack.get('archiveURL') != 'https://kenney.nl/media/pages/assets/' + slug + '/' + LEGACY_MEDIA[slug]:
        raise ValueError('Unapproved publisher route')
    page = 'https://kenney.nl/assets/' + slug
    if pack.get('additional', {}).get('sourceURL', page) != page:
        raise ValueError('Unapproved publisher page')
    asset = ('assets/' + slug).encode('ascii').hex()
    return page, 'https://kenney.nl/download-link/' + asset, asset

def signed_publisher_url(value, asset, now=None):
    now = time.time() if now is None else now
    if not isinstance(value, str) or len(value.encode('utf-8')) > 2048:
        raise ValueError('Invalid publisher download metadata')
    url = urllib.parse.urlsplit(value)
    prefix = '/download/' + asset + '/'
    signature = url.path[len(prefix):] if url.path.startswith(prefix) else ''
    if (urllib.parse.urlunsplit(url) != value or
            url.scheme != 'https' or url.netloc != 'kenney.nl' or url.fragment or
            not re.fullmatch('[0-9a-f]{64}', signature) or
            not re.fullmatch('expires=[0-9]{1,12}', url.query)):
        raise ValueError('Unapproved publisher download route')
    expiry = int(url.query.removeprefix('expires='))
    if not now < expiry <= now + 900:
        raise ValueError('Expired or unexpected publisher download lifetime')
    return value

def _publisher_response(opener, url, limit, deadline, *, page=None, landing=None):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError('Publisher download timed out')
    headers = {'Accept': 'application/json' if page else 'application/zip'}
    if page is not None:
        headers['Referer'] = page
    request = urllib.request.Request(url, headers=headers)
    try:
        response = opener.open(request, timeout=min(30, remaining))
    except urllib.error.HTTPError as error:
        try:
            # No redirect request is followed. Only the exact known landing
            # Location unlocks a fresh metadata request constructed by the app.
            if (landing is not None and error.code == 302 and error.url == url and
                    error.headers.get('Location') == landing):
                return None
        finally:
            error.close()
        raise ValueError('Publisher response refused') from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ValueError('Publisher request failed') from None
    with response:
        if response.status != 200 or response.url != url:
            raise ValueError('Unexpected publisher response')
        length = response.headers.get('Content-Length')
        if length is not None and (not re.fullmatch('[0-9]{1,12}', length) or int(length) > limit):
            raise ValueError('Publisher response exceeds its byte limit')
        output = bytearray()
        while True:
            if time.monotonic() >= deadline:
                raise ValueError('Publisher download timed out')
            chunk = response.read(min(65536, limit - len(output) + 1))
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > limit:
                raise ValueError('Publisher response exceeds its byte limit')
        return bytes(output)

def fetch_pinned_archive(pack, opener=None):
    page, endpoint, asset = publisher_route(pack)
    size, digest = pack['archiveBytes'], pack['archiveSHA256']
    if type(size) is not int or not 0 < size <= MAXIMUM_TOTAL or not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('Invalid pinned archive bounds')
    opener = urllib.request.build_opener(NoRedirect()) if opener is None else opener
    deadline = time.monotonic() + 120
    archive = _publisher_response(opener, pack['archiveURL'], size, deadline, landing=page)
    if archive is None:
        metadata = _publisher_response(opener, endpoint, MAXIMUM_METADATA, deadline, page=page)
        try:
            record = json.loads(metadata)
        except (ValueError, UnicodeError):
            raise ValueError('Invalid publisher download metadata') from None
        if not isinstance(record, dict) or set(record) != {'url'}:
            raise ValueError('Invalid publisher download metadata')
        url = signed_publisher_url(record['url'], asset)
        archive = _publisher_response(opener, url, size, deadline)
    if len(archive) != size or hashlib.sha256(archive).hexdigest() != digest:
        raise ValueError('Publisher ZIP differs from approved fixture')
    return archive

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
            archive = fetch_pinned_archive(pack, opener)
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
