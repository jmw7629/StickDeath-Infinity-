"""Bounded WSGI composition for the existing advice contract; imports start nothing."""
from __future__ import annotations

import json
import os
import threading
import urllib.parse
import urllib.request
from http import HTTPStatus

from backend.ingestion.application import _secret_file
from backend.ingestion.auth import AccountAuthorizer, NoRedirect
from backend.ingestion.store import IntakeError
from . import handler
from .metering import SqlMeter


class MeterRPC:
    """Only the service-only usage RPC, with bounded JSON and no redirects/retries."""

    def __init__(self, backend, secret, publishable_key):
        if not secret or len(secret) > 16384 or not all(32 < ord(c) < 127 for c in secret):
            raise ValueError("Invalid Spatter service credential.")
        if (not publishable_key or publishable_key == secret or
                not all(32 < ord(c) < 127 for c in publishable_key)):
            raise ValueError("A separate application API key is required.")
        self.url = backend + "/rest/v1/rpc/sdi_spatter_usage_meter"
        self.secret = secret
        self.api_key = publishable_key

    def __call__(self, function, params):
        if function != SqlMeter.FUNCTION:
            raise ValueError("Unsupported Spatter RPC.")
        body = json.dumps(params, allow_nan=False, separators=(",", ":")).encode()
        if len(body) > 4096:
            raise ValueError("Spatter meter request too large.")
        request = urllib.request.Request(self.url, data=body, method="POST", headers={
            "apikey": self.api_key, "Authorization": "Bearer " + self.secret, "Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=10) as response:
            raw = response.read(16385)
        if len(raw) > 16384:
            raise ValueError("Spatter meter response too large.")
        result = json.loads(raw)
        if not isinstance(result, dict):
            raise ValueError("Invalid Spatter meter response.")
        return result


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key.")
        result[key] = value
    return result


def _body(environ):
    # The approved gateway must reject conflicting framing and bound read time.
    # WSGI does not expose a portable per-read deadline or disconnect signal.
    length = environ.get("CONTENT_LENGTH", "")
    if environ.get("HTTP_TRANSFER_ENCODING") or not isinstance(length, str) or not length.isascii() or not length.isdigit() or len(length) > 6:
        raise handler.HandlerError(413, "bounded Content-Length required")
    length = int(length)
    if not 0 < length <= handler.MAX_BODY_BYTES:
        raise handler.HandlerError(413, "request too large")
    raw = environ["wsgi.input"].read(length)
    if not isinstance(raw, bytes) or len(raw) != length:
        raise handler.HandlerError(400, "incomplete request body")
    try:
        data = json.loads(raw, object_pairs_hook=_unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if not isinstance(data, dict) or set(data) - {"schemaVersion", "messages", "suggestedPromptId", "max_tokens", "temperature"}:
            raise ValueError()
        if "schemaVersion" in data and type(data["schemaVersion"]) is not int:
            raise ValueError()
        if "max_tokens" in data and (type(data["max_tokens"]) is not int or not 1 <= data["max_tokens"] <= 500):
            raise ValueError()
        if "temperature" in data and (type(data["temperature"]) not in (int, float) or not 0 <= data["temperature"] <= 1):
            raise ValueError()
        messages = data.get("messages")
        if not isinstance(messages, list) or any(not isinstance(m, dict) or set(m) != {"role", "content"} for m in messages):
            raise ValueError()
    except (ValueError, UnicodeError, RecursionError):
        raise handler.HandlerError(400, "malformed request") from None
    return raw


class SpatterApplication:
    def __init__(self, endpoint, *, verify_jwt=None, authorize=None, meter=None, provider=None, concurrency=2):
        parsed = urllib.parse.urlsplit(endpoint)
        if (not endpoint or not all(32 < ord(c) < 127 for c in endpoint) or
                any(c in endpoint for c in ("%", "\\", "?", "#")) or
                parsed.scheme != "https" or not parsed.hostname or parsed.username is not None or
                parsed.password is not None or parsed.netloc.endswith(":") or parsed.port not in (None, 443) or
                not parsed.path.startswith("/") or parsed.path.endswith("/") or "//" in parsed.path or
                any(p in (".", "..") for p in parsed.path.split("/"))):
            raise ValueError("Configure an exact HTTPS Spatter endpoint.")
        if type(concurrency) is not int or not 1 <= concurrency <= 4:
            raise ValueError("Spatter concurrency must be 1..4.")
        self.host, self.path = parsed.hostname.lower(), parsed.path
        self.verify_jwt, self.authorize = verify_jwt, authorize
        self.meter, self.provider = meter, provider if provider is not None else handler.NullProvider()
        self.capacity = threading.BoundedSemaphore(concurrency)

    @staticmethod
    def respond(start_response, response):
        body = response.json().encode()
        if len(body) > handler.MAX_BODY_BYTES:
            response = handler.Response(502, {"schemaVersion": 1, "error": "provider response too large"})
            body = response.json().encode()
        headers = [("Content-Type", "application/json"), ("Content-Length", str(len(body))),
                   ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")]
        if response.status in (429, 503):
            headers.append(("Retry-After", "5"))
        if response.status == 405:
            headers.append(("Allow", "POST"))
        start_response(f"{response.status} {HTTPStatus(response.status).phrase}", headers)
        return [body]

    def __call__(self, environ, start_response):
        acquired = False
        try:
            if environ.get("wsgi.url_scheme") != "https" or environ.get("HTTP_HOST", "").lower() not in (self.host, self.host + ":443"):
                raise handler.HandlerError(421, "invalid service origin")
            if environ.get("PATH_INFO") != self.path or environ.get("QUERY_STRING", ""):
                raise handler.HandlerError(404, "route unavailable")
            if environ.get("REQUEST_METHOD") != "POST":
                raise handler.HandlerError(405, "unsupported method")
            authorization = environ.get("HTTP_AUTHORIZATION", "")
            handler._bearer({"Authorization": authorization})
            if environ.get("CONTENT_TYPE", "").split(";", 1)[0].strip().lower() != "application/json":
                raise handler.HandlerError(415, "JSON required")
            if environ.get("HTTP_CONTENT_ENCODING", environ.get("CONTENT_ENCODING", "")):
                raise handler.HandlerError(415, "encoded request unsupported")
            acquired = self.capacity.acquire(blocking=False)
            if not acquired:
                raise handler.HandlerError(503, "Spatter busy")
            raw = _body(environ)
            if (self.verify_jwt is None or self.authorize is None or self.meter is None or
                    isinstance(self.provider, handler.NullProvider) or getattr(self.provider, "configured", True) is False):
                raise handler.HandlerError(503, "not configured")

            def verify(token):
                claims = self.verify_jwt(token)
                actor = handler._user_id(claims)  # Refuse anon/service roles before the live RPC.
                try:
                    current_actor = self.authorize("Bearer " + token)
                except IntakeError as error:
                    raise handler.HandlerError(error.status, "authorization unavailable" if error.status == 503 else "unauthorized") from None
                except Exception:
                    raise handler.HandlerError(503, "authorization unavailable") from None
                if actor != current_actor:
                    raise handler.HandlerError(401, "unauthorized")
                return claims

            response = handler.handle({"Authorization": authorization}, raw, verify_jwt=verify,
                                      meter=self.meter, provider=self.provider)
        except handler.HandlerError as error:
            response = handler.Response(error.status, {"schemaVersion": 1, "error": error.reason})
        except Exception:
            response = handler.Response(503, {"schemaVersion": 1, "error": "Spatter unavailable"})
        finally:
            if acquired:
                self.capacity.release()
        return self.respond(start_response, response)


def create_application(environment=None, *, verify_jwt=None, provider=None):
    """Explicit host factory. The host injects a vetted verifier and provider.

    No listener, provider request, SQL request or secret read occurs on import.
    Missing collaborators/configuration produce 503 without any provider call.
    """
    env = os.environ if environment is None else environment
    app = SpatterApplication(env.get("SDI_SPATTER_URL", ""), verify_jwt=verify_jwt, provider=provider,
                             concurrency=int(env.get("SDI_SPATTER_CONCURRENCY", "2")))
    if verify_jwt is None or isinstance(app.provider, handler.NullProvider) or getattr(app.provider, "configured", True) is False:
        return app
    if not all(env.get(k) for k in ("SDI_BACKEND_URL", "SDI_BACKEND_PUBLISHABLE_KEY", "SDI_BACKEND_SERVICE_KEY_FILE")):
        return app
    app.authorize = AccountAuthorizer(env["SDI_BACKEND_URL"], env["SDI_BACKEND_PUBLISHABLE_KEY"])
    app.meter = SqlMeter(MeterRPC(app.authorize.base, _secret_file(env, "SDI_BACKEND_SERVICE_KEY_FILE"),
                                env["SDI_BACKEND_PUBLISHABLE_KEY"]))
    return app
