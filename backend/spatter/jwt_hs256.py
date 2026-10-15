"""Standard-library verifier for Supabase access tokens signed with HS256.

Legacy Supabase projects sign access tokens with the project JWT secret. The
deployment reads that secret from its own environment and passes the bytes to
``make_hs256_verifier``; nothing here reads, stores or logs it. Projects that
use asymmetric signing keys (RS256/ES256 via JWKS) need a verifier backed by a
vetted crypto library; this module refuses those tokens rather than guessing.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time as _time
from typing import Any, Callable, Dict

MAX_TOKEN_BYTES = 16_384


class TokenRejected(Exception):
    """Generic rejection. The message never contains token material."""

    def __init__(self) -> None:
        super().__init__("unauthorized")


def _b64(segment: str) -> bytes:
    if not segment or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for c in segment):
        raise TokenRejected()
    return base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))


def make_hs256_verifier(secret: bytes, issuer: str, audience: str = "authenticated",
                        leeway_seconds: int = 30,
                        now: Callable[[], float] = _time.time) -> Callable[[str], Dict[str, Any]]:
    if not isinstance(secret, (bytes, bytearray)) or len(secret) < 32:
        raise ValueError("HS256 secret must be at least 32 bytes")
    if not issuer:
        raise ValueError("issuer is required")
    key = bytes(secret)

    def verify(token: str) -> Dict[str, Any]:
        if not isinstance(token, str) or len(token.encode()) > MAX_TOKEN_BYTES or token.count(".") != 2:
            raise TokenRejected()
        head_b64, body_b64, sig_b64 = token.split(".")
        try:
            header = json.loads(_b64(head_b64))
            claims = json.loads(_b64(body_b64))
            signature = _b64(sig_b64)
        except (ValueError, UnicodeDecodeError):
            raise TokenRejected() from None
        if not isinstance(header, dict) or header.get("alg") != "HS256" or not isinstance(claims, dict):
            raise TokenRejected()
        expected = hmac.new(key, (head_b64 + "." + body_b64).encode("ascii"), hashlib.sha256).digest()
        if not hmac.compare_digest(expected, signature):
            raise TokenRejected()
        current = now()
        exp, nbf = claims.get("exp"), claims.get("nbf")
        if not isinstance(exp, (int, float)) or isinstance(exp, bool) or exp + leeway_seconds <= current:
            raise TokenRejected()
        if nbf is not None and (not isinstance(nbf, (int, float)) or nbf - leeway_seconds > current):
            raise TokenRejected()
        aud = claims.get("aud")
        if not (aud == audience or (isinstance(aud, list) and audience in aud)):
            raise TokenRejected()
        if claims.get("iss") != issuer:
            raise TokenRejected()
        return claims

    return verify
