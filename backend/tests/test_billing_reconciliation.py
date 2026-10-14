"""Offline tests for backend/billing/reconciliation.py (#254). Sample statements are
synthetic fixtures written here; no provider is contacted and no amount is money.

    python3 -m unittest backend.tests.test_billing_reconciliation
"""
import datetime as dt
import json
import unittest

from backend.billing import reconciliation as rec

START = dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc)
END = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)
HEADER = ("balance_transaction_id,created_utc,currency,gross,fee,net,reporting_category,source_id,invoice_id,"
          "customer_email,customer_name,description\n")


def statement(*rows: str) -> str:
    return HEADER + "".join(row + "\n" for row in rows)


SAMPLE = statement(
    "txn_c1,2026-10-02 10:00:00,usd,4.99,0.44,4.55,charge,ch_1,in_1,member@example.invalid,Sample Member,Subscription",
    "txn_c2,2026-10-03 10:00:00,usd,9.99,0.59,9.40,charge,ch_2,in_2,other@example.invalid,Other Member,Subscription",
    "txn_r1,2026-10-04 10:00:00,usd,-4.99,0.00,-4.99,refund,re_1,,member@example.invalid,Sample Member,Refund",
    "txn_p1,2026-10-05 10:00:00,usd,-9.40,0.00,-9.40,payout,po_1,,,,Payout",
    "txn_t1,2026-10-05 11:00:00,usd,-0.30,0.00,-0.30,tax,txr_1,,,,Tax",
)

LEDGER = [
    {"provider": "stripe", "provider_ref": "in_1", "kind": "charge", "amount_minor": 499, "currency": "USD", "occurred_at": "2026-10-02T10:00:01Z"},
    {"provider": "stripe", "provider_ref": "in_2", "kind": "charge", "amount_minor": 999, "currency": "USD", "occurred_at": "2026-10-03T10:00:01Z"},
    {"provider": "stripe", "provider_ref": "re_1", "kind": "refund", "amount_minor": -499, "currency": "USD", "occurred_at": "2026-10-04T10:00:01Z"},
    {"provider": "stripe", "provider_ref": "po_1", "kind": "payout", "amount_minor": 940, "currency": "USD", "occurred_at": "2026-10-05T10:00:01Z"},
    {"provider": "manual", "provider_ref": "host-2026-10", "kind": "expense", "amount_minor": -2500, "currency": "USD", "occurred_at": "2026-10-06T00:00:00Z"},
]


def kinds(report):
    return sorted(item["kind"] for item in report["discrepancies"])


class ParseTests(unittest.TestCase):
    def test_amounts_are_exact_minor_units_per_currency(self):
        self.assertEqual(rec.to_minor("4.99", "USD"), 499)
        self.assertEqual(rec.to_minor("-0.30", "usd"), -30)
        self.assertEqual(rec.to_minor("500", "JPY"), 500)
        self.assertEqual(rec.to_minor("1.234", "KWD"), 1234)
        self.assertIsNone(rec.to_minor("4.999", "USD"), "more precision than the currency is refused, never rounded")
        self.assertIsNone(rec.to_minor("1.5", "JPY"))
        self.assertIsNone(rec.to_minor("NaN", "USD"))
        self.assertIsNone(rec.to_minor("", "USD"))

    def test_missing_columns_refuse_the_statement(self):
        with self.assertRaises(rec.StatementError):
            rec.parse_stripe_itemized_csv("id,amount\nx,1\n")

    def test_bad_rows_are_rejected_by_number_without_content(self):
        lines, rejected = rec.parse_stripe_itemized_csv(statement(
            "txn_a,2026-10-02 10:00:00,usd,4.999,0,0,charge,ch_a,in_a,secret@example.invalid,,",
            "txn_b,not-a-date,usd,1.00,0,0,charge,ch_b,in_b,,,",
            "txn_c,2026-10-02 10:00:00,us,1.00,0,0,charge,ch_c,in_c,,,",
            "txn_d,2026-10-02 10:00:00,usd,1.00,0,0,charge,ch_d,in_d,,,"))
        self.assertEqual([line.balance_transaction_id for line in lines], ["txn_d"])
        self.assertEqual([item["reason"] for item in rejected], ["amount", "created_utc", "currency"])
        self.assertNotIn("secret@example.invalid", json.dumps(rejected))


class ReconcileTests(unittest.TestCase):
    def reconcile(self, text=SAMPLE, ledger=LEDGER, livemode=True):
        lines, rejected = rec.parse_stripe_itemized_csv(text)
        return rec.reconcile_stripe_statement(lines, ledger, period_start=START, period_end=END, livemode=livemode, rejected=rejected)

    def test_clean_statement_matches_by_provider_ids(self):
        report = self.reconcile()
        self.assertEqual(report["matched"], 4)
        self.assertEqual(kinds(report), ["tax_not_in_ledger"])
        usd = report["totals"][0]
        self.assertEqual((usd["currency"], usd["gross_charges_minor"], usd["refunds_minor"], usd["provider_fees_minor"],
                          usd["payouts_minor"], usd["tax_minor"]), ("USD", 1498, -499, -103, 940, -30))
        self.assertIn("Not an available balance", report["label"])

    def test_fees_become_idempotent_import_rows_until_recorded(self):
        report = self.reconcile()
        refs = [row["ref"] for row in report["fee_import_rows"]]
        self.assertEqual(refs, ["stripe-fee:txn_c1", "stripe-fee:txn_c2"])
        self.assertTrue(all(row["kind"] == "fee" and row["amount_minor"] < 0 for row in report["fee_import_rows"]))
        recorded = LEDGER + [{"provider": "manual", "provider_ref": "stripe-fee:txn_c1", "kind": "fee", "amount_minor": -44,
                              "currency": "USD", "occurred_at": "2026-10-02T10:00:00Z"}]
        self.assertEqual([row["ref"] for row in self.reconcile(ledger=recorded)["fee_import_rows"]], ["stripe-fee:txn_c2"])

    def test_sample_discrepancies_are_named(self):
        ledger = [dict(row) for row in LEDGER]
        ledger[1]["amount_minor"] = 899          # webhook recorded a different amount
        del ledger[2]                             # refund never reached the ledger
        ledger.append({"provider": "stripe", "provider_ref": "in_ghost", "kind": "charge", "amount_minor": 499,
                       "currency": "USD", "occurred_at": "2026-10-09T00:00:00Z"})
        ledger.append({"provider": "stripe", "provider_ref": "po_eur", "kind": "payout", "amount_minor": 100,
                       "currency": "EUR", "occurred_at": "2026-10-09T00:00:00Z"})
        text = SAMPLE + "".join(row + "\n" for row in (
            "txn_c1,2026-10-02 10:00:00,usd,4.99,0.44,4.55,charge,ch_1,in_1,,,",          # duplicate line
            "txn_old,2026-09-20 10:00:00,usd,4.99,0.44,4.55,charge,ch_9,in_9,,,",       # outside the period
            "txn_po_eur,2026-10-09 00:00:00,usd,-1.00,0,-1.00,payout,po_eur,,,,",        # currency differs
            "txn_x,2026-10-09 00:00:00,usd,-2.00,0,-2.00,climate_order,co_1,,,,",         # unknown category
            "txn_bad,2026-10-09 00:00:00,usd,abc,0,0,charge,ch_bad,in_bad,,,"))
        report = self.reconcile(text=text, ledger=ledger)
        self.assertEqual(kinds(report), sorted([
            "amount_mismatch", "missing_in_ledger", "missing_in_statement", "duplicate_statement_line", "outside_period",
            "currency_mismatch", "unclassified_category", "statement_row_rejected", "tax_not_in_ledger"]))
        mismatch = next(d for d in report["discrepancies"] if d["kind"] == "amount_mismatch")
        self.assertEqual((mismatch["ref"], mismatch["ledger_minor"], mismatch["statement_minor"]), ("in_2", 899, 999))
        self.assertEqual(next(d for d in report["discrepancies"] if d["kind"] == "missing_in_ledger")["ref"], "re_1")
        self.assertEqual(next(d for d in report["discrepancies"] if d["kind"] == "missing_in_statement")["ref"], "in_ghost")
        self.assertEqual(report["discrepancy_count"], len(report["discrepancies"]))

    def test_customer_information_never_reaches_the_report(self):
        text = json.dumps(self.reconcile())
        for value in ("member@example.invalid", "other@example.invalid", "Sample Member", "Other Member"):
            self.assertNotIn(value, text)

    def test_test_mode_statement_is_labelled_and_never_imported_or_compared(self):
        report = self.reconcile(ledger=[], livemode=False)
        self.assertFalse(report["livemode"])
        self.assertIn("not money", report["label"])
        self.assertEqual(report["fee_import_rows"], [])
        self.assertNotIn("missing_in_ledger", kinds(report))
        self.assertNotIn("available balance", report["label"].replace("Not an available balance", ""))

    def test_period_must_be_valid(self):
        with self.assertRaises(rec.StatementError):
            rec.reconcile_stripe_statement([], [], period_start=END, period_end=START, livemode=True)
        with self.assertRaises(rec.StatementError):
            rec.reconcile_stripe_statement([], [], period_start=START.replace(tzinfo=None), period_end=END, livemode=True)

    def test_import_batches_fit_the_import_limit(self):
        rows = [{"ref": "stripe-fee:%d" % i} for i in range(1001)]
        self.assertEqual([len(batch) for batch in rec.import_batches(rows)], [500, 500, 1])
        with self.assertRaises(ValueError):
            rec.import_batches(rows, size=501)


if __name__ == "__main__":
    unittest.main()
