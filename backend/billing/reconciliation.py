"""Provider statement reconciliation for the finance ledger (#254).

Pure functions. Nothing here contacts Stripe, reads a secret or writes the
database. The deployment (or a finance administrator working offline) supplies:

* the provider statement: Stripe's *Balance change from activity — itemized*
  report downloaded as CSV from the dashboard or the Reporting API, with at least
  the columns ``balance_transaction_id, created_utc, currency, gross, fee,
  reporting_category, source_id`` (``invoice_id`` recommended);
* the ledger rows for the same period from ``public.sdi_finance_report('export',
  ...)``, which already requires the finance capability with MFA and carries no
  member identity.

``reconcile_stripe_statement`` matches the two by provider ids and returns a
report of concrete discrepancies, per-currency totals (gross charges, refunds,
provider fees, payouts, tax, adjustments) and suggested fee import rows for the
audited ``sdi_finance_record('import', ...)`` path, because signed webhook events
do not carry Stripe's processing fees.

Rules:

* The ledger itself is written only from signed provider events
  (``sdi_billing_apply_event``, idempotent by provider event id) and the audited
  import/manual path. This module never writes; its import rows are suggestions
  an authorized finance administrator submits, and the ledger's
  ``unique(provider, provider_ref, kind)`` makes resubmission a no-op.
* Customer data is never copied. Only the allowlisted columns are read; e-mail,
  name, description, card and address columns in the CSV are ignored and never
  appear in the report.
* Test-mode statements are labelled as test records, are never compared with the
  live ledger and never produce import rows. No total is an available balance.
"""
from __future__ import annotations

import csv
import datetime as _dt
import io
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from .appstore_notifications import _THREE_DECIMAL, _ZERO_DECIMAL

MAX_STATEMENT_ROWS = 50_000
REQUIRED_COLUMNS = ("balance_transaction_id", "created_utc", "currency", "gross", "fee", "reporting_category", "source_id")
# The only statement columns this module reads. Everything else, including
# customer_email, customer_name, description and card or address fields, is ignored.
READ_COLUMNS = REQUIRED_COLUMNS + ("invoice_id",)

# Stripe reporting_category -> ledger kind. ``None`` means the category is a
# provider record with no ledger kind of its own (reported, never imported).
CATEGORY_KIND: Dict[str, Optional[str]] = {
    "charge": "charge",
    "refund": "refund",
    "payout": "payout",
    "fee": "fee",
    "tax": None,
    "dispute": "adjustment",
    "dispute_reversal": "adjustment",
    "other_adjustment": "adjustment",
    "payout_reversal": "adjustment",
    "refund_failure": "adjustment",
}
# Kinds the webhook writes and that must appear in a matching live statement.
MATCHED_KINDS = ("charge", "refund", "payout")
FEE_REF_PREFIX = "stripe-fee:"
LIVE_LABEL = ("Provider-reported statement lines and ledger records in minor units. Not an available balance, "
              "not a forecast and not recognized revenue; payouts are cash movements.")
TEST_LABEL = ("TEST-MODE statement: these are Stripe test records, not money. They were not compared with the live "
              "ledger and produce no import rows.")


class StatementError(ValueError):
    """A statement that cannot be reconciled at all (wrong columns, too large)."""


def minor_exponent(currency: str) -> int:
    code = currency.upper()
    return 0 if code in _ZERO_DECIMAL else 3 if code in _THREE_DECIMAL else 2


def to_minor(amount: Any, currency: str) -> Optional[int]:
    """Exact conversion of a major-unit decimal string to minor units; ``None``
    when the value is malformed or has more precision than the currency allows."""
    if not isinstance(amount, str) or not amount.strip():
        return None
    try:
        value = Decimal(amount.strip().replace(",", ""))
    except InvalidOperation:
        return None
    if not value.is_finite():
        return None
    scaled = value.scaleb(minor_exponent(currency))
    if scaled != scaled.to_integral_value():
        return None
    minor = int(scaled)
    return minor if abs(minor) < 10 ** 15 else None


@dataclass(frozen=True)
class StatementLine:
    balance_transaction_id: str
    created: _dt.datetime
    currency: str
    gross_minor: int
    fee_minor: int
    category: str
    source_id: str
    invoice_id: Optional[str]

    @property
    def kind(self) -> Optional[str]:
        return CATEGORY_KIND.get(self.category)

    @property
    def ledger_ref(self) -> str:
        """The provider reference the webhook stores for this movement: the
        invoice id for subscription charges (``invoice.paid``), otherwise the
        source object id (``re_...`` refunds, ``po_...`` payouts)."""
        if self.category == "charge" and self.invoice_id:
            return self.invoice_id
        return self.source_id

    @property
    def ledger_amount(self) -> int:
        """Signed like the ledger: money in positive, money out negative, and
        payouts positive because the ledger records them as cash movements."""
        if self.category == "payout":
            return abs(self.gross_minor)
        return self.gross_minor


def _parse_time(value: str) -> Optional[_dt.datetime]:
    text = (value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        when = _dt.datetime.fromisoformat(text)
    except ValueError:
        try:
            when = _dt.datetime.strptime(text, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=_dt.timezone.utc)  # the column is UTC by definition
    return when.astimezone(_dt.timezone.utc)


def parse_stripe_itemized_csv(text: str) -> Tuple[List[StatementLine], List[dict]]:
    """Parse the itemized balance report. Returns ``(lines, rejected)``; each
    rejection names the row number and reason, never the row's content."""
    reader = csv.DictReader(io.StringIO(text))
    header = [name.strip() for name in (reader.fieldnames or [])]
    missing = [name for name in REQUIRED_COLUMNS if name not in header]
    if missing:
        raise StatementError("statement is missing columns: " + ", ".join(missing))
    reader.fieldnames = header
    lines: List[StatementLine] = []
    rejected: List[dict] = []
    for number, row in enumerate(reader, start=2):
        if number - 1 > MAX_STATEMENT_ROWS:
            raise StatementError("statement has more than %d rows; split the period" % MAX_STATEMENT_ROWS)
        row = {key: (row.get(key) or "").strip() for key in READ_COLUMNS}
        currency = row["currency"].upper()
        if len(currency) != 3 or not currency.isalpha():
            rejected.append({"row": number, "reason": "currency"})
            continue
        gross, fee = to_minor(row["gross"], currency), to_minor(row["fee"] or "0", currency)
        created = _parse_time(row["created_utc"])
        if gross is None or fee is None:
            rejected.append({"row": number, "reason": "amount"})
            continue
        if created is None:
            rejected.append({"row": number, "reason": "created_utc"})
            continue
        if not row["balance_transaction_id"] or not row["source_id"] or len(row["source_id"]) > 200:
            rejected.append({"row": number, "reason": "provider id"})
            continue
        lines.append(StatementLine(
            balance_transaction_id=row["balance_transaction_id"][:200], created=created, currency=currency,
            gross_minor=gross, fee_minor=fee, category=row["reporting_category"].lower(), source_id=row["source_id"],
            invoice_id=row["invoice_id"][:200] or None))
    return lines, rejected


@dataclass(frozen=True)
class LedgerRow:
    provider: str
    provider_ref: str
    kind: str
    amount_minor: int
    currency: str
    occurred_at: _dt.datetime

    @classmethod
    def from_export(cls, row: Mapping[str, Any]) -> "LedgerRow":
        when = row.get("occurred_at")
        occurred = when if isinstance(when, _dt.datetime) else _parse_time(str(when or ""))
        if occurred is None:
            raise StatementError("ledger export row without occurred_at")
        return cls(provider=str(row["provider"]), provider_ref=str(row["provider_ref"]), kind=str(row["kind"]),
                   amount_minor=int(row["amount_minor"]), currency=str(row["currency"]), occurred_at=occurred)


def _totals(lines: Sequence[StatementLine]) -> List[dict]:
    by_currency: Dict[str, Dict[str, int]] = {}
    for line in lines:
        bucket = by_currency.setdefault(line.currency, {"gross_charges_minor": 0, "refunds_minor": 0, "provider_fees_minor": 0,
                                                         "payouts_minor": 0, "tax_minor": 0, "adjustments_minor": 0,
                                                         "unclassified_minor": 0, "lines": 0})
        bucket["lines"] += 1
        bucket["provider_fees_minor"] -= line.fee_minor  # Stripe reports fees as positive costs
        if line.category == "charge":
            bucket["gross_charges_minor"] += line.gross_minor
        elif line.category == "refund":
            bucket["refunds_minor"] += line.gross_minor
        elif line.category == "fee":
            bucket["provider_fees_minor"] += line.gross_minor
        elif line.category == "payout":
            bucket["payouts_minor"] += abs(line.gross_minor)
        elif line.category == "tax":
            bucket["tax_minor"] += line.gross_minor
        elif line.kind == "adjustment":
            bucket["adjustments_minor"] += line.gross_minor
        else:
            bucket["unclassified_minor"] += line.gross_minor
    return [dict(currency=code, **values) for code, values in sorted(by_currency.items())]


def reconcile_stripe_statement(lines: Sequence[StatementLine], ledger: Iterable[Mapping[str, Any]], *,
                               period_start: _dt.datetime, period_end: _dt.datetime, livemode: bool,
                               rejected: Sequence[dict] = ()) -> dict:
    """Compare one Stripe statement with the ledger export for the same period."""
    if period_start.tzinfo is None or period_end.tzinfo is None or period_end <= period_start:
        raise StatementError("period must be timezone-aware with end after start")
    discrepancies: List[dict] = [dict(kind="statement_row_rejected", **item) for item in rejected]
    seen: Dict[str, StatementLine] = {}
    in_period: List[StatementLine] = []
    for line in lines:
        if line.balance_transaction_id in seen:
            discrepancies.append({"kind": "duplicate_statement_line", "balance_transaction": line.balance_transaction_id})
            continue
        seen[line.balance_transaction_id] = line
        if not period_start <= line.created < period_end:
            discrepancies.append({"kind": "outside_period", "balance_transaction": line.balance_transaction_id})
            continue
        if line.category not in CATEGORY_KIND:
            discrepancies.append({"kind": "unclassified_category", "balance_transaction": line.balance_transaction_id,
                                  "category": line.category[:60], "amount_minor": line.gross_minor, "currency": line.currency})
        in_period.append(line)

    report = {"provider": "stripe", "livemode": livemode, "period_start": period_start.isoformat(),
              "period_end": period_end.isoformat(), "statement_lines": len(in_period), "totals": _totals(in_period)}
    if not livemode:
        report.update(label=TEST_LABEL, discrepancies=discrepancies, discrepancy_count=len(discrepancies),
                      fee_import_rows=[], matched=0)
        return report

    ledger_rows = [LedgerRow.from_export(row) for row in ledger]
    live = {(row.kind, row.provider_ref): row for row in ledger_rows
            if row.provider == "stripe" and row.kind in MATCHED_KINDS and period_start <= row.occurred_at < period_end}
    recorded_fees = {row.provider_ref for row in ledger_rows if row.kind == "fee" and row.provider_ref.startswith(FEE_REF_PREFIX)}
    matched_keys = set()
    fee_rows: List[dict] = []
    for line in in_period:
        kind = line.kind
        if kind in MATCHED_KINDS:
            key = (kind, line.ledger_ref)
            entry = live.get(key)
            if entry is None:
                discrepancies.append({"kind": "missing_in_ledger", "ledger_kind": kind, "ref": line.ledger_ref,
                                      "balance_transaction": line.balance_transaction_id,
                                      "amount_minor": line.ledger_amount, "currency": line.currency})
            else:
                matched_keys.add(key)
                if entry.currency != line.currency:
                    discrepancies.append({"kind": "currency_mismatch", "ledger_kind": kind, "ref": line.ledger_ref,
                                          "ledger_currency": entry.currency, "statement_currency": line.currency})
                elif entry.amount_minor != line.ledger_amount:
                    discrepancies.append({"kind": "amount_mismatch", "ledger_kind": kind, "ref": line.ledger_ref,
                                          "ledger_minor": entry.amount_minor, "statement_minor": line.ledger_amount,
                                          "currency": line.currency})
        fee = -line.fee_minor if line.fee_minor else (line.gross_minor if line.category == "fee" else 0)
        ref = FEE_REF_PREFIX + line.balance_transaction_id
        if fee and ref not in recorded_fees:
            fee_rows.append({"ref": ref, "kind": "fee", "amount_minor": fee, "currency": line.currency,
                             "occurred_at": line.created.isoformat(),
                             "note": "Stripe %s fee for %s" % (line.category[:30], line.source_id[:60])})
    for key, entry in sorted(live.items()):
        if key not in matched_keys:
            discrepancies.append({"kind": "missing_in_statement", "ledger_kind": entry.kind, "ref": entry.provider_ref,
                                  "amount_minor": entry.amount_minor, "currency": entry.currency})
    tax = sum(1 for line in in_period if line.category == "tax")
    if tax:
        discrepancies.append({"kind": "tax_not_in_ledger", "lines": tax,
                              "note": "Tax lines are reported here only; the ledger has no provider tax feed."})
    report.update(label=LIVE_LABEL, discrepancies=discrepancies, discrepancy_count=len(discrepancies),
                  fee_import_rows=fee_rows, matched=len(matched_keys))
    return report


def import_batches(rows: Sequence[dict], size: int = 500) -> List[List[dict]]:
    """Split fee import rows into batches ``sdi_finance_record('import')`` accepts (1..500)."""
    if not 1 <= size <= 500:
        raise ValueError("batch size must be 1..500")
    return [list(rows[index:index + size]) for index in range(0, len(rows), size)]
