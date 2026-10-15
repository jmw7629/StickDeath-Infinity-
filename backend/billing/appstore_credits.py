"""``appstore-credits`` edge-function candidate: redeem an Apple Spatter credit pack.

Apple does not send an App Store Server Notification when a consumable is
bought, so the app posts the StoreKit 2 signed transaction (``jwsRepresentation``)
here right after ``Transaction.verified`` and before ``finish()``:

    POST  Authorization: Bearer <member access token>
    body  {"signedTransaction": "<compact JWS>"}

The handler verifies the member JWT (injected ``verify_jwt``, same contract as
``stripe_checkout``), checks the account is active, then verifies the JWS with
the same pinned-root chain verifier as ``appstore_notifications`` and requires:
the configured bundle id and environment, ``type == "Consumable"``, an approved
credit pack product id, no ``revocationDate``, and ``appAccountToken`` equal to
the signed-in member (the app sets it to the account id at purchase), so one
member cannot redeem another's transaction. It then calls the service-only
``public.sdi_spatter_credits_grant`` once; the database grants each
``transactionId`` at most once and never re-grants a refunded one. Sandbox
transactions are granted with ``livemode = false`` and never write revenue
rows. Apple ``REFUND`` notifications for credit packs are handled by
``appstore_notifications`` (claw back). Nothing here contacts Apple.
"""
from __future__ import annotations

import datetime as _dt
from typing import Any, Callable, Mapping, Optional

from .appstore_notifications import AppStoreConfig, ChainVerifier, verify_jws
from .contract import ContractError, CreditPackCatalog, Response, SQLExecutor, as_uuid, grant_credits, parse_json_object
from .stripe_checkout import _bearer, _member

MAX_BODY_BYTES = 64 * 1024
CONSUMABLE_TYPE = "Consumable"


def handle(headers: Mapping[str, str], raw_body: bytes, *, verify_jwt: Callable[[str], Mapping[str, Any]],
           account_active: Callable[[str], bool], executor: SQLExecutor, packs: CreditPackCatalog,
           config: AppStoreConfig, verifier: Optional[ChainVerifier] = None,
           now: Callable[[], _dt.datetime] = lambda: _dt.datetime.now(_dt.timezone.utc)) -> Response:
    try:
        token = _bearer(headers)
        try:
            claims = verify_jwt(token)
        except ContractError:
            raise
        except Exception:
            raise ContractError(401, "unauthorized") from None
        user_id = _member(claims, now())
        if account_active(user_id) is not True:
            raise ContractError(403, "account is not active")
        body = parse_json_object(raw_body, MAX_BODY_BYTES)
        tx = verify_jws(body.get("signedTransaction"), config, verifier)
        if tx.get("bundleId") != config.bundle_id or tx.get("environment", config.environment) != config.environment:
            raise ContractError(400, "transaction is for another app or environment")
        if tx.get("type") != CONSUMABLE_TYPE:
            raise ContractError(400, "not a credit pack purchase")
        pack = packs.get("apple", tx.get("productId"))
        if pack is None:
            raise ContractError(400, "unknown or unapproved credit pack")
        if tx.get("revocationDate") is not None:
            raise ContractError(409, "transaction was refunded or revoked")
        if as_uuid(tx.get("appAccountToken")) != user_id:
            raise ContractError(403, "transaction belongs to another account")
        transaction_id = tx.get("transactionId")
        if not isinstance(transaction_id, str) or not transaction_id or len(transaction_id) > 200:
            raise ContractError(400, "transaction lacks an id")
        result = grant_credits(executor, user_id, "apple", pack.product_id, transaction_id,
                               livemode=config.environment == "Production")
        if result["status"] == "refused":
            raise ContractError(409, "credit pack not granted")
        return Response(200, {"status": result["status"], "credits": result.get("credits"),
                              "credits_added": result.get("credits_added", 0)})
    except ContractError as error:
        return Response(error.status, {"error": error.reason})
