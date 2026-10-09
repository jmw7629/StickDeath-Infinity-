"""Resumable binary upload adapter. Importing this module makes no requests.
Tokens, channel ownership and approval renewal are supplied by the server worker.
Uploads remain private; publication is a separate approved worker operation.
"""
from __future__ import annotations
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from typing import Callable
import urllib.error
import urllib.parse
import urllib.request


class UploadError(RuntimeError):
    pass


class ReconciliationRequired(UploadError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def google_url(value: str) -> str:
    parts = urllib.parse.urlsplit(value)
    if (parts.scheme != 'https' or parts.hostname != 'www.googleapis.com'
            or parts.port not in (None, 443) or parts.username or parts.password
            or parts.fragment or not parts.path.startswith(('/upload/youtube/v3/', '/youtube/v3/'))):
        raise UploadError('Provider endpoint rejected.')
    return value


def http(method: str, url: str, headers: dict, body: bytes) -> tuple[int, dict, bytes]:
    request = urllib.request.Request(google_url(url), data=body if method != 'GET' else None,
                                     headers=headers, method=method)
    opener = urllib.request.build_opener(NoRedirect())
    try:
        response = opener.open(request, timeout=45)
    except urllib.error.HTTPError as response_error:
        response = response_error
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ReconciliationRequired('Provider response uncertain; query the saved upload session.') from None
    with response:
        payload = response.read(65537)
        if len(payload) > 65536:
            raise ReconciliationRequired('Provider response exceeded limit.')
        return response.code, {k.lower(): v for k, v in response.headers.items()}, payload


class YouTubeUploader:
    CHUNK = 4 * 1024 * 1024  # multiple of 256 KiB
    MAX_BYTES = 2 * 1024 * 1024 * 1024

    def __init__(self, root: Path, access_token: Callable[[], str],
                 renew_approval: Callable[[], bool], channel_id: str, transport=http):
        self.root = root
        self.token = access_token
        self.renew = renew_approval
        self.channel = channel_id
        self.transport = transport
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if root.is_symlink() or root.stat().st_mode & 0o077:
            raise UploadError('Worker checkpoint directory must be private.')

    def request(self, method, url, body=b'', extra=None):
        if not self.renew():
            raise UploadError('Approval lease ended; transfer stopped.')
        token = self.token()
        if not token or len(token) > 16384 or not all(32 < ord(c) < 127 for c in token):
            raise UploadError('Owner OAuth is unavailable.')
        headers = {'Authorization': 'Bearer ' + token, 'Content-Length': str(len(body))}
        headers.update(extra or {})
        response = self.transport(method, google_url(url), headers, body)
        if response[0] == 401:
            invalidate = getattr(self.token, 'invalidate', None)
            if callable(invalidate): invalidate()
        # Do not automatically replay a binary upload or visibility mutation.
        # The caller preserves its existing provider/reconciliation semantics.
        return response

    def save(self, path: Path, value: dict):
        fd, temporary = tempfile.mkstemp(prefix='.checkpoint-', dir=self.root)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(value, stream); stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory = os.open(self.root, os.O_RDONLY)
            try: os.fsync(directory)
            finally: os.close(directory)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)

    def upload(self, job_id: str, source: Path, digest: str, title: str, description: str,
               made_for_kids: bool) -> dict:
        if not re.fullmatch(r'[a-fA-F0-9-]{36}', job_id) or not re.fullmatch(r'[a-f0-9]{64}', digest):
            raise UploadError('Invalid job identity.')
        if not title.strip() or len(title) > 100 or len(description.encode('utf-8')) > 5000:
            raise UploadError('Invalid video metadata.')
        if type(made_for_kids) is not bool or not self.channel:
            raise UploadError('Owner channel and audience declaration required.')
        metadata = {'snippet': {'title': title, 'description': description},
                    'status': {'privacyStatus': 'private', 'selfDeclaredMadeForKids': made_for_kids}}
        metadata_digest = hashlib.sha256(json.dumps(metadata, sort_keys=True).encode()).hexdigest()
        checkpoint = self.root / (job_id + '.json')
        with (self.root / (job_id + '.lock')).open('a') as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = json.loads(checkpoint.read_text()) if checkpoint.exists() else {
                'digest': digest, 'channel': self.channel, 'metadata_digest': metadata_digest}
            if (state.get('digest'), state.get('channel'), state.get('metadata_digest')) != (digest, self.channel, metadata_digest):
                raise UploadError('Job artifact or metadata changed; new approval required.')
            if state.get('result'):
                return state['result']
            code, _, body = self.request('GET', 'https://www.googleapis.com/youtube/v3/channels?part=id&mine=true')
            if code != 200 or self.channel not in [x.get('id') for x in json.loads(body).get('items', [])]:
                raise UploadError('OAuth identity does not match the approved owner channel.')
            # Copy a bounded private snapshot while hashing; never upload a path or
            # read changing source bytes during transfer. Original is never deleted.
            fd, temporary = tempfile.mkstemp(prefix='.render-', dir=self.root)
            try:
                size = 0; sha = hashlib.sha256()
                with source.open('rb') as original, os.fdopen(fd, 'wb') as snapshot:
                    while chunk := original.read(self.CHUNK):
                        if not self.renew(): raise UploadError('Approval ended while staging.')
                        size += len(chunk)
                        if size > self.MAX_BYTES: raise UploadError('Render exceeds upload bound.')
                        sha.update(chunk); snapshot.write(chunk)
                    snapshot.flush(); os.fsync(snapshot.fileno())
                if size == 0 or sha.hexdigest() != digest:
                    raise UploadError('Actual render bytes do not match approval.')
                os.chmod(temporary, 0o400)
                if state.get('size', size) != size: raise UploadError('Render size changed.')
                state['size'] = size
                if not state.get('session'):
                    if state.get('initializing'):
                        raise ReconciliationRequired('Upload initiation outcome needs operator reconciliation.')
                    state['initializing'] = True; self.save(checkpoint, state)
                    code, headers, _ = self.request('POST',
                        'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status',
                        json.dumps(metadata).encode(), {'Content-Type': 'application/json; charset=UTF-8',
                        'X-Upload-Content-Length': str(size), 'X-Upload-Content-Type': 'video/mp4'})
                    if code not in (200, 201) or 'location' not in headers:
                        raise ReconciliationRequired('Upload initiation was not confirmed.')
                    state['session'] = google_url(headers['location']); state['initializing'] = False
                    self.save(checkpoint, state)
                # Always probe on resume: local offsets never imply provider progress.
                code, headers, body = self.request('PUT', state['session'], extra={'Content-Range': f'bytes */{size}'})
                with open(temporary, 'rb') as snapshot:
                    stalled = 0
                    while True:
                        if code in (200, 201):
                            value = json.loads(body); video_id = value.get('id', '')
                            if not re.fullmatch(r'[A-Za-z0-9_-]{11}', video_id):
                                raise ReconciliationRequired('Provider completion lacks a valid video identifier.')
                            result = {'video_id': video_id, 'url': 'https://www.youtube.com/watch?v=' + video_id,
                                      'visibility': 'private', 'processing_verified': False, 'digest': digest}
                            state['result'] = result; self.save(checkpoint, state); return result
                        if code != 308:
                            raise ReconciliationRequired('Upload session requires provider reconciliation; no new session created.')
                        match = re.fullmatch(r'bytes=0-(\d+)', headers.get('range', ''))
                        if headers.get('range') and not match: raise ReconciliationRequired('Invalid provider offset.')
                        offset = int(match.group(1)) + 1 if match else 0
                        if offset < 0 or offset >= size: raise ReconciliationRequired('Invalid incomplete upload offset.')
                        if 'retry-after' in headers:
                            raise ReconciliationRequired('Provider requested a delay; resume later with backoff.')
                        old_offset = state.get('offset', -1)
                        stalled = stalled + 1 if offset <= old_offset else 0
                        if stalled > 2: raise ReconciliationRequired('Provider upload made no progress.')
                        state['offset'] = offset; self.save(checkpoint, state)
                        snapshot.seek(offset); data = snapshot.read(min(self.CHUNK, size-offset))
                        code, headers, body = self.request('PUT', state['session'], data,
                            {'Content-Type': 'video/mp4', 'Content-Range': f'bytes {offset}-{offset+len(data)-1}/{size}'})
            finally:
                if os.path.exists(temporary): os.unlink(temporary)

    def finish_processing_and_publish(self, job_id: str, digest: str) -> dict:
        """One bounded processing/release step; caller schedules later if pending.
        Only a private upload persisted by this adapter can enter this path.
        Lease callback must authorize this exact job/digest/destination each time.
        """
        if not re.fullmatch(r'[a-fA-F0-9-]{36}', job_id) or not re.fullmatch(r'[a-f0-9]{64}', digest):
            raise UploadError('Invalid release identity.')
        checkpoint = self.root / (job_id + '.json')
        with (self.root / (job_id + '.lock')).open('a') as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = json.loads(checkpoint.read_text())
            result = state.get('result') or {}
            if state.get('digest') != digest or state.get('channel') != self.channel or result.get('digest') != digest:
                raise UploadError('Release artifact does not match the approved upload.')
            video_id = result.get('video_id', '')
            if not re.fullmatch(r'[A-Za-z0-9_-]{11}', video_id):
                raise UploadError('Private upload is not complete.')
            endpoint = 'https://www.googleapis.com/youtube/v3/videos?part=snippet,status,processingDetails&id=' + video_id
            code, _, body = self.request('GET', endpoint)
            if code != 200:
                raise ReconciliationRequired('Unable to confirm owner video processing.')
            videos = json.loads(body).get('items', [])
            if len(videos) != 1 or videos[0].get('id') != video_id or videos[0].get('snippet', {}).get('channelId') != self.channel:
                raise UploadError('Uploaded video ownership could not be confirmed.')
            video = videos[0]; status = video.get('status', {})
            processing = video.get('processingDetails', {}).get('processingStatus')
            if processing in ('failed', 'terminated') or status.get('uploadStatus') in ('failed', 'rejected', 'deleted'):
                state['processing'] = 'failed'; self.save(checkpoint, state)
                raise UploadError('YouTube processing failed; no release performed.')
            if processing != 'succeeded' or status.get('uploadStatus') != 'processed':
                state['processing'] = 'pending'; self.save(checkpoint, state)
                return {'state': 'processing', 'video_id': video_id, 'digest': digest}
            # Reconcile an uncertain prior visibility update through provider state.
            if status.get('privacyStatus') != 'public':
                if status.get('privacyStatus') != 'private':
                    raise ReconciliationRequired('Video visibility changed outside this job.')
                writable = ('embeddable', 'license', 'publicStatsViewable', 'selfDeclaredMadeForKids', 'containsSyntheticMedia')
                update = {key: status[key] for key in writable if key in status}
                update['privacyStatus'] = 'public'
                state['processing'] = 'complete'; state['release_intent'] = True
                self.save(checkpoint, state)
                # The request method renews exact approval immediately before PUT.
                code, _, _ = self.request('PUT', 'https://www.googleapis.com/youtube/v3/videos?part=status',
                                          json.dumps({'id': video_id, 'status': update}).encode(),
                                          {'Content-Type': 'application/json'})
                if code != 200:
                    raise ReconciliationRequired('Public release response uncertain; reconcile video state.')
            elif not state.get('release_intent') and not state.get('published'):
                raise ReconciliationRequired('Video was made public outside this approval-controlled job.')
            code, _, body = self.request('GET', endpoint)
            verified = json.loads(body).get('items', []) if code == 200 else []
            if (len(verified) != 1 or verified[0].get('id') != video_id
                    or verified[0].get('snippet', {}).get('channelId') != self.channel
                    or verified[0].get('status', {}).get('privacyStatus') != 'public'
                    or verified[0].get('status', {}).get('uploadStatus') != 'processed'):
                raise ReconciliationRequired('Public video state is not confirmed.')
            receipt = {'state': 'published', 'video_id': video_id, 'digest': digest,
                       'url': 'https://www.youtube.com/watch?v=' + video_id,
                       'visibility': 'public', 'processing_verified': True}
            state['published'] = receipt; self.save(checkpoint, state)
            return receipt
