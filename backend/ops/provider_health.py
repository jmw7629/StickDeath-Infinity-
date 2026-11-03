"""Provider outcome reports for the masked provider health view (#248).

A service worker that just talked to an external provider records one outcome
through ``sdi_provider_outcome``: success, or failure with a class from a closed
vocabulary. Nothing else is sent: no exception message, status text, address,
token or identifier, so the command centre can show "last success / last failure
/ error class" without any secret or member data reaching the database.

Outcomes that the database already records durably (Stripe events, push
deliveries, YouTube publish jobs, Spatter draft jobs) are read there directly;
this report is for integrations without such a record, such as the email sender.
"""
from __future__ import annotations

import smtplib
import socket
from typing import Optional

from ..publishing.worker import JobAPI

PROVIDERS = frozenset({"spatter", "apns", "fcm", "email", "stripe", "youtube"})
# Must match sdi_private.provider_error_classes() in backend/sql/worker-configuration.sql.
ERROR_CLASSES = frozenset({"configuration", "authentication", "rate_limited", "network", "timeout", "rejected",
                           "provider_error", "invalid_response", "event_error", "job_failed", "render_failed", "other"})


class ProviderOutcomeAPI(JobAPI):
    PREFIX = "sdi_"
    PERMITTED = frozenset({"provider_outcome"})


def classify_exception(error: BaseException) -> str:
    """Map an exception to a closed error class by type only, never by message."""
    if isinstance(error, smtplib.SMTPAuthenticationError):
        return "authentication"
    if isinstance(error, (socket.timeout, TimeoutError)):
        return "timeout"
    if isinstance(error, (smtplib.SMTPServerDisconnected, smtplib.SMTPConnectError, ConnectionError)):
        return "network"
    if isinstance(error, smtplib.SMTPResponseException):
        return "provider_error" if 400 <= error.smtp_code < 500 else "rejected"
    if isinstance(error, smtplib.SMTPException):
        return "provider_error"
    if isinstance(error, OSError):
        return "network"
    if isinstance(error, ValueError):
        return "configuration"
    return "other"


def report_outcome(api, provider: str, succeeded: bool, error_class: Optional[str] = None) -> dict:
    """Send one outcome. Returns a small status; never raises (reporting is informational)."""
    if provider not in PROVIDERS:
        return {"state": "skipped", "reason": "unknown provider"}
    if succeeded:
        error_class = None
    elif error_class not in ERROR_CLASSES:
        error_class = "other"
    try:
        accepted = api.call("provider_outcome", provider=provider, succeeded=bool(succeeded), error_class=error_class)
        return {"state": "ok" if accepted is True else "refused"}
    except Exception as error:
        return {"state": "failed", "error": type(error).__name__}
