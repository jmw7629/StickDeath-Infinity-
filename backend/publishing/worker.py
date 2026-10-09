"""One-job server executor; not a daemon and never starts on import.
Deployment supplies validated storage, private checkpoints and owner OAuth.
"""
from __future__ import annotations
import fcntl
import json
from pathlib import Path
import urllib.parse
import urllib.request
import urllib.error
from .youtube_upload import YouTubeUploader, NoRedirect, UploadError, ReconciliationRequired
from .owner_oauth import OwnerAuthorizationRequired
from .youtube_withdraw import withdraw


class JobAPI:
    def __init__(self, base_url: str, service_key: str):
        parsed = urllib.parse.urlsplit(base_url)
        if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
                or parsed.query or parsed.fragment or parsed.path not in ('', '/') or parsed.port not in (None,443)):
            raise ValueError('Invalid configured application backend.')
        if not service_key or not all(32 < ord(c) < 127 for c in service_key):
            raise ValueError('Server service key required.')
        self.base = base_url.rstrip('/')
        self.key = service_key

    def call(self, operation: str, **payload):
        permitted = {'claim','renew','finish','progress','uncertain',
                     'removal_claim','removal_renew','removal_finish'}
        if operation not in permitted: raise ValueError('Unsupported worker operation.')
        body = json.dumps(payload).encode()
        request = urllib.request.Request(self.base+'/rest/v1/rpc/sdi_publish_'+operation,
            data=body,method='POST',headers={'apikey':self.key,'Authorization':'Bearer '+self.key,
                                            'Content-Type':'application/json'})
        try:
            with urllib.request.build_opener(NoRedirect()).open(request,timeout=20) as response:
                raw = response.read(131073)
                if len(raw)>131072: raise RuntimeError('Job response exceeded limit.')
                return json.loads(raw)
        except (urllib.error.URLError, TimeoutError, OSError):
            raise RuntimeError('Job service response unavailable; preserve lease for reconciliation.') from None


class PublishingWorker:
    def __init__(self, api: JobAPI, artifact_root: Path, checkpoint_root: Path,
                 access_token, channel_id: str):
        self.api = api
        self.artifacts = artifact_root.resolve(strict=True)
        self.checkpoints = checkpoint_root
        self.access_token = access_token
        self.channel_id = channel_id

    def run_once(self) -> dict:
        self.checkpoints.mkdir(mode=0o700,parents=True,exist_ok=True)
        if self.checkpoints.is_symlink() or self.checkpoints.stat().st_mode & 0o077:
            raise RuntimeError('Worker state must be private.')
        with (self.checkpoints/'worker.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            removal = self.api.call('removal_claim')
            if not removal.get('empty'):
                return self._withdraw(removal)
            job = self.api.call('claim')
            if job.get('empty'): return {'state':'idle'}
            job_id = job['job']; token = job['lease']
            def renew(): return self.api.call('renew',job=job_id,token=token) is True
            uploader = YouTubeUploader(self.checkpoints,self.access_token,renew,self.channel_id)
            try:
                if job['destination']!='youtube': raise UploadError('Unsupported publishing destination.')
                if job['phase']=='upload':
                    source = (self.artifacts/job['object_key']).resolve(strict=True)
                    if not source.is_relative_to(self.artifacts) or not source.is_file():
                        raise UploadError('Artifact lies outside owned storage.')
                    if source.stat().st_size != job['byte_count']:
                        raise UploadError('Artifact size differs from registered render.')
                    private = uploader.upload(job_id,source,job['digest'],job['title'],job['description'],job['made_for_kids'])
                    if not self.api.call('progress',job=job_id,token=token,provider=private['video_id'],wait_for_processing=True):
                        raise ReconciliationRequired('Private upload completed after job authorization changed.')
                    return {'state':'processing','job':job_id}
                result = uploader.finish_processing_and_publish(job_id,job['digest'])
                if result['state']=='processing':
                    if not self.api.call('progress',job=job_id,token=token,provider=result['video_id'],wait_for_processing=True):
                        raise ReconciliationRequired('Processing state could not be recorded.')
                    return {'state':'processing','job':job_id}
                if not self.api.call('finish',job=job_id,token=token,provider=result['video_id'],url=result['url']):
                    raise ReconciliationRequired('Release result needs reconciliation.')
                # Final SQL state may be removal_pending if cancellation raced release.
                return {'state':'release_recorded','job':job_id}
            except ReconciliationRequired:
                self.api.call('uncertain',job=job_id,token=token)
                return {'state':'reconcile','job':job_id}
            except OwnerAuthorizationRequired:
                self.api.call('finish',job=job_id,token=token,provider=None,url=None,
                              failure='Channel authorization unavailable. An administrator must restore the connection before retry.')
                return {'state':'authorization_unavailable','job':job_id}
            except UploadError:
                # Sanitized stored error: never persist token/session URLs or
                # arbitrary upstream response bodies in creator-visible status.
                self.api.call('finish',job=job_id,token=token,provider=None,url=None,
                              failure='Artifact or approval rejected. Refresh status before retry.')
                return {'state':'failed','job':job_id}

    def _withdraw(self, job: dict) -> dict:
        job_id = job['job']; token = job['lease']; provider = job['provider']
        def renew(): return self.api.call('removal_renew',job=job_id,token=token) is True
        uploader = YouTubeUploader(self.checkpoints,self.access_token,renew,self.channel_id)
        try:
            withdraw(uploader,job_id,job['digest'],provider)
        except UploadError:
            self.api.call('removal_finish',job=job_id,token=token,provider=provider,confirmed=False)
            return {'state':'withdrawal_pending','job':job_id}
        if not self.api.call('removal_finish',job=job_id,token=token,provider=provider,confirmed=True):
            return {'state':'withdrawal_needs_reconciliation','job':job_id}
        return {'state':'withdrawn_from_public','job':job_id}
