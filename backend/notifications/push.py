"""Push batch worker and provider transports (#290).

``PushBatchWorker`` moves one claimed batch from ``sdi_announcement_claim`` to a
transport and reports results to ``sdi_announcement_finish``. The database already
applied audience, preferences, account state and daily caps; the batch contains
only deliveries that may be sent.

Transports:

* ``SinkTransport`` – development and tests. Records what would have been sent and
  never contacts a device.
* ``ApnsTransport`` – Apple Push Notification service with token-based (ES256 JWT)
  authentication over HTTP/2. HTTP/2 is not in the standard library, so the
  request goes through an injected ``Http2Sender``; ``HttpxHttp2Sender`` is the
  optional production sender (needs ``httpx`` with the ``h2`` extra installed on
  the worker host). Without a sender the transport reports "not configured".
* ``FcmTransport`` – Firebase Cloud Messaging HTTP v1. An OAuth2 access token is
  obtained from a service-account key with an RS256 JWT bearer assertion; both the
  token exchange and the send go through an injected ``HttpSender`` (the default
  is ``UrllibSender``, HTTPS only, no redirects).
* ``RoutingTransport`` – picks APNs for ``ios`` and FCM for ``android``.

Configuration comes from environment variables only (names below). Key material is
read from files whose paths are configured; nothing secret is in source, in a
result, or in an exception message. A transport that is not fully configured has
``configured == False`` and a ``reason`` naming the missing settings, and the
worker refuses to claim a batch in that state, so nothing is marked failed and no
device is contacted. The CLI additionally requires ``SDI_PUSH_ENABLED=1``; it is
never set in development or test environments.

APNs settings: ``SDI_APNS_KEY_ID``, ``SDI_APNS_TEAM_ID``, ``SDI_APNS_KEY_FILE``
(.p8 path), ``SDI_APNS_TOPIC`` (app bundle id).
FCM settings: ``SDI_FCM_PROJECT_ID``, ``SDI_FCM_SERVICE_ACCOUNT_FILE`` (JSON path).

Signing uses the optional ``cryptography`` package, imported lazily; when it is
missing the transport reports "not configured" rather than failing at import.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable, Dict, List, Mapping, Optional, Protocol, Tuple

from ..publishing.worker import JobAPI

PERMANENT_FAILURES = ("Unregistered", "BadDeviceToken", "unregistered", "invalid_token")
MAX_RESPONSE_BYTES = 65536
APNS_MAX_PAYLOAD = 4096
FCM_MAX_PAYLOAD = 4096
APNS_HOSTS = {"production": "api.push.apple.com", "sandbox": "api.sandbox.push.apple.com"}
FCM_HOST = "fcm.googleapis.com"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

APNS_SETTINGS = ("SDI_APNS_KEY_ID", "SDI_APNS_TEAM_ID", "SDI_APNS_KEY_FILE", "SDI_APNS_TOPIC")
FCM_SETTINGS = ("SDI_FCM_PROJECT_ID", "SDI_FCM_SERVICE_ACCOUNT_FILE")

# (status, headers, body)
HttpResult = Tuple[int, Mapping[str, str], bytes]


class AnnouncementAPI(JobAPI):
    PREFIX = "sdi_announcement_"
    PERMITTED = frozenset({"claim", "finish"})


class PushTransport(Protocol):
    def send(self, platform: str, environment: str, token: str, title: str, body: str) -> Tuple[bool, str]:
        """Return ``(ok, reason)``. ``reason`` for a permanent token failure must be
        one of PERMANENT_FAILURES so the database revokes the device."""


class Http2Sender(Protocol):
    def post(self, url: str, headers: Mapping[str, str], body: bytes, timeout: float) -> HttpResult:
        """One HTTP/2 POST. Raise on transport failure."""


class HttpSender(Protocol):
    def post(self, url: str, headers: Mapping[str, str], body: bytes, timeout: float) -> HttpResult:
        """One HTTPS POST. Raise on transport failure."""


class NotConfigured(RuntimeError):
    """Raised by a transport asked to send while not configured."""


class SinkTransport:
    """Records sends; optional scripted failures keyed by token."""

    configured = True
    reason = ""

    def __init__(self, failures=None):
        self.sent: List[dict] = []
        self.failures = dict(failures or {})

    def send(self, platform, environment, token, title, body):
        self.sent.append({"platform": platform, "environment": environment, "token_suffix": token[-6:], "title": title, "body": body})
        if token in self.failures:
            return False, self.failures[token]
        return True, ""


# --------------------------------------------------------------------------- helpers

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _crypto():
    """Lazy import; returns the modules or None when ``cryptography`` is absent."""
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec, padding
        from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    except ImportError:
        return None
    return hashes, serialization, ec, padding, decode_dss_signature


def _missing(environment: Mapping[str, str], names) -> List[str]:
    return [name for name in names if not (environment.get(name) or "").strip()]


def _read_file(path: str) -> bytes:
    with open(path, "rb") as handle:
        return handle.read(65536)


def _json(body: bytes) -> dict:
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _payload_ok(title: str, body: str) -> bool:
    return isinstance(title, str) and isinstance(body, str) and bool(title.strip() or body.strip())


class UrllibSender:
    """HTTPS-only POST through urllib with redirects refused. Production default for FCM."""

    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    def post(self, url, headers, body, timeout):
        if urllib.parse.urlsplit(url).scheme != "https":
            raise ValueError("https required")
        request = urllib.request.Request(url, data=body, method="POST", headers=dict(headers))
        opener = urllib.request.build_opener(self._NoRedirect())
        try:
            with opener.open(request, timeout=timeout) as response:
                return response.status, dict(response.headers), response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers or {}), error.read(MAX_RESPONSE_BYTES + 1)


class HttpxHttp2Sender:
    """Optional HTTP/2 sender for APNs. ``available`` is False unless ``httpx`` and
    ``h2`` are importable; the transport then reports "not configured"."""

    def __init__(self):
        self._client = None
        try:
            import httpx  # noqa: F401
            import h2  # noqa: F401
        except ImportError:
            self.available = False
        else:
            self.available = True

    def post(self, url, headers, body, timeout):
        if not self.available:
            raise NotConfigured("HTTP/2 client unavailable")
        import httpx
        if self._client is None:
            self._client = httpx.Client(http2=True, timeout=timeout, follow_redirects=False)
        response = self._client.post(url, headers=dict(headers), content=body)
        return response.status_code, dict(response.headers), response.content[:MAX_RESPONSE_BYTES + 1]


# --------------------------------------------------------------------------- APNs

class ApnsTokenSigner:
    """ES256 provider token for APNs, reused for ``lifetime`` seconds (Apple accepts
    a token for one hour and rejects refreshing more than once every 20 minutes)."""

    def __init__(self, key_id: str, team_id: str, key_loader: Callable[[], bytes],
                 clock: Callable[[], float] = time.time, lifetime: int = 50 * 60):
        if not (10 <= lifetime <= 3300):
            raise ValueError("lifetime must be 10..3300 seconds")
        self.key_id, self.team_id = key_id, team_id
        self._load = key_loader
        self._key = None
        self.clock = clock
        self.lifetime = lifetime
        self._token: Optional[str] = None
        self._issued = 0.0
        self._lock = threading.Lock()

    def _private_key(self):
        crypto = _crypto()
        if crypto is None:
            raise NotConfigured("cryptography package unavailable")
        if self._key is None:
            _, serialization, ec, _, _ = crypto
            try:
                key = serialization.load_pem_private_key(self._load(), password=None)
            except (OSError, ValueError, TypeError):
                raise NotConfigured("APNs signing key unreadable") from None
            if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
                raise NotConfigured("APNs signing key must be a P-256 key")
            self._key = key
        return self._key

    def token(self) -> str:
        with self._lock:
            now = self.clock()
            if self._token and now - self._issued < self.lifetime:
                return self._token
            hashes, _, ec, _, decode = _crypto() or (None,) * 5
            key = self._private_key()
            header = _b64url(json.dumps({"alg": "ES256", "kid": self.key_id}, separators=(",", ":")).encode())
            claims = _b64url(json.dumps({"iss": self.team_id, "iat": int(now)}, separators=(",", ":")).encode())
            signing_input = ("%s.%s" % (header, claims)).encode("ascii")
            r, s = decode(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
            signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
            self._token = "%s.%s" % (signing_input.decode("ascii"), _b64url(signature))
            self._issued = now
            return self._token

    def invalidate(self) -> None:
        with self._lock:
            self._token = None


class ApnsTransport:
    def __init__(self, signer: Optional[ApnsTokenSigner], topic: Optional[str], sender: Optional[Http2Sender],
                 timeout: float = 10.0, missing: Tuple[str, ...] = ()):
        self.signer, self.topic, self.sender, self.timeout = signer, topic, sender, timeout
        problems = list(missing)
        if sender is None or getattr(sender, "available", True) is False:
            problems.append("HTTP/2 sender (install httpx[http2] on the worker host)")
        if _crypto() is None:
            problems.append("cryptography package")
        self.configured = not problems and signer is not None and bool(topic)
        self.reason = "" if self.configured else "APNs not configured: missing " + ", ".join(problems or ["signer/topic"])

    @classmethod
    def from_environment(cls, environment: Mapping[str, str], sender: Optional[Http2Sender] = None,
                         clock: Callable[[], float] = time.time) -> "ApnsTransport":
        missing = tuple(_missing(environment, APNS_SETTINGS))
        if missing:
            return cls(None, None, sender, missing=missing)
        path = environment["SDI_APNS_KEY_FILE"]
        signer = ApnsTokenSigner(environment["SDI_APNS_KEY_ID"].strip(), environment["SDI_APNS_TEAM_ID"].strip(),
                                 lambda: _read_file(path), clock=clock)
        return cls(signer, environment["SDI_APNS_TOPIC"].strip(), sender)

    def send(self, platform, environment, token, title, body):
        if not self.configured:
            raise NotConfigured(self.reason)
        if platform != "ios":
            return False, "apns handles ios only"
        host = APNS_HOSTS.get(environment)
        if host is None:
            return False, "unknown apns environment"
        if not token or not all(c in "0123456789abcdefABCDEF" for c in token):
            return False, "BadDeviceToken"
        if not _payload_ok(title, body):
            return False, "empty notification"
        payload = json.dumps({"aps": {"alert": {"title": title, "body": body}, "sound": "default"}},
                             separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(payload) > APNS_MAX_PAYLOAD:
            return False, "payload too large"
        headers = {"authorization": "bearer " + self.signer.token(), "apns-topic": self.topic,
                   "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0",
                   "content-type": "application/json"}
        status, _, raw = self.sender.post("https://%s/3/device/%s" % (host, token), headers, payload, self.timeout)
        if status == 200:
            return True, ""
        reason = str(_json(raw[:MAX_RESPONSE_BYTES]).get("reason") or "")[:100]
        if reason in ("ExpiredProviderToken", "InvalidProviderToken"):
            self.signer.invalidate()
        if status == 410 or reason == "Unregistered":
            return False, "Unregistered"
        if reason == "BadDeviceToken":
            return False, "BadDeviceToken"
        return False, "apns status %d %s" % (status, reason) if reason else "apns status %d" % status


# --------------------------------------------------------------------------- FCM

class GoogleServiceAccountToken:
    """OAuth2 access token for FCM from a service-account key (RS256 JWT bearer)."""

    def __init__(self, account_loader: Callable[[], bytes], sender: HttpSender,
                 clock: Callable[[], float] = time.time, timeout: float = 10.0):
        self._load = account_loader
        self.sender, self.clock, self.timeout = sender, clock, timeout
        self._account: Optional[dict] = None
        self._key = None
        self._token: Optional[str] = None
        self._expires = 0.0
        self._lock = threading.Lock()

    def _credentials(self):
        crypto = _crypto()
        if crypto is None:
            raise NotConfigured("cryptography package unavailable")
        if self._key is None:
            _, serialization, _, _, _ = crypto
            try:
                account = json.loads(self._load())
                key = serialization.load_pem_private_key(account["private_key"].encode("ascii"), password=None)
                email = account["client_email"]
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                raise NotConfigured("FCM service account unreadable") from None
            if not isinstance(email, str) or "@" not in email:
                raise NotConfigured("FCM service account unreadable")
            token_uri = account.get("token_uri") or GOOGLE_TOKEN_URL
            if token_uri != GOOGLE_TOKEN_URL:
                raise NotConfigured("unexpected token endpoint in service account")
            self._account, self._key = {"client_email": email}, key
        return self._account, self._key

    def token(self) -> str:
        with self._lock:
            now = self.clock()
            if self._token and now < self._expires - 60:
                return self._token
            account, key = self._credentials()
            hashes, _, _, padding, _ = _crypto()
            header = _b64url(b'{"alg":"RS256","typ":"JWT"}')
            claims = _b64url(json.dumps({"iss": account["client_email"], "scope": FCM_SCOPE, "aud": GOOGLE_TOKEN_URL,
                                         "iat": int(now), "exp": int(now) + 3600}, separators=(",", ":")).encode())
            signing_input = "%s.%s" % (header, claims)
            signature = key.sign(signing_input.encode("ascii"), padding.PKCS1v15(), hashes.SHA256())
            assertion = "%s.%s" % (signing_input, _b64url(signature))
            form = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion}).encode()
            status, _, raw = self.sender.post(GOOGLE_TOKEN_URL, {"Content-Type": "application/x-www-form-urlencoded"}, form, self.timeout)
            data = _json(raw[:MAX_RESPONSE_BYTES])
            token, lifetime = data.get("access_token"), data.get("expires_in")
            if status != 200 or not isinstance(token, str) or not token or not isinstance(lifetime, int) or lifetime <= 60:
                raise RuntimeError("FCM token exchange refused (status %d)" % status)
            self._token, self._expires = token, now + lifetime
            return token

    def invalidate(self) -> None:
        with self._lock:
            self._token = None


class FcmTransport:
    def __init__(self, project_id: Optional[str], tokens: Optional[GoogleServiceAccountToken], sender: Optional[HttpSender],
                 timeout: float = 10.0, missing: Tuple[str, ...] = ()):
        self.project_id, self.tokens, self.sender, self.timeout = project_id, tokens, sender, timeout
        problems = list(missing)
        if _crypto() is None:
            problems.append("cryptography package")
        if project_id is not None and not all(c.isalnum() or c == "-" for c in project_id):
            problems.append("valid SDI_FCM_PROJECT_ID")
        self.configured = not problems and bool(project_id) and tokens is not None and sender is not None
        self.reason = "" if self.configured else "FCM not configured: missing " + ", ".join(problems or ["project/credentials"])

    @classmethod
    def from_environment(cls, environment: Mapping[str, str], sender: Optional[HttpSender] = None,
                         clock: Callable[[], float] = time.time) -> "FcmTransport":
        missing = tuple(_missing(environment, FCM_SETTINGS))
        sender = sender or UrllibSender()
        if missing:
            return cls(None, None, sender, missing=missing)
        path = environment["SDI_FCM_SERVICE_ACCOUNT_FILE"]
        tokens = GoogleServiceAccountToken(lambda: _read_file(path), sender, clock=clock)
        return cls(environment["SDI_FCM_PROJECT_ID"].strip(), tokens, sender)

    def send(self, platform, environment, token, title, body):
        if not self.configured:
            raise NotConfigured(self.reason)
        if platform != "android":
            return False, "fcm handles android only"
        if not token or len(token) > 4096 or any(c.isspace() for c in token):
            return False, "invalid_token"
        if not _payload_ok(title, body):
            return False, "empty notification"
        payload = json.dumps({"message": {"token": token, "notification": {"title": title, "body": body},
                                          "android": {"priority": "high"}}}, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(payload) - len(token) > FCM_MAX_PAYLOAD:
            return False, "payload too large"
        url = "https://%s/v1/projects/%s/messages:send" % (FCM_HOST, self.project_id)
        headers = {"Authorization": "Bearer " + self.tokens.token(), "Content-Type": "application/json; charset=utf-8"}
        status, _, raw = self.sender.post(url, headers, payload, self.timeout)
        if status == 200 and isinstance(_json(raw[:MAX_RESPONSE_BYTES]).get("name"), str):
            return True, ""
        error = _json(raw[:MAX_RESPONSE_BYTES]).get("error")
        error = error if isinstance(error, dict) else {}
        codes = {str(d.get("errorCode")) for d in error.get("details", []) if isinstance(d, dict) and d.get("errorCode")}
        if status == 401:
            self.tokens.invalidate()
        if "UNREGISTERED" in codes or status == 404:
            return False, "unregistered"
        if "INVALID_ARGUMENT" in codes and "token" in str(error.get("message", "")).lower():
            return False, "invalid_token"
        label = sorted(codes)[0] if codes else str(error.get("status") or "")
        return False, ("fcm status %d %s" % (status, label[:60])).strip()


# --------------------------------------------------------------------------- routing and worker

class RoutingTransport:
    """APNs for ``ios``, FCM for ``android``. Configured only when both are, so a
    batch never half-sends because one platform lacks credentials."""

    def __init__(self, apns, fcm):
        self.by_platform = {"ios": apns, "android": fcm}
        problems = [t.reason for t in (apns, fcm) if not getattr(t, "configured", False)]
        self.configured = not problems
        self.reason = "; ".join(problems)

    def send(self, platform, environment, token, title, body):
        transport = self.by_platform.get(platform)
        if transport is None:
            return False, "unsupported platform"
        return transport.send(platform, environment, token, title, body)


def transport_from_environment(environment: Mapping[str, str], http2: Optional[Http2Sender] = None,
                               https: Optional[HttpSender] = None) -> RoutingTransport:
    return RoutingTransport(ApnsTransport.from_environment(environment, http2 if http2 is not None else HttpxHttp2Sender()),
                            FcmTransport.from_environment(environment, https))


class PushBatchWorker:
    def __init__(self, api: AnnouncementAPI, transport: PushTransport, batch: int = 500):
        if not 1 <= batch <= 1000:
            raise ValueError("batch must be 1..1000")
        self.api = api
        self.transport = transport
        self.batch = batch

    def run_once(self) -> dict:
        if getattr(self.transport, "configured", True) is False:
            # Refuse before claiming: nothing is leased, failed or sent.
            return {"state": "not_configured", "reason": getattr(self.transport, "reason", "push transport not configured")}
        claimed = self.api.call("claim", batch=self.batch)
        if claimed.get("empty"):
            return {"state": "idle"}
        results = []
        for delivery in claimed.get("deliveries", []):
            try:
                ok, reason = self.transport.send(delivery["platform"], delivery["environment"], delivery["token"], delivery["title"], delivery["body"])
            except NotConfigured:
                ok, reason = False, "transport not configured"
            except Exception:
                ok, reason = False, "transport error"
            results.append({"delivery": delivery["delivery"], "ok": bool(ok), "reason": "" if ok else str(reason)[:200]})
        finish = self.api.call("finish", results=results) if results else {"sent": 0, "failed": 0}
        return {"state": "complete" if claimed.get("complete") else "batch", "announcement": claimed.get("announcement"),
                "attempted": len(results), "sent": finish.get("sent", 0), "failed": finish.get("failed", 0)}


def main(argv: Optional[list] = None, environment: Optional[Mapping[str, str]] = None,
         api_factory: Optional[Callable[[], AnnouncementAPI]] = None,
         transport_factory: Optional[Callable[[Mapping[str, str]], PushTransport]] = None) -> int:
    """Run one push batch. Exit 0 on a completed/idle run, 2 when not enabled or not configured."""
    environment = os.environ if environment is None else environment
    if environment.get("SDI_PUSH_ENABLED") != "1":
        print(json.dumps({"state": "disabled", "reason": "SDI_PUSH_ENABLED is not 1; nothing was claimed or sent."}))
        return 2
    transport = (transport_factory or transport_from_environment)(environment)
    if getattr(transport, "configured", True) is False:
        print(json.dumps({"state": "not_configured", "reason": transport.reason}))
        return 2
    try:
        api = api_factory() if api_factory else AnnouncementAPI(environment["SDI_BACKEND_URL"], environment["SDI_SERVICE_KEY"])
    except (KeyError, ValueError):
        print(json.dumps({"state": "not_configured", "reason": "Backend URL and service key are not configured."}))
        return 2
    report = PushBatchWorker(api, transport).run_once()
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
