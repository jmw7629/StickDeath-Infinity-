"""Server-only owner token refresh. Importing this module performs no requests.

The deployment injects an encrypted secret-store reader and connection-status
writer. No refresh token is accepted from a publishing job or an iOS client.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from .youtube_upload import NoRedirect, UploadError


class OwnerAuthorizationRequired(UploadError):
    pass


@dataclass(frozen=True, repr=False)
class OwnerGrant:
    revision: str
    channel_id: str
    client_id: str = field(repr=False)
    client_secret: str = field(repr=False)
    refresh_token: str = field(repr=False)
    enabled: bool = True


def refresh_request(fields: dict) -> tuple[int, bytes]:
    request = urllib.request.Request('https://oauth2.googleapis.com/token',
        data=urllib.parse.urlencode(fields).encode(), method='POST',
        headers={'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json'})
    try:
        response = urllib.request.build_opener(NoRedirect()).open(request, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    except (urllib.error.URLError, TimeoutError, OSError):
        raise OwnerAuthorizationRequired('Owner token service temporarily unavailable.') from None
    with response:
        body = response.read(32769)
        if len(body) > 32768:
            raise OwnerAuthorizationRequired('Owner token response exceeded limit.')
        return response.code, body


class OwnerTokenProvider:
    """Callable access-token provider for PublishingWorker.

    load_grant reads current server connection state on EVERY call, including
    cached-token calls. record_state(revision, state) must compare-and-set that
    revision in the secret store; it must never overwrite a newly linked grant.
    Access tokens live only in this object. Revision changes clear the cache.
    """
    def __init__(self, load_grant, record_state, channel_id: str,
                 transport=refresh_request, clock=time.monotonic):
        if not channel_id: raise ValueError('Configured owner channel required.')
        self.load_grant = load_grant
        self.record_state = record_state
        self.channel_id = channel_id
        self.transport = transport
        self.clock = clock
        self._lock = threading.Lock()
        self._revision = None
        self._token = None
        self._expires = 0
        self._retry_at = 0
        self._reconnect = False

    def _clear(self):
        self._token = None
        self._expires = 0

    def invalidate(self):
        """Called on provider 401; never repeats an upload mutation itself."""
        with self._lock:
            self._clear()
            self._retry_at = self.clock() + 30

    @staticmethod
    def _valid(value):
        return isinstance(value, str) and 0 < len(value) <= 16384 and all(32 < ord(c) < 127 for c in value)

    def __call__(self) -> str:
        with self._lock:
            try:
                grant = self.load_grant()
            except Exception:
                self._clear()
                raise OwnerAuthorizationRequired('Owner connection unavailable.') from None
            if (not isinstance(grant, OwnerGrant) or grant.enabled is not True
                    or grant.channel_id != self.channel_id
                    or not all(self._valid(x) for x in (grant.revision, grant.client_id,
                                                        grant.client_secret, grant.refresh_token))):
                self._clear()
                raise OwnerAuthorizationRequired('Owner connection is disabled or incomplete.')
            if self._revision != grant.revision:
                self._clear()
                self._revision = grant.revision
                self._retry_at = 0
                self._reconnect = False
            if self._reconnect:
                raise OwnerAuthorizationRequired('Owner must reconnect YouTube.')
            now = self.clock()
            if self._token and now < self._expires: return self._token
            if now < self._retry_at:
                raise OwnerAuthorizationRequired('Owner token refresh is deferred.')
            self._clear()
            self._retry_at = now + 60
            try:
                code, raw = self.transport({'client_id': grant.client_id,
                    'client_secret': grant.client_secret, 'refresh_token': grant.refresh_token,
                    'grant_type': 'refresh_token'})
                result = json.loads(raw)
                if not isinstance(result, dict): raise ValueError()
            except Exception:
                raise OwnerAuthorizationRequired('Owner token refresh unavailable.') from None
            if code != 200:
                if result.get('error') in ('invalid_grant', 'invalid_client', 'unauthorized_client'):
                    self._reconnect = True
                    try:
                        self.record_state(grant.revision, 'reconnect_required')
                    except Exception:
                        pass  # The in-process connection remains blocked, never enabled.
                    raise OwnerAuthorizationRequired('Owner must reconnect YouTube.')
                raise OwnerAuthorizationRequired('Owner token service rejected refresh.')
            token = result.get('access_token')
            duration = result.get('expires_in')
            if (not self._valid(token) or str(result.get('token_type', '')).lower() != 'bearer'
                    or type(duration) is not int or not 60 < duration <= 86400):
                raise OwnerAuthorizationRequired('Owner token response was invalid.')
            # A disconnect or replacement while refresh was in flight wins.
            try:
                current = self.load_grant()
            except Exception:
                raise OwnerAuthorizationRequired('Owner connection unavailable.') from None
            if current != grant:
                raise OwnerAuthorizationRequired('Owner connection changed during refresh.')
            self._token = token
            self._expires = now + duration - 60
            self._retry_at = 0
            return token
