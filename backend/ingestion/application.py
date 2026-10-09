"""Explicit WSGI factory for the private intake host; importing starts nothing."""
from __future__ import annotations

import os
from pathlib import Path
import stat
import threading
from urllib.parse import urlsplit

from .auth import AccountAuthorizer
from .http import UploadApplication
from .media import MediaValidator
from .preview import PreviewApplication, PreviewLinks
from .registration import ReviewRegistrar
from .store import UploadStore


def _required(environment, name):
    value = environment.get(name, "")
    if not value or value != value.strip():
        raise ValueError("Missing or invalid intake setting: " + name)
    return value


def _secret_file(environment, name, binary=False):
    path = Path(_required(environment, name))
    if not path.is_absolute():
        raise ValueError("Secret file paths must be absolute.")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                info.st_mode & 0o077 or not 1 <= info.st_size <= 16384):
            raise ValueError("Use a bounded private worker-owned secret file.")
        value = source.read(16385)
    if binary:
        return value
    try:
        return value.decode("ascii").strip()
    except UnicodeError:
        raise ValueError("Invalid service credential encoding.") from None


class _Response:
    def __init__(self, response, capacity):
        self.response, self.capacity, self.closed = response, capacity, False

    def __iter__(self):
        try:
            yield from self.response
        finally:
            self.close()

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                close = getattr(self.response, "close", None)
                if close:
                    close()
            finally:
                self.capacity.release()


class IntakeApplication:
    def __init__(self, origin, upload, preview, concurrency):
        parsed = urlsplit(origin)  # PreviewLinks has already validated this origin.
        self.host = parsed.hostname.lower()
        self.upload, self.preview = upload, preview
        self.capacity = threading.BoundedSemaphore(concurrency)

    @staticmethod
    def reject(start_response, status, body):
        start_response(status, [("Content-Type", "application/json"),
            ("Content-Length", str(len(body))), ("Cache-Control", "no-store"),
            ("Retry-After", "5"), ("X-Content-Type-Options", "nosniff")])
        return [body]

    def __call__(self, environ, start_response):
        # Never trust client Forwarded/X-Forwarded-* headers. The approved gateway
        # must set the WSGI scheme and preserve this configured host itself.
        host = environ.get("HTTP_HOST", "").lower()
        if environ.get("wsgi.url_scheme") != "https" or host not in (self.host, self.host + ":443"):
            return self.reject(start_response, "421 Misdirected Request", b'{"error":"Invalid service origin."}')
        path = environ.get("PATH_INFO", "")
        if path.startswith("/v1/render-previews/"):
            target = self.preview
        elif path == "/v1/render-uploads" or path.startswith(("/v1/render-uploads/", "/v1/review-previews/")):
            target = self.upload
        else:
            return self.reject(start_response, "404 Not Found", b'{"error":"Route unavailable."}')
        if not self.capacity.acquire(blocking=False):
            return self.reject(start_response, "503 Service Unavailable", b'{"error":"Intake busy. Retry later."}')
        try:
            return _Response(target(environ, start_response), self.capacity)
        except BaseException:
            self.capacity.release()
            raise


def create_application(environment=None):
    """Call explicitly in the approved host's WSGI configuration, never a preview.

    No network requests, media decode, listener or retention scheduler is started.
    Construction initializes the private SQLite intake directory.
    """
    env = os.environ if environment is None else environment
    backend = _required(env, "SDI_BACKEND_URL")
    origin = _required(env, "SDI_INTAKE_ORIGIN")
    consent = _required(env, "SDI_PUBLISHING_CONSENT_VERSION")
    if len(consent) > 100 or not all(32 <= ord(c) < 127 for c in consent):
        raise ValueError("Invalid publishing consent version.")
    root = Path(_required(env, "SDI_INTAKE_DIRECTORY"))
    if not root.is_absolute():
        raise ValueError("Intake directory must be absolute.")
    quota = int(_required(env, "SDI_INTAKE_TOTAL_BYTES"))
    account_quota = int(env.get("SDI_INTAKE_ACCOUNT_BYTES", str(2 * 1024**3)))
    concurrency = int(env.get("SDI_INTAKE_CONCURRENCY", "2"))
    if not 1 <= concurrency <= 4 or not 1 <= account_quota <= quota <= 1024**4:
        raise ValueError("Invalid intake capacity limits.")
    links = PreviewLinks(origin, _secret_file(env, "SDI_PREVIEW_SIGNING_KEY_FILE", binary=True))
    authorize = AccountAuthorizer(backend, _required(env, "SDI_BACKEND_PUBLISHABLE_KEY"))
    service_key = _secret_file(env, "SDI_BACKEND_SERVICE_KEY_FILE")
    validate = MediaValidator(Path(_required(env, "SDI_FFPROBE")), Path(_required(env, "SDI_FFMPEG")))
    store = UploadStore(root, total_quota=quota, account_quota=account_quota)
    registrar = ReviewRegistrar(backend, service_key, store.root, consent, links)
    upload = UploadApplication(store, authorize, validate, registrar, registrar.renew_preview)
    preview = PreviewApplication(store.root, links, registrar.preview_authority)
    return IntakeApplication(origin, upload, preview, concurrency)
