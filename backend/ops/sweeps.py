"""Bounded service sweeps over the SQL candidates' service-role functions.

The README of ``backend/sql`` notes that nothing schedules the sweeps. This module
is the single, auditable place a host cron or systemd timer calls:

    python3 -m backend.ops.sweeps --all          # or --only billing_reconcile,...

Each sweep is one named RPC. The runner never deletes files, never retries a sweep
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

SWEEPS: Dict[str, str] = {
    "billing_reconcile": "billing_reconcile",
    "support_retention": "support_retention",
    "war_expire_proposals": "war_expire_proposals",
    "war_finalize": "war_finalize",
    "challenge_finalize": "challenge_finalize",
    "award_achievements": "award_achievements",
    "account_deletion_run": "account_deletion_run",
    "marketing_cadence_due": "marketing_cadence_due",
}
LOOPING = {"account_deletion_run": ("action", {"idle", "waiting", "blocked"})}
MAX_LOOP = 20


# Settings whose presence the sweeps worker reports for the masked configuration
# health view (#248). Only names appear here; the report sends booleans.
REPORTED_SETTINGS = ("SDI_BACKEND_URL", "SDI_SERVICE_KEY", "SDI_YOUTUBE_CLIENT_FILE", "SDI_YOUTUBE_TOKEN_FILE",
                     "SDI_STRIPE_WEBHOOK_SECRET_FILE", "SDI_MAIL_SENDER_DOMAIN", "SDI_MAIL_CREDENTIALS_FILE")


class SweepAPI(JobAPI):
    PREFIX = "sdi_"
    PERMITTED = frozenset(SWEEPS.values()) | {"worker_heartbeat", "worker_configuration"}


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
               heartbeat: bool = True) -> dict:
    report: Dict[str, dict] = {}
    for name in names:
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
        print("\n".join(sorted(SWEEPS)))
        return 0
    names = sorted(SWEEPS) if args.all else [n.strip() for n in args.only.split(",") if n.strip()]
    environment = os.environ if environment is None else environment
    try:
        api = api_factory() if api_factory else SweepAPI(environment["SDI_BACKEND_URL"], environment["SDI_SERVICE_KEY"])
    except (KeyError, ValueError):
        print("Backend URL and service key are not configured; no sweep ran.", file=sys.stderr)
        return 2
    report = run_sweeps(api, names)
    # Informational: a refused or failed presence report is printed, never fatal.
    report["_configuration"] = report_configuration(api, environment)
    print(json.dumps(report, sort_keys=True))
    return 0 if all(v["state"] != "failed" for k, v in report.items() if k != "_configuration") else 1


if __name__ == "__main__":
    raise SystemExit(main())
