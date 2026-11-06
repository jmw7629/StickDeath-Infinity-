#!/usr/bin/env python3
"""Offline cases against the real fixture preparer's publisher transport."""
import importlib.util
import io
import json
import os
from pathlib import Path
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('sdi_prepare', ROOT / 'scripts/image-packs/prepare-fixtures.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
RESOURCE = Path(os.environ.get('SDI_IMAGE_PACK_RESOURCE', ROOT / 'StickDeathInfinity/Resources/StudioImages/remote-pack.json'))
ARCHIVE = Path(os.environ.get('SDI_IMAGE_PACK_ARCHIVE', ROOT / 'Tests/StudioImagePack/Fixtures/kenney-1-bit-pack.zip'))

class Response(io.BytesIO):
    status = 200
    def __init__(self, url, data, headers=None):
        super().__init__(data)
        self.url = url
        self.headers = headers or {}
    def __enter__(self):
        return self
    def __exit__(self, *_):
        self.close()

class Opener:
    def __init__(self, replies):
        self.replies = list(replies)
        self.requests = []
    def open(self, request, timeout):
        self.requests.append(request)
        if not 0 < timeout <= 30:
            raise AssertionError('Unbounded request timeout')
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return Response(request.full_url, reply)

class TransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pack = json.loads(RESOURCE.read_bytes())
        cls.archive = ARCHIVE.read_bytes()
        cls.page, cls.endpoint, cls.asset = prepare.publisher_route(cls.pack)

    def signed(self, **changes):
        values = {'origin': 'https://kenney.nl', 'asset': self.asset, 'signature': 'a' * 64,
                  'query': 'expires=' + str(int(time.time()) + 300), 'fragment': ''}
        values.update(changes)
        return values['origin'] + '/download/' + values['asset'] + '/' + values['signature'] + '?' + values['query'] + values['fragment']

    def redirect(self, location=None, url=None):
        return urllib.error.HTTPError(url or self.pack['archiveURL'], 302, 'Found',
            {'Location': location or self.page}, io.BytesIO(b''))

    def test_real_pinned_archive_direct_and_resolved_paths(self):
        direct = Opener([self.archive])
        self.assertEqual(self.archive, prepare.fetch_pinned_archive(self.pack, direct))
        self.assertEqual([self.pack['archiveURL']], [r.full_url for r in direct.requests])
        value = self.signed()
        resolved = Opener([self.redirect(), json.dumps({'url': value}).encode(), self.archive])
        self.assertEqual(self.archive, prepare.fetch_pinned_archive(self.pack, resolved))
        self.assertEqual([self.pack['archiveURL'], self.endpoint, value], [r.full_url for r in resolved.requests])
        for request in resolved.requests:
            self.assertFalse(any(request.has_header(name) for name in ['Authorization', 'Cookie', 'Proxy-Authorization']))
        self.assertEqual(self.page, resolved.requests[1].get_header('Referer'))

    def test_unknown_ids_or_legacy_routes_issue_no_request(self):
        for edit in [{'id': 'unknown'}, {'archiveURL': 'https://example.invalid/a.zip'},
                     {'archiveURL': self.pack['archiveURL'] + '?x=1'}]:
            opener = Opener([])
            with self.subTest(edit=next(iter(edit))), self.assertRaises(ValueError):
                prepare.fetch_pinned_archive(dict(self.pack, **edit), opener)
            self.assertEqual([], opener.requests)

    def test_only_exact_known_landing_unlocks_resolution(self):
        for landing in ['http://kenney.nl/assets/1-bit-pack', 'https://example.invalid/assets/1-bit-pack',
                        'https://kenney.nl/assets/micro-roguelike', self.page + '?extra=1']:
            opener = Opener([self.redirect(landing)])
            with self.subTest(landing=landing), self.assertRaises(ValueError):
                prepare.fetch_pinned_archive(self.pack, opener)
            self.assertEqual(1, len(opener.requests))

    def test_signed_scope_lifetime_and_shape(self):
        invalid = [
            self.signed(origin='http://kenney.nl'), self.signed(origin='https://example.invalid'),
            self.signed(origin='https://user@kenney.nl'), self.signed(origin='https://kenney.nl:443'),
            self.signed(asset='wrong'), self.signed(signature='A' * 64),
            self.signed(signature='a' * 63), self.signed(fragment='#extra'),
            self.signed() + '\n', self.signed(origin='https://kenney.\tnl'),
            self.signed(query='expires=1'),
            self.signed(query='expires=' + str(int(time.time()) + 3600)),
            self.signed(query='expires=' + str(int(time.time()) + 300) + '&extra=1'),
            self.signed(query='expires=' + str(int(time.time()) + 300) + '&expires=2'),
        ]
        for index, value in enumerate(invalid):
            with self.subTest(case=index), self.assertRaises(ValueError):
                prepare.signed_publisher_url(value, self.asset)
        valid = self.signed()
        self.assertEqual(valid, prepare.signed_publisher_url(valid, self.asset))

    def test_invalid_metadata_never_reaches_archive(self):
        for data in [b'{bad', b'null', b'[]', b'{"url":7}', b'{"url":"x","extra":1}',
                     b' ' * (prepare.MAXIMUM_METADATA + 1)]:
            opener = Opener([self.redirect(), data])
            with self.subTest(bytes=len(data)), self.assertRaises(ValueError):
                prepare.fetch_pinned_archive(self.pack, opener)
            self.assertEqual(2, len(opener.requests))

    def test_metadata_and_resolved_redirects_are_not_followed(self):
        value = self.signed()
        for replies, count in [
            ([self.redirect(), self.redirect(value, self.endpoint)], 2),
            ([self.redirect(), json.dumps({'url': value}).encode(), self.redirect(self.page, value)], 3),
        ]:
            opener = Opener(replies)
            with self.assertRaises(ValueError):
                prepare.fetch_pinned_archive(self.pack, opener)
            self.assertEqual(count, len(opener.requests))
        handler = prepare.NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, 'Found', {}, value))

    def test_resolved_zip_remains_exact_size_and_hash_pinned(self):
        value = self.signed()
        bad = self.archive[:-1] + bytes([self.archive[-1] ^ 1])
        for payload in [self.archive[:-1], self.archive + b'x', bad]:
            opener = Opener([self.redirect(), json.dumps({'url': value}).encode(), payload])
            with self.subTest(bytes=len(payload)), self.assertRaises(ValueError):
                prepare.fetch_pinned_archive(self.pack, opener)

if __name__ == '__main__':
    unittest.main()
