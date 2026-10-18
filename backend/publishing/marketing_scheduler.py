"""Scheduled marketing cadence job (#283): social plugs and the email blast.

One invocation from the host timer (``python3 -m backend.publishing.marketing_scheduler``):

1. ``sdi_marketing_cadence_due`` – for each enabled destination whose daily/weekly
   slot has passed, the database queues the earliest draft the owner already
   approved, after re-checking the exact render's release approval and the
   creator's marketing consent. The cadence never approves anything.
2. Only in live mode: claim up to ``max_jobs`` leased drafts. Social drafts go to the
   destination adapters (``destinations.py``: Discord webhook, Facebook Page; the
   others report unavailable). An ``email`` draft becomes a blast: recipients come
   from ``sdi_email_recipients('marketing')`` (opted in, active, not suppressed) and
   are queued with ``EmailQueue.enqueue_blast`` under the draft id as dedup key, so a
   retried draft never mails anyone twice. ``EmailWorker`` sends later and re-checks
   suppression. The draft is finished with the enqueued count (``email-queue:<n>``).

Dry run is the default: step 1 runs (it only moves approved drafts into the queue,
as the hourly sweep already does), nothing is claimed, posted or emailed. Live mode
needs both ``--live`` and ``SDI_MARKETING_LIVE=1``; each adapter additionally needs
its own target and credential file. Credentials are read from files named by
environment variables at send time and never printed.

Environment: ``SDI_BACKEND_URL``, ``SDI_SERVICE_KEY``; Discord ``SDI_DISCORD_WEBHOOK_ID``,
``SDI_DISCORD_WEBHOOK_TOKEN_FILE``, optional ``SDI_DISCORD_GUILD_ID``; Facebook
``SDI_FACEBOOK_PAGE_ID``, ``SDI_FACEBOOK_PAGE_TOKEN_FILE``; email ``SDI_MAIL_QUEUE_PATH``,
``SDI_UNSUBSCRIBE_BASE_URL`` (https), ``SDI_UNSUBSCRIBE_SECRET_FILE`` (>= 32 bytes).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Dict, List, Mapping, Optional, Tuple

from ..mail.queue import EmailQueue, enqueue_blast
from ..mail.templates import render, unsubscribe_token
from .destinations import (MAX_RESPONSE_BYTES, Destination, DestinationConfig, MarketingJobAPI, MarketingWorker,
                           Transport, default_registry)
from .worker import JobAPI

BLAST_TEMPLATE = "marketing_campaign"
DEFAULT_HEADLINE = "New from StickDeath Infinity"
MAX_RECIPIENT_PAGES = 200
EMAIL_SETTINGS = ("SDI_MAIL_QUEUE_PATH", "SDI_UNSUBSCRIBE_BASE_URL", "SDI_UNSUBSCRIBE_SECRET_FILE")


class EmailRecipientsAPI(JobAPI):
    PREFIX = "sdi_email_"
    PERMITTED = frozenset({"recipients"})


def unsubscribe_url_factory(base_url: str, secret: bytes) -> Callable[[str, str], str]:
    parts = urllib.parse.urlsplit(base_url)
    if parts.scheme != "https" or not parts.netloc or parts.query or parts.fragment:
        raise ValueError("unsubscribe base url must be https without query")
    if len(secret) < 32:
        raise ValueError("unsubscribe secret too short")

    def url_for(address_hash: str, category: str) -> str:
        return "%s?token=%s" % (base_url, unsubscribe_token(secret, address_hash, category))
    return url_for


class EmailBlaster:
    """Turns one leased email draft into queued opt-in messages; sends nothing."""

    def __init__(self, recipients_api, queue: EmailQueue, unsubscribe_url_for: Callable[[str, str], str],
                 page_size: int = 500, max_pages: int = MAX_RECIPIENT_PAGES):
        if not 1 <= page_size <= 1000 or not 1 <= max_pages <= 1000:
            raise ValueError("page bounds invalid")
        self.api, self.queue, self.unsubscribe_url_for = recipients_api, queue, unsubscribe_url_for
        self.page_size, self.max_pages = page_size, max_pages

    @staticmethod
    def context(job: Mapping[str, object]) -> Dict[str, str]:
        headline = str(job.get("title") or "").strip() or DEFAULT_HEADLINE
        body = str(job.get("copy") or "")
        if job.get("media_url"):
            body = "%s\n\nWatch: %s" % (body, job["media_url"])
        return {"headline": headline[:150], "body": body}

    def blast(self, job: Mapping[str, object]) -> Dict[str, int]:
        context = self.context(job)
        render(BLAST_TEMPLATE, context, "https://validation.invalid/u")  # raises ValueError before any recipient is read
        totals = {"queued": 0, "duplicate": 0, "refused": 0, "pages": 0}
        for page in range(self.max_pages):
            result = self.api.call("recipients", category="marketing", batch=self.page_size, page=page)
            if not isinstance(result, Mapping) or "error" in result or not isinstance(result.get("recipients"), list):
                raise RuntimeError("recipient lookup refused")
            counts = enqueue_blast(self.queue, result["recipients"], BLAST_TEMPLATE, context,
                                   "marketing-draft:%s" % job["draft"], self.unsubscribe_url_for)
            for key in ("queued", "duplicate", "refused"):
                totals[key] += counts[key]
            totals["pages"] += 1
            if not result.get("has_more"):
                break
        else:
            totals["truncated"] = 1
        return totals


class MarketingScheduler:
    def __init__(self, api: MarketingJobAPI, worker: MarketingWorker, *, live: bool = False,
                 blaster: Optional[EmailBlaster] = None, email_reason: str = "", max_jobs: int = 10):
        if not 1 <= max_jobs <= 100:
            raise ValueError("max_jobs must be 1..100")
        self.api, self.worker, self.live = api, worker, live
        self.blaster, self.email_reason, self.max_jobs = blaster, email_reason, max_jobs

    def run_once(self) -> dict:
        report: Dict[str, object] = {"mode": "live" if self.live else "dry_run"}
        try:
            due = self.api.call("cadence_due")
            scheduled = due.get("queued", []) if isinstance(due, Mapping) else []
            report["scheduled"] = [{"draft": item.get("draft"), "destination": item.get("destination")}
                                   for item in scheduled if isinstance(item, Mapping)]
        except Exception as error:
            report["scheduled"] = []
            report["cadence_error"] = type(error).__name__
        if not self.live:
            report["posting"] = "skipped: dry run; nothing was claimed, posted or emailed"
            return report
        results: List[dict] = []
        for _ in range(self.max_jobs):
            job = self.api.call("claim")
            if not isinstance(job, Mapping) or job.get("empty"):
                break
            results.append(self._email(job) if job.get("destination") == "email" else self.worker.process(job))
        report["jobs"] = [{k: v for k, v in r.items() if k != "request"} for r in results]
        return report

    def _fail(self, job, reason: str) -> dict:
        self.api.call("finish", draft=job["draft"], token=job["lease"], failure=reason)
        return {"state": "failed", "draft": job["draft"], "reason": reason}

    def _email(self, job: Mapping[str, object]) -> dict:
        if self.blaster is None:
            return self._fail(job, "Email blast not configured: %s" % (self.email_reason or "missing settings"))
        try:
            counts = self.blaster.blast(job)
        except ValueError as error:
            return self._fail(job, "Draft content invalid for email: %s" % error)
        except Exception:
            return self._fail(job, "Recipient lookup failed; addresses already queued stay deduplicated on retry.")
        enqueued = counts["queued"] + counts["duplicate"]
        if enqueued == 0:
            return self._fail(job, "No opted-in, unsuppressed recipients; nothing was queued.")
        accepted = self.api.call("finish", draft=job["draft"], token=job["lease"], provider_ref="email-queue:%d" % enqueued)
        return {"state": "published" if accepted is True else "late_result", "draft": job["draft"],
                "queued": counts["queued"], "duplicate": counts["duplicate"], "refused": counts["refused"]}


# --------------------------------------------------------------------------- environment wiring

def _file_reader(path: str) -> Callable[[], str]:
    def read() -> str:
        with open(path, "r", encoding="utf-8") as handle:
            value = handle.read(8192).strip()
        if not value:
            raise ValueError("credential file empty")
        return value
    return read


def registry_from_environment(environment: Mapping[str, str], live: bool) -> Dict[str, Destination]:
    configs: Dict[str, DestinationConfig] = {}
    if environment.get("SDI_DISCORD_WEBHOOK_ID") and environment.get("SDI_DISCORD_WEBHOOK_TOKEN_FILE"):
        configs["discord"] = DestinationConfig(enabled=True, dry_run=not live, target=environment["SDI_DISCORD_WEBHOOK_ID"].strip(),
                                               guild_id=(environment.get("SDI_DISCORD_GUILD_ID") or "").strip() or None,
                                               credential=_file_reader(environment["SDI_DISCORD_WEBHOOK_TOKEN_FILE"]))
    if environment.get("SDI_FACEBOOK_PAGE_ID") and environment.get("SDI_FACEBOOK_PAGE_TOKEN_FILE"):
        configs["facebook"] = DestinationConfig(enabled=True, dry_run=not live, target=environment["SDI_FACEBOOK_PAGE_ID"].strip(),
                                                credential=_file_reader(environment["SDI_FACEBOOK_PAGE_TOKEN_FILE"]))
    return default_registry(configs)


def blaster_from_environment(environment: Mapping[str, str], recipients_api) -> Tuple[Optional[EmailBlaster], str]:
    missing = [name for name in EMAIL_SETTINGS if not (environment.get(name) or "").strip()]
    if missing:
        return None, "missing " + ", ".join(missing)
    try:
        with open(environment["SDI_UNSUBSCRIBE_SECRET_FILE"], "rb") as handle:
            secret = handle.read(4096).strip()
        url_for = unsubscribe_url_factory(environment["SDI_UNSUBSCRIBE_BASE_URL"].strip(), secret)
        queue = EmailQueue(Path(environment["SDI_MAIL_QUEUE_PATH"]))
    except (OSError, ValueError):
        return None, "unsubscribe secret, base url or queue path unusable"
    return EmailBlaster(recipients_api, queue, url_for), ""


def urllib_transport(method: str, url: str, headers: Mapping[str, str], body: bytes):
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    request = urllib.request.Request(url, data=body, method=method, headers=dict(headers))
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            return response.status, dict(response.headers), response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers or {}), error.read(MAX_RESPONSE_BYTES + 1)


def main(argv: Optional[list] = None, environment: Optional[Mapping[str, str]] = None,
         api_factory: Optional[Callable[[], MarketingJobAPI]] = None,
         recipients_factory: Optional[Callable[[], EmailRecipientsAPI]] = None,
         transport: Optional[Transport] = None) -> int:
    parser = argparse.ArgumentParser(description="Run the marketing cadence once (dry run unless --live and SDI_MARKETING_LIVE=1).")
    parser.add_argument("--live", action="store_true", help="claim and post/queue approved drafts")
    parser.add_argument("--max-jobs", type=int, default=10)
    args = parser.parse_args(argv)
    environment = os.environ if environment is None else environment
    if args.live and environment.get("SDI_MARKETING_LIVE") != "1":
        print(json.dumps({"state": "refused", "reason": "--live requires SDI_MARKETING_LIVE=1; nothing ran."}))
        return 2
    try:
        api = api_factory() if api_factory else MarketingJobAPI(environment["SDI_BACKEND_URL"], environment["SDI_SERVICE_KEY"])
        recipients = recipients_factory() if recipients_factory else EmailRecipientsAPI(environment["SDI_BACKEND_URL"], environment["SDI_SERVICE_KEY"])
    except (KeyError, ValueError):
        print(json.dumps({"state": "not_configured", "reason": "Backend URL and service key are not configured; nothing ran."}))
        return 2
    registry = registry_from_environment(environment, args.live)
    blaster, email_reason = blaster_from_environment(environment, recipients) if args.live else (None, "dry run")
    worker = MarketingWorker(api, registry, (transport or urllib_transport) if args.live else None)
    scheduler = MarketingScheduler(api, worker, live=args.live, blaster=blaster, email_reason=email_reason, max_jobs=args.max_jobs)
    report = scheduler.run_once()
    report["destinations"] = {key: {"configured": d.status()["configured"], "dry_run": d.status()["dry_run"]}
                              for key, d in sorted(registry.items())}
    report["email"] = {"configured": blaster is not None, "reason": email_reason}
    print(json.dumps(report, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
