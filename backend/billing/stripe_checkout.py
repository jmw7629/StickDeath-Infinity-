"""``stripe-checkout`` edge-function candidate.

Pure handler: authenticates the member (injected ``verify_jwt`` with the same
contract as ``backend/spatter/handler.py``), checks the account is active through
the injected ``account_active`` callback, validates the product and return URL,
and returns the **request** the deployment must send to Stripe with its secret
key. No HTTP call is made here. The two approved monthly products are the only
accepted offers; annual and unknown ids are refused. No amount appears anywhere:
line items reference the configured ``price_...`` id from the Stripe dashboard.

The hosted URL returned by Stripe is the only thing the client may receive
(``client_response``). A success redirect is not proof of payment; entitlement
appears only after ``stripe_webhook`` applies the signed events.
"""
from __future__ import annotations

import datetime as _dt
import re
import uuid
from dataclasses import dataclass
from typing import Any, Callable, Dict, Mapping, Optional
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from .contract import ApprovedProduct, ContractError, ProductCatalog, Response, header, parse_json_object

MAX_BODY_BYTES = 8 * 1024
MAX_URL_LENGTH = 2048
CHECKOUT_PATH = "/v1/checkout/sessions"
PORTAL_PATH = "/v1/billing_portal/sessions"
_HOST_RE = re.compile(r"^[a-z0-9.-]{1,253}$")


@dataclass(frozen=True)
class CheckoutConfig:
    website_origin: str          # e.g. "https://www.example.com"; return URLs must be on it
    livemode: bool = False       # test mode until the owner separately authorizes live activation

    def __post_init__(self):
        parts = urlsplit(self.website_origin)
        if parts.scheme != "https" or not parts.netloc or parts.path not in ("", "/") or parts.query or parts.fragment or "@" in parts.netloc:
            raise ValueError("website_origin must be an https origin without path, query or credentials")

    @property
    def host(self) -> str:
        return urlsplit(self.website_origin).netloc.lower()


@dataclass
class StripeRequest:
    """One form-encoded POST the deployment makes to Stripe with the secret key."""
    path: str
    form: Dict[str, str]
    idempotency_key: str

    def as_json(self) -> dict:
        return {"path": self.path, "form": dict(self.form), "idempotency_key": self.idempotency_key}


def _bearer(headers: Mapping[str, str]) -> str:
    value = header(headers, "authorization")
    if not value.startswith("Bearer "):
        raise ContractError(401, "missing bearer token")
    token = value[len("Bearer "):].strip()
    if not token or len(token.encode()) > 16_384 or not all(32 < ord(c) < 127 for c in token):
        raise ContractError(401, "invalid bearer token")
    return token


def _member(claims: Mapping[str, Any], now: _dt.datetime) -> str:
    sub = claims.get("sub")
    if not isinstance(sub, str) or claims.get("aud") not in ("authenticated", ["authenticated"]):
        raise ContractError(401, "unauthorized")
    try:
        user = str(uuid.UUID(sub))
    except ValueError:
        raise ContractError(401, "unauthorized") from None
    if claims.get("role") not in (None, "authenticated"):
        raise ContractError(403, "forbidden role")
    if claims.get("is_anonymous") is True:
        raise ContractError(403, "sign in with an account to subscribe")
    exp = claims.get("exp")
    if not isinstance(exp, (int, float)) or exp <= now.timestamp():
        raise ContractError(401, "token expired")
    return user


def validate_return_url(value: Any, config: CheckoutConfig) -> str:
    if not isinstance(value, str) or not value or len(value) > MAX_URL_LENGTH or any(ord(c) < 33 or ord(c) > 126 for c in value):
        raise ContractError(400, "invalid return url")
    parts = urlsplit(value)
    host = parts.netloc.lower()
    if parts.scheme != "https" or host != config.host or not _HOST_RE.match(host) or parts.fragment or "@" in parts.netloc:
        raise ContractError(400, "return url must be on the website origin")
    return value


def _with_query(url: str, extra: Mapping[str, str]) -> str:
    parts = urlsplit(url)
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k not in extra]
    query.extend(extra.items())
    # Stripe substitutes {CHECKOUT_SESSION_ID}; keep the braces literal.
    encoded = urlencode(query, safe="{}")
    return urlunsplit((parts.scheme, parts.netloc, parts.path or "/", encoded, ""))


def _idempotency_key(*parts: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "sdi-billing:" + "|".join(parts)))


def checkout_request(user_id: str, product: ApprovedProduct, return_url: str, config: CheckoutConfig, now: _dt.datetime) -> StripeRequest:
    if product.provider != "stripe" or product.period != "monthly" or not product.stripe_price_id:
        raise ContractError(400, "product is not an approved monthly Stripe offer")
    form = {
        "mode": "subscription",
        "line_items[0][price]": product.stripe_price_id,
        "line_items[0][quantity]": "1",
        "client_reference_id": user_id,
        "success_url": _with_query(return_url, {"checkout": "success", "session_id": "{CHECKOUT_SESSION_ID}"}),
        "cancel_url": _with_query(return_url, {"checkout": "cancelled"}),
        "metadata[sdi_user_id]": user_id,
        "metadata[sdi_product_id]": product.product_id,
        "subscription_data[metadata][sdi_user_id]": user_id,
        "subscription_data[metadata][sdi_product_id]": product.product_id,
        "billing_address_collection": "auto",
    }
    assert not any("amount" in key for key in form), "no amount may be embedded"
    minute = now.astimezone(_dt.timezone.utc).strftime("%Y%m%d%H%M")
    return StripeRequest(CHECKOUT_PATH, form, _idempotency_key("checkout", user_id, product.product_id, minute))


def portal_request(customer_id: str, return_url: str, now: _dt.datetime) -> StripeRequest:
    if not isinstance(customer_id, str) or not customer_id.startswith("cus_"):
        raise ContractError(404, "no billing account for this member")
    minute = now.astimezone(_dt.timezone.utc).strftime("%Y%m%d%H%M")
    return StripeRequest(PORTAL_PATH, {"customer": customer_id, "return_url": return_url},
                         _idempotency_key("portal", customer_id, minute))


def client_response(stripe_session: Mapping[str, Any]) -> dict:
    """The only fields a client receives from a created session: the hosted URL."""
    url = stripe_session.get("url")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise ContractError(502, "provider returned no hosted url")
    return {"url": url}


def handle(headers: Mapping[str, str], raw_body: bytes, *, verify_jwt: Callable[[str], Mapping[str, Any]],
           account_active: Callable[[str], bool], catalog: ProductCatalog, config: CheckoutConfig,
           customer_for_user: Optional[Callable[[str], Optional[str]]] = None,
           now: Callable[[], _dt.datetime] = lambda: _dt.datetime.now(_dt.timezone.utc)) -> Response:
    """Body: ``{"action": "checkout", "product_id": "...", "return_url": "https://..."}``
    or ``{"action": "portal", "return_url": "https://..."}``. Returns the Stripe
    request to perform server-side, never a price and never a Stripe secret."""
    try:
        token = _bearer(headers)
        try:
            claims = verify_jwt(token)
        except ContractError:
            raise
        except Exception:
            raise ContractError(401, "unauthorized") from None
        current = now()
        user_id = _member(claims, current)
        if account_active(user_id) is not True:
            raise ContractError(403, "account is not active")
        body = parse_json_object(raw_body, MAX_BODY_BYTES)
        action = body.get("action", "checkout")
        return_url = validate_return_url(body.get("return_url"), config)
        if action == "checkout":
            product_id = body.get("product_id")
            product = catalog.get("stripe", product_id if isinstance(product_id, str) else None)
            if product is None:
                raise ContractError(400, "unknown or unapproved product")
            if product.period != "monthly":
                raise ContractError(400, "annual offers are not available")
            request = checkout_request(user_id, product, return_url, config, current)
        elif action == "portal":
            customer = customer_for_user(user_id) if customer_for_user else None
            request = portal_request(customer, return_url, current)
        else:
            raise ContractError(400, "unsupported action")
        return Response(200, {"stripe_request": request.as_json(), "livemode": config.livemode})
    except ContractError as error:
        return Response(error.status, {"error": error.reason})
