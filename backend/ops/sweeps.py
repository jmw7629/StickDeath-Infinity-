"""Bounded service sweeps over the SQL candidates' service-role functions.

The README of ``backend/sql`` notes that nothing schedules the sweeps. This module
is the single, auditable place a host cron or systemd timer calls:

    python3 -m backend.ops.sweeps --all          # or --only billing_reconcile,...

Each sweep is one named RPC, except the local ``draft_preview_expire`` sweep, which
deletes only expired Spatter draft preview copies through
``backend.spatter.draft_preview.DraftPreviewStore.expire`` (and is skipped when draft
previews are not configured). The runner deletes no other files, never retries a sweep
that raised, records one worker heartbeat with a terse summary, and returns a
report whose failures carry an exception class name only (payloads could contain
member data). ``account_deletion_run`` loops until the database answers ``idle``
or ``waiting`` (bounded), because each call handles one request.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Callable, Dict, Iterable, Mapping, Optional

from ..publishing.worker import JobAPI
from .report import send_report

SWEEPS: Dict[str, str] = {
    "billing_reconcile": "billing_reconcile",
    "support_retention": "support_retention",
    "war_expire_proposals": "war_expire_proposals",
    "war_finalize": "war_finalize",
    "challenge_finalize": "challenge_finalize",
    "award_achievements": "award_achievements",
    "account_deletion_run": "account_deletion_run",
    "marketing_cadence_due": "marketing_cadence_due",
    # Room asset copies and project handoff snapshots (rooms-v2.sql): expired,
    # closed-room, ended-membership, changed-project and fully delivered copies.
    "room_asset_sweep": "room_asset_sweep",
}
LOOPING = {"account_deletion_run": ("action", {"idle", "waiting", "blocked"})}


def _draft_preview_expire(environment: Mapping[str, str]):
    """Delete expired owner-only draft preview copies (#212); None when unconfigured."""
    from ..spatter.draft_preview import draft_previews_from_env
    drafts = draft_previews_from_env(environment)
    if drafts is None:
        return None
    return {"removed": drafts.expire(), "retained_bytes": drafts.retained_bytes()}


# Sweeps that run on this host's files rather than through an RPC.
LOCAL_SWEEPS: Dict[str, Callable[[Mapping[str, str]], object]] = {"draft_preview_expire": _draft_preview_expire}
MAX_LOOP = 20


# Settings whose presence the sweeps worker reports for the masked configuration
# health view (#248). Only names appear here; the report sends booleans.
# The provider health view (sdi_admin_provider_health) groups these names per
# integration; keep them in step with sdi_private.provider_settings().
REPORTED_SETTINGS = ("SDI_BACKEND_URL", "SDI_SERVICE_KEY", "SDI_YOUTUBE_CLIENT_FILE", "SDI_YOUTUBE_TOKEN_FILE",
                     "SDI_STRIPE_WEBHOOK_SECRET_FILE", "SDI_MAIL_SENDER_DOMAIN", "SDI_MAIL_CREDENTIALS_FILE",
                     "SDI_APNS_KEY_ID", "SDI_APNS_TEAM_ID", "SDI_APNS_KEY_FILE", "SDI_APNS_TOPIC",
                     "SDI_FCM_PROJECT_ID", "SDI_FCM_SERVICE_ACCOUNT_FILE", "SDI_DRAFT_RENDERER_CLI")


class SweepAPI(JobAPI):
    PREFIX = "sdi_"
    PERMITTED = frozenset(SWEEPS.values()) | {"worker_heartbeat", "worker_configuration", "ops_report"}


def configuration_presence(environment: Mapping[str, str], names: Iterable[str] = REPORTED_SETTINGS) -> Dict[str, bool]:
    """Presence booleans keyed by the lower-cased setting name; never the values."""
    return {name.lower(): bool(environment.get(name)) for name in names}


def report_configuration(api: SweepAPI, environment: Mapping[str, str], worker_name: str = "service-sweeps") -> dict:
    try:
        accepted = api.call("worker_configuration", worker=worker_name, settings=configuration_presence(environment))
        return {"state": "ok" if accepted is True else "refused"}
    except Exception as error:
        return {"state": "failed", "error": type(error).__name__}


def run_sweeps(api: SweepAPI, names: Iterable[str], worker_name: str = "service-sweeps",
               heartbeat: bool = True, environment: Optional[Mapping[str, str]] = None) -> dict:
    report: Dict[str, dict] = {}
    for name in names:
        if name in LOCAL_SWEEPS:
            try:
                result = LOCAL_SWEEPS[name](os.environ if environment is None else environment)
                report[name] = ({"state": "skipped", "reason": "not configured"} if result is None
                                else {"state": "ok", "iterations": 1, "result": _summarize(result)})
            except Exception as error:
                report[name] = {"state": "failed", "iterations": 0, "error": type(error).__name__}
            continue
        if name not in SWEEPS:
            report[name] = {"state": "skipped", "reason": "unknown sweep"}
            continue
        operation = SWEEPS[name]
        iterations = 0
        try:
            while True:
                result = api.call(operation)
                iterations += 1
                stop_key = LOOPING.get(name)
                if not stop_key or not isinstance(result, Mapping) or result.get(stop_key[0]) in stop_key[1] or iterations >= MAX_LOOP:
                    break
            report[name] = {"state": "ok", "iterations": iterations, "result": _summarize(result)}
        except Exception as error:  # the RPC client raises RuntimeError without detail
            report[name] = {"state": "failed", "iterations": iterations, "error": type(error).__name__}
    if heartbeat:
        failed = sorted(k for k, v in report.items() if v["state"] == "failed")
        note = "ok" if not failed else "failed: " + ",".join(failed)
        try:
            api.call("worker_heartbeat", worker=worker_name, note=note[:200])
            report["_heartbeat"] = {"state": "ok"}
        except Exception as error:
            report["_heartbeat"] = {"state": "failed", "error": type(error).__name__}
    return report


def report_outcome(api: SweepAPI, report: Mapping[str, dict]) -> dict:
    """Record the run through ``sdi_ops_report`` as a retention sweep (#257).

    Only whole-number counts are sent: how many sweeps ran and how many failed.
    Unknown (skipped) names are not counted. A refused or failed report is
    returned for printing and never changes the run's exit status.
    """
    ran = [v for k, v in report.items() if not k.startswith("_") and v.get("state") in ("ok", "failed")]
    if not ran:
        return {"state": "skipped", "reason": "no sweep ran"}
    failed = sum(1 for v in ran if v["state"] == "failed")
    return send_report(api, "retention_sweep", "failed" if failed else "succeeded", "",
                       {"sweeps_run": len(ran), "sweeps_failed": failed})


def _summarize(result) -> object:
    """Keep counts and small scalars; drop lists and nested member data."""
    if isinstance(result, Mapping):
        return {k: v for k, v in result.items() if isinstance(v, (int, float, bool, str))}
    if isinstance(result, (int, float, bool, str)):
        return result
    return None


def main(argv: Optional[list] = None, environment: Optional[Mapping[str, str]] = None, api_factory: Optional[Callable[[], SweepAPI]] = None) -> int:
    parser = argparse.ArgumentParser(description="Run bounded service sweeps against the configured backend.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--all", action="store_true")
    group.add_argument("--only", help="comma-separated sweep names")
    parser.add_argument("--list", action="store_true", help="print the known sweeps and exit")
    args = parser.parse_args(argv)
    if args.list:
        print("\n".join(sorted(set(SWEEPS) | set(LOCAL_SWEEPS))))
        return 0
    names = sorted(set(SWEEPS) | set(LOCAL_SWEEPS)) if args.all else [n.strip() for n in args.only.split(",") if n.strip()]
    environment = os.environ if environment is None else environment
    try:
        api = api_factory() if api_factory else SweepAPI(environment["SDI_BACKEND_URL"], environment["SDI_SERVICE_KEY"])
    except (KeyError, ValueError):
        print("Backend URL and service key are not configured; no sweep ran.", file=sys.stderr)
        return 2
    report = run_sweeps(api, names, environment=environment)
    # Informational: a refused or failed presence report is printed, never fatal.
    report["_configuration"] = report_configuration(api, environment)
    report["_ops_report"] = report_outcome(api, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if all(v["state"] != "failed" for k, v in report.items() if k not in ("_configuration", "_ops_report")) else 1


if __name__ == "__main__":
    raise SystemExit(main())
