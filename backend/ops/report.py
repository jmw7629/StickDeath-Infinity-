"""Report one operations outcome through ``sdi_ops_report`` (#257).

Host jobs (backups, restore drills, releases, rollbacks, retention sweeps) call
this after they finish so the command centre's operations panel
(``sdi_admin_operations``) shows real, dated outcomes instead of "stale":

    python3 -m backend.ops.report backup succeeded --metric bytes=123456 --metric duration_seconds=42
    python3 -m backend.ops.report release succeeded --label 1.4.0

``SDI_BACKEND_URL`` and ``SDI_SERVICE_KEY`` come from the host secret store. When
either is missing the report is skipped with a clear message and exit status 3;
nothing is sent and no value is printed. The database accepts only a known kind,
``succeeded``/``failed``, a version-or-commit label and named whole-number
metrics, so no host name, path, bucket or credential can be recorded.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Callable, Dict, Mapping, Optional

from ..publishing.worker import JobAPI

KINDS = ("backup", "restore_drill", "release", "rollback", "retention_sweep")
OUTCOMES = ("succeeded", "failed")
_METRIC = re.compile(r"^([a-z_]{1,40})=([0-9]{1,15})$")
NOT_CONFIGURED = 3


class OpsReportAPI(JobAPI):
    PREFIX = "sdi_"
    PERMITTED = frozenset({"ops_report"})


def parse_metrics(items) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    for item in items or ():
        match = _METRIC.match(item)
        if not match:
            raise ValueError("Metrics are name=whole-number pairs with lower-case names.")
        metrics[match.group(1)] = int(match.group(2))
    if len(metrics) > 20:
        raise ValueError("At most 20 metrics.")
    return metrics


def send_report(api, kind: str, outcome: str, label: str = "", metrics: Optional[Mapping[str, int]] = None) -> dict:
    """Return {"state": "recorded"|"refused"|"failed", ...}; never raises."""
    try:
        answer = api.call("ops_report", kind=kind, outcome=outcome, label=label, metrics=dict(metrics or {}))
    except Exception as error:   # the RPC client raises RuntimeError without detail
        return {"state": "failed", "error": type(error).__name__}
    if isinstance(answer, Mapping) and answer.get("status") == "recorded":
        return {"state": "recorded"}
    reason = answer.get("error") if isinstance(answer, Mapping) else None
    return {"state": "refused", "reason": str(reason)[:120] if reason else "unexpected answer"}


def api_from_environment(environment: Mapping[str, str]) -> Optional[OpsReportAPI]:
    url, key = environment.get("SDI_BACKEND_URL"), environment.get("SDI_SERVICE_KEY")
    if not url or not key:
        return None
    return OpsReportAPI(url, key)


def main(argv: Optional[list] = None, environment: Optional[Mapping[str, str]] = None,
         api_factory: Optional[Callable[[], object]] = None) -> int:
    parser = argparse.ArgumentParser(description="Report one operations outcome to the command centre.")
    parser.add_argument("kind", choices=KINDS)
    parser.add_argument("outcome", choices=OUTCOMES)
    parser.add_argument("--label", default="", help="version number or commit hash only")
    parser.add_argument("--metric", action="append", default=[], help="name=whole-number (repeatable)")
    args = parser.parse_args(argv)
    try:
        metrics = parse_metrics(args.metric)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    environment = os.environ if environment is None else environment
    try:
        api = api_factory() if api_factory else api_from_environment(environment)
    except ValueError:
        api = None
    if api is None:
        print("Operations reporting is not configured (SDI_BACKEND_URL / SDI_SERVICE_KEY); report skipped.", file=sys.stderr)
        return NOT_CONFIGURED
    result = send_report(api, args.kind, args.outcome, args.label, metrics)
    print("ops report %s %s: %s" % (args.kind, args.outcome, result["state"]))
    return 0 if result["state"] == "recorded" else 1


if __name__ == "__main__":
    raise SystemExit(main())
