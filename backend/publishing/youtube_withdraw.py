"""Withdraw a registered upload from public view without deleting its original."""
import fcntl
import json
import os
import re

from .youtube_upload import UploadError, ReconciliationRequired


def withdraw(uploader, job_id: str, digest: str, video_id: str) -> dict:
    # uploader.renew MUST be the removal lease, not release approval. Permission
    # withdrawal should stop publication while still allowing the takedown.
    if (not re.fullmatch(r'[a-fA-F0-9-]{36}', job_id)
            or not re.fullmatch(r'[a-f0-9]{64}', digest)
            or not re.fullmatch(r'[A-Za-z0-9_-]{11}', video_id)):
        raise UploadError('Invalid withdrawal identity.')
    checkpoint = uploader.root / (job_id + '.json')
    with (uploader.root / (job_id + '.lock')).open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            state = json.loads(checkpoint.read_text())
        except (OSError, ValueError):
            raise ReconciliationRequired('Upload provenance unavailable for withdrawal.') from None
        result = state.get('result') or {}
        if (state.get('digest') != digest or state.get('channel') != uploader.channel
                or result.get('video_id') != video_id or result.get('digest') != digest):
            raise ReconciliationRequired('Withdrawal does not match the registered upload.')
        endpoint = 'https://www.googleapis.com/youtube/v3/videos?part=snippet,status&id=' + video_id

        def read_owned():
            code, _, raw = uploader.request('GET', endpoint)
            try:
                items = json.loads(raw).get('items', []) if code == 200 else []
                if (len(items) != 1 or items[0].get('id') != video_id
                        or items[0].get('snippet', {}).get('channelId') != uploader.channel):
                    raise ValueError()
                return items[0].get('status', {})
            except (ValueError, TypeError, AttributeError):
                # An empty provider list is not proof of deletion or success.
                raise ReconciliationRequired('Owner video visibility could not be confirmed.') from None

        status = read_owned()
        if status.get('privacyStatus') != 'private' or status.get('publishAt'):
            allowed = ('embeddable', 'license', 'publicStatsViewable',
                       'selfDeclaredMadeForKids', 'containsSyntheticMedia')
            update = {key: status[key] for key in allowed if key in status}
            update['privacyStatus'] = 'private'
            # Omit publishAt deliberately to remove any future public schedule.
            state['withdrawal_intent'] = True
            uploader.save(checkpoint, state)
            code, _, _ = uploader.request('PUT', 'https://www.googleapis.com/youtube/v3/videos?part=status',
                json.dumps({'id': video_id, 'status': update}).encode(), {'Content-Type': 'application/json'})
            if code != 200:
                raise ReconciliationRequired('Withdrawal response uncertain; read visibility before retry.')
        verified = read_owned()
        if verified.get('privacyStatus') != 'private' or verified.get('publishAt'):
            raise ReconciliationRequired('Withdrawal is not confirmed.')
        receipt = {'state': 'private', 'video_id': video_id, 'digest': digest}
        state['withdrawn'] = receipt
        uploader.save(checkpoint, state)
        return receipt
