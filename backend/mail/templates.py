"""Plain-text email templates with strict placeholders and category footers.

Categories follow ``notifications.sql``: ``transactional`` notices are account and
service facts and carry no marketing; ``product`` and ``marketing`` require the
member's separate opt-in and always carry a working one-click unsubscribe link.
Templates are plain text only (no HTML, no tracking pixels, no remote images).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import string
from dataclasses import dataclass
from typing import Dict, Mapping, Optional, Set, Tuple

CATEGORIES = ("transactional", "product", "marketing")
SENDER_NAME = "StickDeath Infinity"


@dataclass(frozen=True)
class Template:
    key: str
    category: str
    subject: str
    body: str

    def placeholders(self) -> Set[str]:
        names: Set[str] = set()
        for text in (self.subject, self.body):
            for _, field_name, _, _ in string.Formatter().parse(text):
                if field_name:
                    names.add(field_name)
        return names


TEMPLATES: Dict[str, Template] = {t.key: t for t in (
    Template("support_receipt", "transactional", "Support request {receipt} received",
             "We received your support request {receipt} ({category}).\n\nWe reply to this address. You can withdraw the request from Settings → Support in the app at any time."),
    Template("account_deletion_scheduled", "transactional", "Account deletion scheduled",
             "Your account deletion is scheduled for {scheduled_for} UTC.\n\nSign in and cancel before then to keep the account. Projects on your device are not affected. Subscriptions must be cancelled with the store or billing portal."),
    Template("account_deletion_completed", "transactional", "Account deleted",
             "Your StickDeath Infinity account and its server records were deleted on {completed_on} UTC. Projects stored on your device remain yours."),
    Template("subscription_payment_failed", "transactional", "Payment for your plan did not go through",
             "The last payment for your {plan} plan failed. Your access continues until {paid_through} UTC while the provider retries. Update the payment method with {provider} to keep the plan."),
    Template("export_ready", "transactional", "Your data export",
             "Your requested export of server records was produced on {produced_on} UTC and is available in the app under Settings → Account for 24 hours. Projects on your device are not included because they are not stored on our servers."),
    Template("product_update", "product", "{headline}",
             "{body}"),
    Template("marketing_campaign", "marketing", "{headline}",
             "{body}"),
)}

TRANSACTIONAL_FOOTER = "\n\n--\nThis is a service notice about your StickDeath Infinity account. It is not marketing and cannot be unsubscribed; it stops when the account closes."
OPT_IN_FOOTER = "\n\n--\nYou receive this because you turned on {kind} email in StickDeath Infinity. One-click unsubscribe: {unsubscribe_url}"


@dataclass(frozen=True)
class Rendered:
    key: str
    category: str
    subject: str
    text: str


def render(key: str, context: Mapping[str, str], unsubscribe_url: Optional[str] = None) -> Rendered:
    template = TEMPLATES.get(key)
    if template is None:
        raise KeyError("unknown template %s" % key)
    expected = template.placeholders()
    provided = set(context)
    if expected != provided:
        raise ValueError("template %s needs exactly %s, got %s" % (key, sorted(expected), sorted(provided)))
    for name, value in context.items():
        if not isinstance(value, str) or not value.strip() or len(value) > 4000 or "<" in value or ">" in value:
            raise ValueError("placeholder %s must be non-empty plain text without angle brackets" % name)
    subject = template.subject.format(**context).replace("\n", " ").strip()
    text = template.body.format(**context)
    if template.category == "transactional":
        text += TRANSACTIONAL_FOOTER
    else:
        if not unsubscribe_url or not unsubscribe_url.startswith("https://"):
            raise ValueError("%s email requires an https unsubscribe url" % template.category)
        text += OPT_IN_FOOTER.format(kind=template.category, unsubscribe_url=unsubscribe_url)
    if len(subject) > 200:
        raise ValueError("subject too long")
    return Rendered(key, template.category, subject, text)


def preview(key: str, context: Mapping[str, str], unsubscribe_url: Optional[str] = None) -> str:
    """Operator preview: the exact text a member would receive, nothing sent."""
    rendered = render(key, context, unsubscribe_url)
    return "Subject: %s\nCategory: %s\n\n%s" % (rendered.subject, rendered.category, rendered.text)


def email_hash(address: str) -> str:
    return hashlib.sha256(address.strip().lower().encode("utf-8")).hexdigest()


def unsubscribe_token(secret: bytes, address_hash: str, category: str) -> str:
    """URL-safe token binding the address hash and category; verified server-side."""
    if len(secret) < 32 or category not in ("product", "marketing") or len(address_hash) != 64:
        raise ValueError("secret, category and address hash required")
    payload = ("%s:%s" % (address_hash, category)).encode("ascii")
    mac = hmac.new(secret, payload, hashlib.sha256).digest()[:20]
    return base64.urlsafe_b64encode(payload + b"|" + mac).rstrip(b"=").decode("ascii")


def verify_unsubscribe_token(secret: bytes, token: str) -> Optional[Tuple[str, str]]:
    try:
        raw = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))
        payload, mac = raw.rsplit(b"|", 1)
        address_hash, category = payload.decode("ascii").split(":")
    except (ValueError, UnicodeDecodeError):
        return None
    if category not in ("product", "marketing") or len(address_hash) != 64:
        return None
    expected = hmac.new(secret, payload, hashlib.sha256).digest()[:20]
    if not hmac.compare_digest(expected, mac):
        return None
    return address_hash, category
