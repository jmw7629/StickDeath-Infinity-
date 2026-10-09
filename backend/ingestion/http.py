"""WSGI adapter, intentionally not a standalone public server.

The host supplies current-session authorization, a bounded media validator and
idempotent private review registration. Never mount without all three adapters.
"""
from __future__ import annotations
import json
import sqlite3
from http import HTTPStatus
from pathlib import Path
from typing import Callable
from .store import UploadStore, IntakeError, CHUNK_BYTES, identifier


class UploadApplication:
    def __init__(self, store: UploadStore, authorize: Callable[[str], str],
                 validate_media: Callable[[Path], None], register_review: Callable, renew_preview: Callable | None = None):
        self.store = store
        self.authorize = authorize
        self.validate_media = validate_media
        self.register_review = register_review
        self.renew_preview = renew_preview

    @staticmethod
    def _body(environ, limit):
        length = environ.get("CONTENT_LENGTH", "")
        if not length.isdigit() or not 0 < int(length) <= limit:
            raise IntakeError("A bounded Content-Length is required.", 413)
        length = int(length)
        body = environ["wsgi.input"].read(length)
        if len(body) != length:
            raise IntakeError("Incomplete request body.")
        return body

    def __call__(self, environ, start_response):
        headers = [("Content-Type", "application/json"), ("Cache-Control", "no-store"),
                   ("X-Content-Type-Options", "nosniff")]
        status = 200
        try:
            token = environ.get("HTTP_AUTHORIZATION", "")
            if not token.startswith("Bearer ") or not 8 <= len(token) <= 16384:
                raise IntakeError("Current account authorization required.", 401)
            # Authorizer checks signature, current session, account control and
            # full (non-anonymous) identity. It must not trust unsigned JWT data.
            actor = identifier(self.authorize(token))
            method = environ.get("REQUEST_METHOD")
            parts = environ.get("PATH_INFO", "").strip("/").split("/")
            if parts[:2] == ["v1", "review-previews"] and len(parts) == 4 and parts[3] == "renew" and method == "POST":
                if self.renew_preview is None:
                    raise IntakeError("Preview renewal is not configured.",503)
                if environ.get("CONTENT_TYPE", "").split(";")[0] != "application/json":
                    raise IntakeError("JSON review identity required.",415)
                try:
                    payload = json.loads(self._body(environ,4096))
                    if not isinstance(payload,dict) or set(payload) != {"digest","version"}: raise ValueError()
                except (ValueError,UnicodeError):
                    raise IntakeError("Invalid review identity.") from None
                result = self.renew_preview(token,parts[2],payload["digest"],payload["version"])
            elif parts[:2] != ["v1", "render-uploads"] or len(parts) not in (2,3,4):
                raise IntakeError("Route unavailable.",404)
            elif len(parts) == 2 and method == "POST":
                if environ.get("CONTENT_TYPE", "").split(";")[0] != "application/json":
                    raise IntakeError("JSON metadata required.",415)
                try:
                    body = json.loads(self._body(environ,8192))
                except (ValueError, UnicodeError):
                    raise IntakeError("Invalid metadata JSON.") from None
                result = self.store.begin(actor,environ.get("HTTP_IDEMPOTENCY_KEY",""),body)
                status = 201
            elif len(parts) == 3 and method == "GET":
                result = self.store.status(actor,parts[2])
            elif len(parts) == 3 and method == "DELETE":
                result = self.store.cancel(actor,parts[2])
            elif len(parts) == 3 and method == "PATCH":
                if environ.get("CONTENT_TYPE", "") != "application/octet-stream":
                    raise IntakeError("Binary chunk required.",415)
                offset = environ.get("HTTP_UPLOAD_OFFSET", "")
                if not offset.isdigit() or len(offset) > 20:
                    raise IntakeError("Current upload offset required.")
                result = self.store.append(actor,parts[2],int(offset),self._body(environ,CHUNK_BYTES),
                                           environ.get("HTTP_UPLOAD_CHECKSUM", ""))
            elif len(parts) == 4 and parts[3] == "complete" and method == "POST":
                def register(upload, owner, path, metadata, artifact_expires):
                    # Repeat current authorization after hashing/probing the file.
                    if identifier(self.authorize(token)) != owner:
                        raise IntakeError("Account changed during submission.",401)
                    return self.register_review(upload,owner,path,metadata,artifact_expires)
                result = self.store.complete(actor,parts[2],validate_media=self.validate_media,register_review=register)
            else:
                raise IntakeError("Unsupported upload operation.",405)
        except IntakeError as error:
            status = error.status; result = {"error": str(error)}
        except (sqlite3.Error, OSError):
            status = 503; result = {"error": "Upload storage unavailable. Retain your local export and retry with the same request ID."}
        except Exception:
            # Never leak callback messages, private paths, tokens or provider data.
            status = 503; result = {"error": "Upload processing unavailable. Retry with the same upload ID; do not create a duplicate."}
        body = json.dumps(result,separators=(",", ":")).encode("utf-8")
        headers.append(("Content-Length",str(len(body))))
        if status in (409,429,503): headers.append(("Retry-After","5"))
        start_response(f"{status} {HTTPStatus(status).phrase}", headers)
        return [body]
