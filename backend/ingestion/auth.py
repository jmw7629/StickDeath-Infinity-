"""Current-session authorization through the configured application's own API."""
import json
import urllib.error
import urllib.parse
import urllib.request
from .store import IntakeError, identifier


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


class AccountAuthorizer:
    def __init__(self, backend_url: str, publishable_key: str):
        parsed = urllib.parse.urlsplit(backend_url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or
                parsed.query or parsed.fragment or parsed.path not in ("", "/") or parsed.port not in (None,443)):
            raise ValueError("Configure the authorized HTTPS application backend.")
        if not publishable_key or not all(32 < ord(c) < 127 for c in publishable_key):
            raise ValueError("Configured application API key required.")
        self.base = backend_url.rstrip("/"); self.key = publishable_key

    def __call__(self, authorization: str) -> str:
        if (not authorization.startswith("Bearer ") or not 8 <= len(authorization) <= 16384 or
                not all(32 <= ord(c) < 127 for c in authorization)):
            raise IntakeError("Current account authorization required.",401)
        # The backend gateway validates the JWT before the RPC checks its live
        # session/account. Never decode client JWT claims as proof of identity.
        request = urllib.request.Request(self.base+"/rest/v1/rpc/sdi_upload_identity",data=b"{}",method="POST",
            headers={"apikey":self.key,"Authorization":authorization,"Content-Type":"application/json"})
        try:
            with urllib.request.build_opener(NoRedirect()).open(request,timeout=10) as response:
                raw = response.read(4097)
                if len(raw)>4096: raise IntakeError("Authorization service unavailable.",503)
                data = json.loads(raw)
        except urllib.error.HTTPError as error:
            if error.code in (401,403): raise IntakeError("Sign in again before uploading.",401) from None
            raise IntakeError("Authorization service unavailable.",503) from None
        except (urllib.error.URLError,TimeoutError,OSError,ValueError):
            raise IntakeError("Authorization service unavailable.",503) from None
        if not isinstance(data,dict) or data.get("authorized") is not True:
            raise IntakeError("This account cannot upload. Sign in or contact support.",403)
        return identifier(data.get("actor"))
