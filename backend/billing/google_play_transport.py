"""Read-only Google Publisher transport. No FCM scope, grants or acknowledgements.

The deployment injects a SecretStore and (optionally) the bounded HTTPS adapter.
There are no environment/secret paths, live configuration or import-time requests.
"""
from __future__ import annotations

import base64
import json
import math
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Mapping, Protocol

from .contract import ContractError

PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
TOKEN_URL = "https://oauth2.googleapis.com/token"
PUBLISHER_ORIGIN = "https://androidpublisher.googleapis.com"
MAX_KEY_BYTES = 64 * 1024
MAX_TOKEN_BYTES = 16 * 1024
MAX_RESPONSE_BYTES = 256 * 1024
TIMEOUT_SECONDS = 10.0
PACKAGE = re.compile(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*){1,15}\Z")


class SecretStore(Protocol):
    def read(self, reference: str) -> bytes:
        """Return a server-held secret; access control/rotation belong to the adapter."""


@dataclass(frozen=True)
class HttpResponse:
    status: int
    body: bytes = field(repr=False)


class HttpTransport(Protocol):
    def request(self, method: str, url: str, headers: Mapping[str, str], body: bytes | None,
                timeout: float, maximum_bytes: int) -> HttpResponse:
        """No redirects; bound reply bytes and timeout. Never log bearer/path/body."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


def _allowed_url(method: str, url: str) -> bool:
    if method == "POST":
        return url == TOKEN_URL
    if method != "GET":
        return False
    parsed = urllib.parse.urlsplit(url)
    return (parsed.scheme == "https" and parsed.netloc == "androidpublisher.googleapis.com"
            and not parsed.query and not parsed.fragment
            and re.fullmatch(r"/androidpublisher/v3/applications/[A-Za-z0-9._]+/purchases/subscriptionsv2/tokens/[^/]+", parsed.path) is not None)


class GoogleHttpsTransport:
    """TLS-verified Google-only requests. No redirect, mutation or automatic retry."""
    def request(self, method, url, headers, body, timeout, maximum_bytes):
        if not _allowed_url(method, url) or not 0 < timeout <= TIMEOUT_SECONDS or not 0 < maximum_bytes <= MAX_RESPONSE_BYTES:
            raise ContractError(503, "invalid Google transport configuration")
        request = urllib.request.Request(url, data=body, headers=dict(headers), method=method)
        opener = urllib.request.build_opener(_NoRedirect())
        try:
            with opener.open(request, timeout=timeout) as reply:
                raw = reply.read(maximum_bytes + 1)
                status = reply.status
        except urllib.error.HTTPError as error:
            raw, status = error.read(maximum_bytes + 1), error.code
        except (OSError, ValueError):
            raise ContractError(502, "Google verification service unavailable") from None
        if len(raw) > maximum_bytes:
            raise ContractError(502, "Google verification response exceeds its limit")
        return HttpResponse(status, raw)


def json_object(raw: bytes, maximum_bytes: int) -> dict:
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError("duplicate field")
            result[key] = value
        return result
    def invalid_constant(_):
        raise ValueError("nonfinite number")
    try:
        if not isinstance(raw, bytes) or len(raw) > maximum_bytes:
            raise ValueError("size")
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs, parse_constant=invalid_constant)
        if not isinstance(value, dict):
            raise ValueError("object required")
        work, count = [(value, 0)], 0
        while work:
            child, depth = work.pop(); count += 1
            if count > 8192 or depth > 16:
                raise ValueError("complexity")
            if isinstance(child, dict):
                work.extend((v, depth + 1) for v in child.values())
            elif isinstance(child, list):
                work.extend((v, depth + 1) for v in child)
        return value
    except (UnicodeDecodeError, ValueError, TypeError, RecursionError):
        raise ContractError(502, "Google verification service returned an invalid response") from None


def read_secret(store: SecretStore, reference: str, minimum: int, maximum: int) -> bytes:
    try:
        value = store.read(reference)
    except Exception:
        raise ContractError(503, "Google verification secret unavailable") from None
    if not isinstance(value, bytes) or not minimum <= len(value) <= maximum:
        raise ContractError(503, "Google verification secret unavailable")
    return value


def _b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


class PublisherAccessToken:
    """Dedicated RS256 service-account grant with only androidpublisher scope.

    No domain-wide delegation. No endpoint from a credential document is followed.
    The key is loaded on cache miss, so invalidation also permits secret rotation.
    """
    def __init__(self, secrets: SecretStore, reference: str, transport: HttpTransport,
                 clock: Callable[[], float] = time.time):
        self._secrets, self._reference, self._transport, self._clock = secrets, reference, transport, clock
        self._cached: str | None = None
        self._expires = 0.0
        self._lock = threading.Lock()

    def invalidate(self):
        with self._lock:
            self._cached = None; self._expires = 0

    def token(self) -> str:
        with self._lock:
            now = self._clock()
            if not isinstance(now, (int, float)) or isinstance(now, bool) or not math.isfinite(now) or now <= 0:
                raise ContractError(503, "Google verification clock unavailable")
            if self._cached is not None and now < self._expires - 60:
                return self._cached
            raw = read_secret(self._secrets, self._reference, 1, MAX_KEY_BYTES)
            try:
                from cryptography.hazmat.primitives import hashes, serialization
                from cryptography.hazmat.primitives.asymmetric import padding, rsa
                account = json_object(raw, MAX_KEY_BYTES)
                email, key_id = account.get("client_email"), account.get("private_key_id")
                if (account.get("type") != "service_account" or account.get("token_uri") != TOKEN_URL
                    or not isinstance(email, str) or re.fullmatch(r"[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.iam\.gserviceaccount\.com", email) is None
                    or not isinstance(key_id, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,200}", key_id) is None
                    or not isinstance(account.get("private_key"), str)):
                    raise ValueError("credentials")
                key = serialization.load_pem_private_key(account["private_key"].encode("ascii"), password=None)
                if not isinstance(key, rsa.RSAPrivateKey) or not 2048 <= key.key_size <= 8192:
                    raise ValueError("RSA key required")
                header = _b64(json.dumps({"alg": "RS256", "typ": "JWT", "kid": key_id}, separators=(",", ":")).encode())
                claims = _b64(json.dumps({"iss": email, "scope": PUBLISHER_SCOPE, "aud": TOKEN_URL,
                    "iat": int(now), "exp": int(now) + 3600}, separators=(",", ":")).encode())
                signing = (header + "." + claims).encode("ascii")
                assertion = signing.decode("ascii") + "." + _b64(key.sign(signing, padding.PKCS1v15(), hashes.SHA256()))
            except Exception:
                raise ContractError(503, "Google Publisher service account is unavailable or invalid") from None
            form = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion}).encode("ascii")
            try:
                reply = self._transport.request("POST", TOKEN_URL, {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
                    form, TIMEOUT_SECONDS, MAX_TOKEN_BYTES)
            except ContractError:
                raise
            except Exception:
                raise ContractError(502, "Google verification service unavailable") from None
            if reply.status != 200:
                raise ContractError(502, "Google Publisher authorization unavailable")
            result = json_object(reply.body, MAX_TOKEN_BYTES)
            token, expiry = result.get("access_token"), result.get("expires_in")
            if (not isinstance(result.get("token_type"), str) or result["token_type"].lower() != "bearer" or not isinstance(token, str) or not 1 <= len(token) <= 8192
                or not all(32 < ord(c) < 127 for c in token) or not isinstance(expiry, int) or isinstance(expiry, bool) or not 60 < expiry <= 3600
                or ("scope" in result and result["scope"] != PUBLISHER_SCOPE)):
                raise ContractError(502, "Google Publisher authorization returned an invalid response")
            self._cached, self._expires = token, now + expiry
            return token


def validate_purchase_token(token) -> str:
    if not isinstance(token, str) or not 1 <= len(token) <= 4096 or not all(32 < ord(c) < 127 for c in token):
        raise ContractError(400, "invalid purchase token")
    return token


class GooglePublisher:
    def __init__(self, tokens: PublisherAccessToken, transport: HttpTransport):
        self._tokens, self._transport = tokens, transport

    def subscription(self, package_name: str, purchase_token: str) -> dict:
        if not isinstance(package_name, str) or PACKAGE.fullmatch(package_name) is None:
            raise ContractError(503, "invalid Google package configuration")
        token = validate_purchase_token(purchase_token)
        url = PUBLISHER_ORIGIN + "/androidpublisher/v3/applications/" + package_name + "/purchases/subscriptionsv2/tokens/" + urllib.parse.quote(token, safe="")
        bearer = self._tokens.token()
        try:
            reply = self._transport.request("GET", url, {"Authorization": "Bearer " + bearer, "Accept": "application/json"},
                None, TIMEOUT_SECONDS, MAX_RESPONSE_BYTES)
        except ContractError:
            raise
        except Exception:
            raise ContractError(502, "Google verification service unavailable") from None
        if reply.status in (404, 410):
            raise ContractError(409, "purchase is unavailable or no longer verifiable")
        if reply.status == 401:
            self._tokens.invalidate()  # no automatic retry or repeated requests
        if reply.status != 200:
            raise ContractError(502, "Google purchase verification unavailable")
        result = json_object(reply.body, MAX_RESPONSE_BYTES)
        if result.get("kind") != "androidpublisher#subscriptionPurchaseV2":
            raise ContractError(502, "Google verification service returned an invalid purchase")
        return result
