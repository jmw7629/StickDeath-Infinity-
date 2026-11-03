"""Daily draft RPC wire and stop checks with an in-process transport double."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import sys
import threading
import time
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

from backend.spatter import draft_queue as dq, draft_rpc_transport as transport
from backend.spatter.draft_worker import DraftRPCStore, DraftServiceError
from backend.spatter.test_draft_queue import DIGEST, NOW, SHA, TODAY, quality_record

JOB = '11111111-1111-4111-8111-111111111111'
RUN = '22222222-2222-4222-8222-222222222222'
REVIEW = '33333333-3333-4333-8333-333333333333'
OWNER = '44444444-4444-4444-8444-444444444444'
KEY = 'sb_secret_offline_fixture'
ORIGIN = 'https://draft-worker.invalid'


class Wire:
    def __init__(self, heartbeat=True, item_cap=1):
        self.heartbeat = heartbeat
        self.item_cap = item_cap
        self.calls = []

    def open(self, request, timeout):
        assert timeout == 20
        assert request.full_url.startswith(ORIGIN + '/rest/v1/rpc/')
        assert request.get_method() == 'POST'
        assert request.get_header('Apikey') == KEY
        assert request.get_header('Authorization') is None
        operation = request.full_url.rsplit('/', 1)[1]
        payload = json.loads(request.data)
        self.calls.append((operation, payload))
        if operation == 'sdi_spatter_draft_claim':
            assert set(payload) == {'p_date', 'p_owner', 'p_seed', 'p_brief_version', 'p_brief'}
            assert payload['p_date'] == TODAY.isoformat()
            response = dict(claimed=True, job=JOB, run=RUN, attempt=1,
                            planner_seed=payload['p_seed'], brief=payload['p_brief'])
            if self.item_cap is not None:
                response['per_run_item_cap'] = self.item_cap
        elif operation == 'sdi_agent_run_heartbeat':
            assert payload == {'run': RUN}
            response = self.heartbeat
        elif operation == 'sdi_spatter_draft_progress':
            assert payload['p_job'] == JOB and payload['p_owner'] == 'offline-worker'
            response = dict(status='confirmed', state=payload['p_state'])
            if payload['p_state'] == 'review_pending':
                response['review'] = REVIEW
        else:
            raise AssertionError('unexpected RPC')
        return io.BytesIO(json.dumps(response).encode())


class Renderer:
    preview_started = False

    def render(self, plan, heartbeat):
        heartbeat()
        self.preview_started = True
        return dq.RenderResult(sha256=SHA, storyboard={'seed': plan.seed}, quality=quality_record(),
                               source_project_digest=DIGEST, preview_url='https://private.invalid/review',
                               artifact={'object_key': JOB + '.mp4', 'byte_count': 512,
                                         'expires_at': '2026-10-14T09:00:00+00:00'})


class DraftWorkerTests(unittest.TestCase):
    def run_with(self, wire, renderer):
        store = DraftRPCStore(ORIGIN, KEY, opener=wire, clock=lambda: 1)
        return dq.run_once(store, owner='offline-worker', reviewer=OWNER, now=lambda: NOW, renderer=renderer)

    def test_exact_private_review_submission_over_fixed_rpc_allowlist(self):
        wire = Wire()
        outcome = self.run_with(wire, Renderer())
        self.assertEqual((outcome.state, outcome.review), ('review_pending', REVIEW))
        self.assertEqual([name for name, _ in wire.calls], [
            'sdi_spatter_draft_claim', 'sdi_spatter_draft_progress', 'sdi_agent_run_heartbeat',
            'sdi_agent_run_heartbeat', 'sdi_spatter_draft_progress'])
        payload = wire.calls[-1][1]
        self.assertEqual((payload['p_state'], payload['p_sha']), ('review_pending', SHA))
        self.assertEqual(payload['p_review']['creator'], OWNER)
        self.assertEqual(payload['p_review']['source_project_digest'], DIGEST)
        self.assertEqual(payload['p_review']['object_key'], JOB + '.mp4')
        self.assertTrue({'approval', 'destinations', 'published'}.isdisjoint(payload['p_review']))

    def test_emergency_stop_during_lease_prevents_preview_and_submission(self):
        wire, renderer = Wire(heartbeat=False), Renderer()
        outcome = self.run_with(wire, renderer)
        self.assertEqual(outcome.state, 'failed')
        self.assertFalse(renderer.preview_started)
        self.assertEqual(wire.calls[-1][1]['p_state'], 'failed')
        self.assertFalse(any(payload.get('p_state') == 'review_pending' for _, payload in wire.calls))

    def test_unauthorized_claim_never_enters_renderer(self):
        class Denied:
            def open(self, request, timeout):
                raise urllib.error.HTTPError(request.full_url, 403, KEY, None, None)

        renderer = Renderer()
        with self.assertRaisesRegex(DraftServiceError, '^Daily draft service authorization was refused[.]$'):
            self.run_with(Denied(), renderer)
        self.assertFalse(renderer.preview_started)

    def test_missing_or_invalid_item_cap_refuses_before_renderer(self):
        for cap in (None, False, True, -1, 0, 10_001, '1'):
            with self.subTest(cap=cap):
                wire, renderer = Wire(item_cap=cap), Renderer()
                outcome = self.run_with(wire, renderer)
                self.assertEqual(outcome.state, 'refused')
                self.assertFalse(renderer.preview_started)
                self.assertEqual([payload.get('p_state') for _, payload in wire.calls], [None, 'failed'])
                self.assertEqual(wire.calls[-1][1]['p_error'], 'The agent did not authorize a daily draft item.')

    def test_renderer_failure_never_sends_exception_text_to_service(self):
        class FailingRenderer:
            def render(self, plan, heartbeat):
                raise PermissionError('/private/fixture/host-path')

        wire = Wire()
        store = DraftRPCStore(ORIGIN, KEY, opener=wire, clock=lambda: 1)
        result = dq.run_once(store, owner='offline-worker', reviewer=OWNER, now=lambda: NOW,
                             renderer=FailingRenderer(), safe_diagnostics=True)
        self.assertEqual(result.reason, dq.DRAFT_RENDER_FAILED)
        self.assertEqual(wire.calls[-1][1]['p_error'], dq.DRAFT_RENDER_FAILED)
        self.assertNotIn('/private/fixture/host-path', json.dumps(wire.calls))

    def test_owned_rpc_process_times_out_on_a_live_loopback_trickle(self):
        # The fixture reroutes only the child's already validated HTTPS request
        # to an ephemeral loopback HTTP listener. The production opener and
        # child response reader still execute in separate processes.
        chunks = []
        disconnected = threading.Event()

        class Trickle(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(200)
                self.send_header('Content-Length', '1024')
                self.end_headers()
                try:
                    for _ in range(100):
                        self.wfile.write(b' ')
                        self.wfile.flush()
                        chunks.append(1)
                        time.sleep(0.05)
                except OSError:
                    disconnected.set()

        fixture_child = """import json, runpy, sys
request = json.load(sys.stdin)
post = runpy.run_path(sys.argv[1])['_post']
sys.stdout.buffer.write(post(sys.argv[2], request['secret'], request['body'].encode()))
"""
        with ThreadingHTTPServer(('127.0.0.1', 0), Trickle) as server:
            listener = threading.Thread(target=server.serve_forever, daemon=True)
            listener.start()
            loopback = f'http://127.0.0.1:{server.server_port}/rest/v1/rpc/sdi_agent_run_heartbeat'
            command = (sys.executable, '-I', '-c', fixture_child, transport.__file__, loopback)
            request = urllib.request.Request(ORIGIN + '/rest/v1/rpc/sdi_agent_run_heartbeat', data=b'{}',
                                             headers={'apikey': KEY}, method='POST')
            try:
                with patch.object(transport, '_CHILD', command):
                    started = time.monotonic()
                    with self.assertRaises(TimeoutError):
                        transport.BoundedRPCOpener().open(request, timeout=1.5)
                    self.assertLess(time.monotonic() - started, 3.0)
                self.assertGreater(len(chunks), 1, 'the timeout must interrupt an actual response body')
                self.assertTrue(disconnected.wait(2), 'the owned child must close its socket when reaped')
            finally:
                server.shutdown()
                listener.join(2)
