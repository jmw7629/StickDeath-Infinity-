"""Service-only adapter to register validated private bytes for owner review."""
from datetime import datetime, timezone
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
from .auth import NoRedirect
from .store import IntakeError, identifier


class ReviewRegistrar:
    def __init__(self, backend_url: str, service_key: str, artifact_root: Path,
                 consent_version: str, create_private_preview):
        parsed = urllib.parse.urlsplit(backend_url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or
                parsed.query or parsed.fragment or parsed.path not in ("", "/") or parsed.port not in (None,443)):
            raise ValueError("Configure the authorized HTTPS application backend.")
        if not service_key or not all(32 < ord(c) < 127 for c in service_key) or not consent_version:
            raise ValueError("Server credential and current consent version required.")
        self.base=backend_url.rstrip("/"); self.key=service_key
        self.root=Path(artifact_root).resolve(strict=True)
        self.consent_version=consent_version
        self.preview=create_private_preview

    def __call__(self, upload: str, owner: str, path: Path, metadata: dict, artifact_expires: float) -> str:
        upload,owner=identifier(upload),identifier(owner)
        if metadata.get("consent_version") != self.consent_version:
            raise IntakeError("Publishing terms changed. Confirm the current permissions before submitting.",409)
        path=Path(path)
        if path.is_symlink() or path.resolve(strict=True) != self.root/(upload+".mp4") or path.stat().st_size != metadata["size"]:
            raise IntakeError("Artifact identity changed.",409)
        # Host preview adapter must protect access, stream these immutable bytes,
        # support range playback, and never return a public permanent asset URL.
        url,expiry=self.preview(upload,owner,metadata["sha256"])
        parsed=urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
            raise IntakeError("Private review preview unavailable.",503)
        now=datetime.now(timezone.utc)
        if not isinstance(expiry,datetime) or expiry.tzinfo is None or not 0 < (expiry-now).total_seconds() <= 86400:
            raise IntakeError("Private review preview expiry unavailable.",503)
        payload={"upload":upload,"creator":owner,"metadata":metadata,"object_key":upload+".mp4",
                 "preview_url":url,"expires_at":expiry.isoformat(),
                 "artifact_expires_at":datetime.fromtimestamp(artifact_expires,timezone.utc).isoformat()}
        request=urllib.request.Request(self.base+"/rest/v1/rpc/sdi_register_upload",data=json.dumps(payload).encode(),method="POST",
            headers={"apikey":self.key,"Authorization":"Bearer "+self.key,"Content-Type":"application/json"})
        try:
            with urllib.request.build_opener(NoRedirect()).open(request,timeout=20) as response:
                raw=response.read(4097)
                if len(raw)>4096: raise ValueError()
                result=json.loads(raw)
        except (urllib.error.URLError,TimeoutError,OSError,ValueError):
            raise IntakeError("Review registration is unconfirmed. Retry this same upload ID.",503) from None
        if not isinstance(result,dict) or result.get("error") or not result.get("review_id"):
            raise IntakeError("Review registration was not confirmed. Retain the local export and retry this upload.",409)
        return identifier(result["review_id"])

    def artifact_released(self, upload: str, review):
        """Fail closed on uncertain retirement; never delete from an HTTP error."""
        payload = {"upload": identifier(upload), "review": identifier(review) if review else None}
        request = urllib.request.Request(self.base+"/rest/v1/rpc/sdi_retire_upload",
            data=json.dumps(payload).encode(), method="POST",
            headers={"apikey": self.key, "Authorization": "Bearer "+self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=10) as response:
                raw = response.read(4097)
                if len(raw) > 4096:
                    return False
                return json.loads(raw) is True
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            return False

    def preview_authority(self, upload: str, owner: str, digest: str):
        payload={"upload":identifier(upload),"creator":identifier(owner),"digest":digest}
        request=urllib.request.Request(self.base+"/rest/v1/rpc/sdi_upload_preview",data=json.dumps(payload).encode(),method="POST",
            headers={"apikey":self.key,"Authorization":"Bearer "+self.key,"Content-Type":"application/json"})
        try:
            with urllib.request.build_opener(NoRedirect()).open(request,timeout=10) as response:
                raw=response.read(4097)
                if len(raw)>4096: return None
                result=json.loads(raw)
            if not isinstance(result,dict) or type(result.get("byte_count")) is not int or not isinstance(result.get("expires"),(int,float)):
                return None
            return result
        except (urllib.error.URLError,TimeoutError,OSError,ValueError):
            return None

    def renew_preview(self, authorization: str, review: str, digest: str, version: int):
        """Called by the authenticated host route; gateway/MFA issue a short permit,
        and only this server credential can install the freshly signed URL.
        """
        import fcntl
        import os
        import stat
        if (not authorization.startswith("Bearer ") or not all(32 <= ord(c) < 127 for c in authorization) or
                type(version) is not int or version < 1):
            raise IntakeError("Current review authorization required.",401)
        def call(operation, payload, token):
            request=urllib.request.Request(self.base+"/rest/v1/rpc/"+operation,data=json.dumps(payload).encode(),method="POST",
                headers={"apikey":self.key,"Authorization":token,"Content-Type":"application/json"})
            try:
                with urllib.request.build_opener(NoRedirect()).open(request,timeout=10) as response:
                    raw=response.read(8193)
                    if len(raw)>8192: raise ValueError()
                    value=json.loads(raw)
            except (urllib.error.URLError,TimeoutError,OSError,ValueError):
                raise IntakeError("Preview renewal unavailable. Refresh before retrying.",503) from None
            if not isinstance(value,dict) or value.get("error"):
                raise IntakeError("Current review permission and retained render required.",403)
            return value
        grant=call("sdi_preview_permit",{"review":identifier(review),"digest":digest,"version":version},authorization)
        upload=identifier(grant.get("upload")); creator=identifier(grant.get("creator")); permit=identifier(grant.get("permit"))
        if grant.get("digest") != digest: raise IntakeError("Render changed.",409)
        lock=os.open(self.root/(upload+".lock"),os.O_RDONLY|os.O_NOFOLLOW)
        try:
            fcntl.flock(lock,fcntl.LOCK_SH|fcntl.LOCK_NB)
            fd=os.open(self.root/(upload+".mp4"),os.O_RDONLY|os.O_NOFOLLOW)
            try:
                info=os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_size!=grant.get("byte_count"):
                    raise IntakeError("Retained render unavailable.",410)
            finally: os.close(fd)
            url,expiry=self.preview(upload,creator,digest)
            return call("sdi_preview_renew",{"permit":permit,"url":url,"expires":expiry.isoformat()},"Bearer "+self.key)
        finally: os.close(lock)
