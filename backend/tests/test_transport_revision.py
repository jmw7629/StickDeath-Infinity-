"""Focused offline security coverage for the private proposed runtime overlay."""
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch, Mock
import uuid

from backend.ingestion.auth import AccountAuthorizer
from backend.ingestion.registration import ReviewRegistrar
from backend.ingestion.preview import PreviewLinks
from backend.ingestion import application
from backend.tests.test_ingestion import FakeOpener, FakeResponse, metadata


BASE = 'https://backend.example.test/native-review-api'


class TransportRevisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.links = PreviewLinks('https://intake.example.test', b'k' * 32)
        self.network = patch.object(socket.socket, 'connect', side_effect=AssertionError('Unexpected network'))
        self.network.start()
        self.addCleanup(self.network.stop)

    def registrar(self, base=BASE, key='publishable-test'):
        return ReviewRegistrar(base, 'service-test', self.root, 'terms-v1', self.links,
                               publishable_key=key)

    def test_both_adapters_allow_only_root_or_exact_deployed_prefix(self):
        for base in ('https://backend.example.test', 'https://backend.example.test/',
                     BASE, BASE + '/', 'https://backend.example.test:443/native-review-api'):
            with self.subTest(allowed=base):
                self.assertEqual(AccountAuthorizer(base, 'publishable-test').base, base.rstrip('/'))
                self.assertEqual(self.registrar(base).base, base.rstrip('/'))
        refused = ['http://backend.example.test', 'https:///native-review-api',
                   'https://user@backend.example.test/native-review-api',
                   'https://@backend.example.test/native-review-api',
                   'https://user:pass@backend.example.test/native-review-api',
                   'https://backend.example.test:444/native-review-api',
                   'https://backend.example.test:/native-review-api',
                   BASE + '?', BASE + '#', BASE + '?a=1', BASE + '#frag',
                   BASE + '//', BASE + '/..', BASE + '/extra',
                   BASE + '%2f', BASE + '%2f..', BASE + '%252f..',
                   BASE + '/%2e%2e', BASE + '/%252e%252e', BASE + '-other',
                   'https://backend.example.test//native-review-api',
                   'https://backend.example.test/./native-review-api',
                   'https://backend.example.test/arbitrary',
                   'https://backend.example.test\\@evil.test/native-review-api',
                   BASE + '\n', ' ' + BASE, BASE + ' ']
        for base in refused:
            with self.subTest(refused=repr(base)):
                with self.assertRaises(ValueError):
                    AccountAuthorizer(base, 'publishable-test')
                with self.assertRaises(ValueError):
                    self.registrar(base)

    def test_registrar_requires_explicit_separate_publishable_key(self):
        with self.assertRaises(TypeError):
            ReviewRegistrar(BASE, 'service-test', self.root, 'terms-v1', self.links)
        for key in ('', 'service-test', 'bad\nkey', 'bad key', None):
            with self.subTest(key=repr(key)), self.assertRaises(ValueError):
                self.registrar(key=key)

    def test_identity_preserves_prefix_and_session_uses_publishable_key(self):
        actor = str(uuid.uuid4())
        opener = FakeOpener([FakeResponse(json.dumps({'authorized': True, 'actor': actor}).encode())])
        with patch('urllib.request.build_opener', return_value=opener):
            self.assertEqual(AccountAuthorizer(BASE, 'publishable-test')('Bearer current-user-test'), actor)
        request = opener.requests[0]
        self.assertEqual(request.full_url, BASE + '/rest/v1/rpc/sdi_upload_identity')
        self.assertEqual(request.get_header('Apikey'), 'publishable-test')
        self.assertEqual(request.get_header('Authorization'), 'Bearer current-user-test')

    def test_all_registrar_rpcs_keep_service_credential_only_in_authorization(self):
        upload, owner, review, permit = [str(uuid.uuid4()) for _ in range(4)]
        digest = 'a' * 64
        movie = self.root / (upload + '.mp4')
        movie.write_bytes(b'x' * 10)
        (self.root / (upload + '.lock')).touch()
        answers = [{'allowed': True}, {'review_id': review}, {'status': 'confirmed'},
                   True, {'byte_count': 10, 'expires': 1800000000},
                   {'upload': upload, 'creator': owner, 'permit': permit, 'digest': digest, 'byte_count': 10},
                   {'preview_url': 'test', 'preview_expires_at': 'test'}]
        opener = FakeOpener([FakeResponse(json.dumps(x).encode()) for x in answers])
        registrar = self.registrar()
        with patch('urllib.request.build_opener', return_value=opener):
            meta = {**metadata(10, digest), 'source_project_digest': digest}
            self.assertEqual(registrar(upload, owner, movie, meta, 1800000000), review)
            self.assertTrue(registrar.artifact_released(upload, review))
            self.assertEqual(registrar.preview_authority(upload, owner, digest)['byte_count'], 10)
            registrar.renew_preview('Bearer current-admin-test', review, digest, 1)
        operations = ['sdi_consent_verify', 'sdi_register_upload', 'sdi_review_bind_source_digest',
                      'sdi_retire_upload', 'sdi_upload_preview', 'sdi_preview_permit', 'sdi_preview_renew']
        self.assertEqual(len(opener.requests), len(operations))
        for index, (request, operation) in enumerate(zip(opener.requests, operations)):
            self.assertEqual(request.full_url, BASE + '/rest/v1/rpc/' + operation)
            self.assertEqual(request.get_header('Apikey'), 'publishable-test')
            expected = 'Bearer current-admin-test' if operation == 'sdi_preview_permit' else 'Bearer service-test'
            self.assertEqual(request.get_header('Authorization'), expected)
            self.assertNotIn('service-test', request.full_url)
            self.assertNotIn(b'service-test', request.data)

    def test_factory_requires_and_passes_existing_publishable_key(self):
        env = {'SDI_BACKEND_URL': BASE, 'SDI_INTAKE_ORIGIN': 'https://intake.example.test',
               'SDI_PUBLISHING_CONSENT_VERSION': 'terms-v1', 'SDI_INTAKE_DIRECTORY': str(self.root),
               'SDI_INTAKE_TOTAL_BYTES': str(4 * 1024**3),
               'SDI_BACKEND_PUBLISHABLE_KEY': 'publishable-test',
               'SDI_BACKEND_SERVICE_KEY_FILE': '/test/service', 'SDI_PREVIEW_SIGNING_KEY_FILE': '/test/signing',
               'SDI_DECODER_ROOT': '/test/decoder', 'SDI_DECODER_SNAPSHOT_DIRECTORY': '/test/snapshots'}
        with patch.object(application, '_secret_file', side_effect=lambda _e, name, binary=False: b'k'*32 if binary else 'service-test'), \
             patch.object(application, 'DecoderSandbox'), patch.object(application, 'MediaValidator'), patch.object(application, 'LicensedAssetRegistry'), \
             patch.object(application, 'UploadStore') as store, patch.object(application, 'ReviewRegistrar') as registrar:
            store.return_value.root = self.root
            application.create_application(env)
            self.assertEqual(registrar.call_args.kwargs['publishable_key'], 'publishable-test')
            self.assertEqual(registrar.call_args.args[:2], (BASE, 'service-test'))
            with self.assertRaises(ValueError):
                application.create_application({k:v for k,v in env.items() if k != 'SDI_BACKEND_PUBLISHABLE_KEY'})


if __name__ == '__main__':
    unittest.main()
