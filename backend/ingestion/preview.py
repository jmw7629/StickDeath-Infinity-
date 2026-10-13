"""Expiring capability URLs delivered only through protected review responses.

Mount behind existing HTTPS; strip tokens/query strings from gateway logs. This
is private bearer-link playback, not a public CDN or permanent media library.
"""
import base64
from datetime import datetime, timezone
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import stat
import time
import urllib.parse
from .store import DIGEST, identifier


class PreviewLinks:
    def __init__(self, origin: str, signing_key: bytes, lifetime: int = 600, clock=time.time):
        parsed=urllib.parse.urlsplit(origin)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or
                parsed.fragment or parsed.path not in ("", "/") or parsed.port not in (None,443)):
            raise ValueError("Configured private preview HTTPS origin required.")
        if not isinstance(signing_key,bytes) or len(signing_key)<32 or not 60<=lifetime<=900:
            raise ValueError("Private signing key and short preview lifetime required.")
        self.origin=origin.rstrip("/"); self.key=signing_key; self.lifetime=lifetime; self.clock=clock

    def __call__(self, upload, owner, digest):
        upload,owner=identifier(upload),identifier(owner)
        if not DIGEST.fullmatch(digest): raise ValueError("Invalid render checksum.")
        expires=int(self.clock())+self.lifetime
        raw=json.dumps([1,upload,owner,digest,expires],separators=(",", ":")).encode()
        encoded=base64.urlsafe_b64encode(raw).decode().rstrip("=")
        signature=hmac.new(self.key,encoded.encode(),hashlib.sha256).hexdigest()
        return self.origin+"/v1/render-previews/"+encoded+"."+signature, datetime.fromtimestamp(expires,timezone.utc)

    def verify(self, token):
        if not isinstance(token,str) or len(token)>1024 or token.count(".")!=1: raise ValueError()
        encoded,signature=token.split(".")
        if not re.fullmatch(r"[A-Za-z0-9_-]+",encoded) or not DIGEST.fullmatch(signature): raise ValueError()
        if not hmac.compare_digest(signature,hmac.new(self.key,encoded.encode(),hashlib.sha256).hexdigest()): raise ValueError()
        version,upload,owner,digest,expires=json.loads(base64.urlsafe_b64decode(encoded+"="*((-len(encoded))%4)))
        if version!=1 or type(expires) is not int or not self.clock()<expires<=self.clock()+900 or not DIGEST.fullmatch(digest): raise ValueError()
        return identifier(upload),identifier(owner),digest,expires


class PreviewApplication:
    def __init__(self, artifact_root: Path, links: PreviewLinks, authorize_artifact):
        self.root=Path(artifact_root).resolve(strict=True)
        self.links=links
        # Callback rechecks registration, current creator restrictions and
        # consent; returns {'byte_count': int, 'expires': UNIX-seconds} or None.
        self.authorize=authorize_artifact

    def __call__(self,environ,start_response):
        headers=[("Cache-Control","private, no-store"),("Referrer-Policy","no-referrer"),
                 ("X-Content-Type-Options","nosniff")]
        file=None; lock=None
        try:
            method=environ.get("REQUEST_METHOD")
            if method not in ("GET","HEAD"): raise ValueError()
            prefix="/v1/render-previews/"
            path=environ.get("PATH_INFO","")
            if not path.startswith(prefix): raise ValueError()
            upload,owner,digest,expires=self.links.verify(path[len(prefix):])
            # Shared reader lock uses the same retained inode as intake/expiry.
            lock=os.open(self.root/(upload+".lock"),os.O_RDONLY|os.O_NOFOLLOW)
            fcntl.flock(lock,fcntl.LOCK_SH|fcntl.LOCK_NB)
            authority=self.authorize(upload,owner,digest)
            if not authority or not self.links.clock()<authority["expires"]: raise ValueError()
            file=os.fdopen(os.open(self.root/(upload+".mp4"),os.O_RDONLY|os.O_NOFOLLOW),"rb")
            info=os.fstat(file.fileno()); size=authority["byte_count"]
            if type(size) is not int or size<=0 or not stat.S_ISREG(info.st_mode) or info.st_size!=size: raise ValueError()
            first,last=0,size-1; status="200 OK"
            requested=environ.get("HTTP_RANGE")
            if requested:
                match=re.fullmatch(r"bytes=([0-9]{0,20})-([0-9]{0,20})",requested)
                if not match or not any(match.groups()):
                    return self._range_error(start_response,headers,size,file,lock)
                left,right=match.groups()
                if left:
                    first=int(left); last=min(int(right),size-1) if right else size-1
                else:
                    suffix=int(right)
                    if suffix==0: return self._range_error(start_response,headers,size,file,lock)
                    first=max(0,size-suffix)
                if first>last or first>=size:
                    return self._range_error(start_response,headers,size,file,lock)
                status="206 Partial Content"; headers.append(("Content-Range",f"bytes {first}-{last}/{size}"))
            headers += [("Content-Type","video/mp4"),("Accept-Ranges","bytes"),("Content-Length",str(last-first+1))]
            file.seek(first)
            start_response(status,headers)
            if method=="HEAD":
                file.close(); os.close(lock); return []
            return OwnedStream(self._stream(file,last-first+1,min(expires,authority["expires"]),upload,owner,digest),file,lock)
        except Exception:
            if file is not None: file.close()
            if lock is not None: os.close(lock)
            body=b"Private preview unavailable or expired. Refresh the review queue."
            start_response("404 Not Found",headers+[("Content-Type","text/plain"),("Content-Length",str(len(body)))])
            return [body]

    @staticmethod
    def _range_error(start_response,headers,size,file,lock):
        file.close(); os.close(lock)
        start_response("416 Range Not Satisfiable",headers+[("Content-Range",f"bytes */{size}"),("Content-Length","0")])
        return []

    def _stream(self,file,remaining,expires,upload,owner,digest):
        check_at=0
        while remaining>0:
            now=self.links.clock()
            if now>=expires: return
            if now>=check_at:
                authority=self.authorize(upload,owner,digest)
                if not authority or now>=authority["expires"]: return
                check_at=now+5
            data=file.read(min(256*1024,remaining))
            if not data: return
            remaining-=len(data)
            yield data


class OwnedStream:
    """Release the reader lock even if WSGI closes before requesting byte one."""
    def __init__(self,iterator,file,lock):
        self.iterator=iterator; self.file=file; self.lock=lock; self.closed=False
    def __iter__(self): return self
    def __next__(self):
        if self.closed: raise StopIteration
        try: return next(self.iterator)
        except BaseException:
            self.close(); raise
    def close(self):
        if not self.closed:
            self.closed=True
            try: self.iterator.close()
            finally:
                self.file.close(); os.close(self.lock)
