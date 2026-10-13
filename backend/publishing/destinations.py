"""Destination adapters for owner-approved marketing posts (#243, #283) and the
marketing worker that binds them to ``marketing-workspace.sql``.

Every adapter answers one of four honest states:

* ``unavailable`` – the destination is not configured (no credential, no target)
  or has no supported API; nothing was attempted.
* ``dry_run`` – the exact request is returned for review; nothing was sent. This
  is the only mode in development and test environments.
* ``published`` – the provider confirmed the post and returned an id/link.
* ``failed`` – the provider refused; the reason never includes a credential.

Credentials are read through an injected callable at send time, never stored on
the adapter and never written into an ``Outcome``. The worker posts only a draft
that the database leased after re-checking the owner's approval of the exact render
and the creator's marketing consent; a dry-run result is recorded as a failure with
a plain reason so nothing is ever marked published without a provider receipt.

Platform notes (facts to confirm before enabling; none is a claim of access):
* Discord: an incoming webhook posts a message with a link; message text ≤ 2000.
* Facebook: a Page post needs a Page access token with publishing permission and
  App Review for public use; text + link.
* X: posting needs an API tier with write access; text ≤ 280 characters.
* YouTube: community posts have no public API; channel uploads go through the
  publishing worker, so this adapter only shares an existing public link.
* Instagram and TikTok: both require business/app-review onboarding and hosted
  media; not implemented, reported unavailable.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Callable, Dict, Mapping, Optional, Tuple
from urllib.parse import urlsplit

from .worker import JobAPI

Transport = Callable[[str, str, Mapping[str, str], bytes], Tuple[int, Mapping[str, str], bytes]]
MAX_RESPONSE_BYTES = 65536


@dataclass(frozen=True)
class Post:
    destination: str
    copy: str
    media_url: Optional[str] = None
    title: str = ""
    digest: Optional[str] = None

    def __post_init__(self):
        if not self.copy or len(self.copy) > 2000:
            raise ValueError("copy must be 1..2000 characters")
        if self.media_url is not None and (not self.media_url.startswith("https://") or len(self.media_url) > 2048):
            raise ValueError("media_url must be https")


@dataclass
class PostRequest:
    method: str
    url: str
    headers: Dict[str, str]
    body: Dict[str, object]

    def redacted(self) -> dict:
        headers = {k: ("<redacted>" if k.lower() == "authorization" else v) for k, v in self.headers.items()}
        body = {k: ("<redacted>" if k == "access_token" else v) for k, v in self.body.items()}
        url = self.url
        parts = urlsplit(url)
        if "webhooks" in parts.path:   # Discord webhook URLs embed their token
            url = "%s://%s/api/webhooks/<redacted>" % (parts.scheme, parts.netloc)
        return {"method": self.method, "url": url, "headers": headers, "body": body}


@dataclass
class Outcome:
    state: str
    reason: str = ""
    result_url: Optional[str] = None
    provider_ref: Optional[str] = None
    request: Optional[dict] = None

    def __post_init__(self):
        if self.state not in ("unavailable", "dry_run", "published", "failed"):
            raise ValueError("unknown outcome state")


@dataclass(frozen=True)
class DestinationConfig:
    """Non-secret configuration. ``credential`` is called at send time only."""
    enabled: bool = False
    dry_run: bool = True
    target: Optional[str] = None            # page id, channel id, webhook path holder, etc.
    guild_id: Optional[str] = None
    credential: Optional[Callable[[], str]] = field(default=None, compare=False, repr=False)


class Destination:
    key = ""
    host = ""

    def __init__(self, config: Optional[DestinationConfig] = None):
        self.config = config or DestinationConfig()

    @property
    def configured(self) -> bool:
        return bool(self.config.enabled and self.config.target and self.config.credential)

    def status(self) -> dict:
        return {"key": self.key, "configured": self.configured, "dry_run": self.config.dry_run,
                "reason": "" if self.configured else "not configured: owner must supply the target and a server-held credential"}

    def prepare(self, post: Post, credential: str) -> PostRequest:  # pragma: no cover - abstract
        raise NotImplementedError

    def parse(self, status: int, body: bytes) -> Outcome:  # pragma: no cover - abstract
        raise NotImplementedError

    def publish(self, post: Post, transport: Optional[Transport] = None) -> Outcome:
        if post.destination != self.key:
            return Outcome("failed", "post addressed to a different destination")
        if not self.configured:
            return Outcome("unavailable", self.status()["reason"])
        try:
            request = self.prepare(post, "<credential>" if self.config.dry_run else self.config.credential())
        except ValueError as error:
            return Outcome("failed", str(error))
        if self.config.dry_run or transport is None:
            return Outcome("dry_run", "dry run: nothing was sent", request=request.redacted())
        if urlsplit(request.url).netloc != self.host:
            return Outcome("failed", "request host is not the provider host")
        try:
            status, _, body = transport(request.method, request.url, request.headers, json.dumps(request.body).encode())
        except Exception:
            return Outcome("failed", "provider unreachable")
        if len(body) > MAX_RESPONSE_BYTES:
            return Outcome("failed", "provider response too large")
        return self.parse(status, body)


def _json(body: bytes) -> dict:
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


class DiscordWebhook(Destination):
    key = "discord"
    host = "discord.com"

    def prepare(self, post: Post, credential: str) -> PostRequest:
        content = post.copy if not post.media_url else "%s\n%s" % (post.copy, post.media_url)
        if len(content) > 2000:
            raise ValueError("Discord messages are limited to 2000 characters including the link")
        # target: "<webhook id>", credential: webhook token (server-held).
        url = "https://discord.com/api/webhooks/%s/%s?wait=true" % (self.config.target, credential)
        return PostRequest("POST", url, {"Content-Type": "application/json"}, {"content": content, "allowed_mentions": {"parse": []}})

    def parse(self, status: int, body: bytes) -> Outcome:
        data = _json(body)
        if status in (200, 201) and isinstance(data.get("id"), str) and isinstance(data.get("channel_id"), str):
            link = "https://discord.com/channels/%s/%s/%s" % (self.config.guild_id or "@me", data["channel_id"], data["id"])
            return Outcome("published", result_url=link, provider_ref=data["id"])
        return Outcome("failed", "discord refused the message (status %d)" % status)


class FacebookPage(Destination):
    key = "facebook"
    host = "graph.facebook.com"

    def prepare(self, post: Post, credential: str) -> PostRequest:
        body: Dict[str, object] = {"message": post.copy, "access_token": credential}
        if post.media_url:
            body["link"] = post.media_url
        return PostRequest("POST", "https://graph.facebook.com/v21.0/%s/feed" % self.config.target, {"Content-Type": "application/json"}, body)

    def parse(self, status: int, body: bytes) -> Outcome:
        data = _json(body)
        if status == 200 and isinstance(data.get("id"), str):
            return Outcome("published", result_url="https://www.facebook.com/%s" % data["id"], provider_ref=data["id"])
        return Outcome("failed", "facebook refused the post (status %d)" % status)


class XPosts(Destination):
    key = "x"
    host = "api.x.com"

    def prepare(self, post: Post, credential: str) -> PostRequest:
        text = post.copy if not post.media_url else "%s %s" % (post.copy, post.media_url)
        # X counts any link as 23 characters.
        counted = len(post.copy) + (24 if post.media_url else 0)
        if counted > 280:
            raise ValueError("X posts are limited to 280 characters including the link")
        return PostRequest("POST", "https://api.x.com/2/tweets", {"Content-Type": "application/json", "Authorization": "Bearer " + credential}, {"text": text})

    def parse(self, status: int, body: bytes) -> Outcome:
        data = _json(body).get("data")
        if status == 201 and isinstance(data, dict) and isinstance(data.get("id"), str):
            return Outcome("published", result_url="https://x.com/i/web/status/%s" % data["id"], provider_ref=data["id"])
        return Outcome("failed", "x refused the post (status %d)" % status)


class UnavailableDestination(Destination):
    """A destination with no supported server-side posting path."""

    def __init__(self, key: str, reason: str):
        super().__init__(DestinationConfig())
        self.key = key
        self.reason = reason

    @property
    def configured(self) -> bool:
        return False

    def status(self) -> dict:
        return {"key": self.key, "configured": False, "dry_run": True, "reason": self.reason}

    def publish(self, post: Post, transport: Optional[Transport] = None) -> Outcome:
        return Outcome("unavailable", self.reason)


def default_registry(configs: Optional[Mapping[str, DestinationConfig]] = None) -> Dict[str, Destination]:
    configs = configs or {}
    return {
        "discord": DiscordWebhook(configs.get("discord")),
        "facebook": FacebookPage(configs.get("facebook")),
        "x": XPosts(configs.get("x")),
        "youtube": UnavailableDestination("youtube", "YouTube community posts have no public API; channel uploads go through the publishing worker."),
        "instagram": UnavailableDestination("instagram", "Instagram publishing needs a business account, app review and hosted media; not implemented."),
        "tiktok": UnavailableDestination("tiktok", "TikTok Content Posting API needs app audit; not implemented."),
        "email": UnavailableDestination("email", "Email campaigns go through backend/mail with consent and suppression checks, not this adapter."),
    }


class MarketingJobAPI(JobAPI):
    PREFIX = "sdi_marketing_"
    PERMITTED = frozenset({"claim", "finish", "cadence_due"})


class MarketingWorker:
    """Claims one leased draft, hands it to the adapter, reports the real result."""

    def __init__(self, api: MarketingJobAPI, registry: Mapping[str, Destination], transport: Optional[Transport] = None):
        self.api = api
        self.registry = registry
        self.transport = transport

    def run_once(self) -> dict:
        job = self.api.call("claim")
        if job.get("empty"):
            return {"state": "idle"}
        draft, token = job["draft"], job["lease"]
        adapter = self.registry.get(job.get("destination"))
        if adapter is None:
            self.api.call("finish", draft=draft, token=token, failure="Unknown destination.")
            return {"state": "failed", "draft": draft, "reason": "unknown destination"}
        try:
            post = Post(destination=job["destination"], copy=job["copy"], media_url=job.get("media_url"), title=job.get("title") or "", digest=job.get("digest"))
        except ValueError as error:
            self.api.call("finish", draft=draft, token=token, failure="Draft content invalid: %s" % error)
            return {"state": "failed", "draft": draft, "reason": str(error)}
        outcome = adapter.publish(post, self.transport)
        if outcome.state == "published":
            accepted = self.api.call("finish", draft=draft, token=token, result_url=outcome.result_url, provider_ref=outcome.provider_ref)
            return {"state": "published" if accepted is True else "late_result", "draft": draft, "result_url": outcome.result_url}
        reason = {"unavailable": "Destination unavailable: %s" % outcome.reason,
                  "dry_run": "Dry run only: destination posting is disabled in this environment; nothing was sent.",
                  "failed": "Provider refused: %s" % outcome.reason}[outcome.state]
        self.api.call("finish", draft=draft, token=token, failure=reason)
        return {"state": outcome.state, "draft": draft, "reason": reason, "request": outcome.request}
