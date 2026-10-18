"""Offline tests for backend/mail: templates, deduplicated queue and SMTP sender
against a local SMTP sink that runs inside the test process on 127.0.0.1. No
message leaves the machine.

    python3 -m unittest discover -s backend/tests -t .
"""
import contextlib
import email
import email.policy
import os
import socketserver
import tempfile
import threading
import unittest
from pathlib import Path

from backend.mail import templates
from backend.mail.queue import BLAST_MIN_INTERVAL_SECONDS, EmailQueue, fetch_recipients
from backend.mail.sender import EmailWorker, SMTPSender

SECRET = b"s" * 32
UNSUB = "https://www.example.test/unsubscribe?token=abc"


class SinkHandler(socketserver.StreamRequestHandler):
    """Minimal SMTP: enough for smtplib to hand over one plain-text message."""

    def handle(self):
        server = self.server
        self.wfile.write(b"220 sink ESMTP\r\n")
        recipients = []
        while True:
            line = self.rfile.readline()
            if not line:
                return
            command = line.decode("utf-8", "replace").strip()
            upper = command.upper()
            if upper.startswith("EHLO") or upper.startswith("HELO"):
                self.wfile.write(b"250-sink\r\n250 8BITMIME\r\n")
            elif upper.startswith("MAIL FROM"):
                self.wfile.write(b"250 OK\r\n")
            elif upper.startswith("RCPT TO"):
                address = command.split(":", 1)[1].strip().strip("<>")
                if address in server.reject:
                    self.wfile.write(b"550 no such user\r\n")
                else:
                    recipients.append(address)
                    self.wfile.write(b"250 OK\r\n")
            elif upper == "DATA":
                self.wfile.write(b"354 go\r\n")
                lines = []
                while True:
                    data = self.rfile.readline()
                    if data in (b".\r\n", b".\n", b""):
                        break
                    lines.append(data[1:] if data.startswith(b"..") else data)
                server.messages.append((list(recipients), b"".join(lines)))
                recipients = []
                self.wfile.write(b"250 queued\r\n")
            elif upper == "QUIT":
                self.wfile.write(b"221 bye\r\n")
                return
            elif upper in ("RSET", "NOOP"):
                self.wfile.write(b"250 OK\r\n")
            else:
                self.wfile.write(b"502 not implemented\r\n")


class SinkServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), SinkHandler)
        self.messages = []
        self.reject = set()


class TemplateTests(unittest.TestCase):
    def test_render_requires_exact_placeholders_and_plain_text(self):
        rendered = templates.render("support_receipt", {"receipt": "SDI-ABC123DEF4", "category": "studio"})
        self.assertEqual(rendered.category, "transactional")
        self.assertIn("SDI-ABC123DEF4", rendered.subject)
        self.assertIn("service notice", rendered.text)
        self.assertNotIn("unsubscribe", rendered.text.lower().replace("cannot be unsubscribed", ""))
        with self.assertRaises(ValueError):
            templates.render("support_receipt", {"receipt": "SDI-1"})
        with self.assertRaises(ValueError):
            templates.render("support_receipt", {"receipt": "<b>x</b>", "category": "studio"})
        with self.assertRaises(KeyError):
            templates.render("newsletter", {})

    def test_opt_in_categories_require_an_unsubscribe_link(self):
        with self.assertRaises(ValueError):
            templates.render("marketing_campaign", {"headline": "New brushes", "body": "Try them."})
        rendered = templates.render("marketing_campaign", {"headline": "New brushes", "body": "Try them."}, UNSUB)
        self.assertEqual(rendered.category, "marketing")
        self.assertIn(UNSUB, rendered.text)
        self.assertIn("because you turned on marketing email", rendered.text)
        self.assertTrue(templates.preview("product_update", {"headline": "H", "body": "B"}, UNSUB).startswith("Subject: H"))

    def test_unsubscribe_tokens_round_trip_and_reject_tampering(self):
        digest = templates.email_hash("Someone@Example.test ")
        self.assertEqual(digest, templates.email_hash("someone@example.test"))
        token = templates.unsubscribe_token(SECRET, digest, "marketing")
        self.assertEqual(templates.verify_unsubscribe_token(SECRET, token), (digest, "marketing"))
        self.assertIsNone(templates.verify_unsubscribe_token(b"t" * 32, token))
        self.assertIsNone(templates.verify_unsubscribe_token(SECRET, token[:-2] + "zz"))
        self.assertIsNone(templates.verify_unsubscribe_token(SECRET, "garbage"))
        with self.assertRaises(ValueError):
            templates.unsubscribe_token(SECRET, digest, "transactional")


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.now = [1_800_000_000.0]
        self.queue = EmailQueue(self.root / "mail.sqlite3", clock=lambda: self.now[0])

    def test_dedup_claim_retry_and_bounce(self):
        first = self.queue.enqueue("a@example.test", "support_receipt", {"receipt": "SDI-1", "category": "studio"}, "SDI-1")
        again = self.queue.enqueue("A@example.test", "support_receipt", {"receipt": "SDI-1", "category": "studio"}, "SDI-1")
        self.assertEqual((first["status"], again["status"], again["id"]), ("queued", "duplicate", first["id"]))
        self.queue.enqueue("b@example.test", "support_receipt", {"receipt": "SDI-2", "category": "bug"}, "SDI-2")
        self.queue.enqueue("c@example.test", "support_receipt", {"receipt": "SDI-3", "category": "bug"}, "SDI-3")
        suppressed = {templates.email_hash("c@example.test")}
        claimed = self.queue.claim(10, suppressed=lambda h: h in suppressed)
        self.assertEqual([c["address"] for c in claimed], ["a@example.test", "b@example.test"])
        self.assertEqual(self.queue.counts()["suppressed"], 1)
        self.assertEqual(self.queue.claim(10), [])                       # nothing left while sending
        self.assertEqual(self.queue.mark(claimed[0]["id"], "sent"), "sent")
        self.assertEqual(self.queue.mark(claimed[1]["id"], "retry", "timeout"), "queued")
        self.assertEqual(self.queue.claim(10), [])                       # backoff not elapsed
        self.now[0] += 61
        second = self.queue.claim(10)
        self.assertEqual(second[0]["attempt"], 2)
        self.assertEqual(self.queue.mark(second[0]["id"], "retry", "timeout"), "queued")
        self.now[0] += 601
        third = self.queue.claim(10)
        self.assertEqual(self.queue.mark(third[0]["id"], "retry", "timeout"), "failed")
        bounced = []
        self.queue.enqueue("d@example.test", "support_receipt", {"receipt": "SDI-4", "category": "bug"}, "SDI-4")
        item = self.queue.claim(1)[0]
        self.assertEqual(self.queue.mark(item["id"], "bounced", "550", bounced.append), "bounced")
        self.assertEqual(bounced, [templates.email_hash("d@example.test")])
        self.assertEqual(self.queue.mark("nope", "sent"), "unknown")
        self.now[0] += 31 * 86400
        self.assertEqual(self.queue.purge(), 4)
        self.assertEqual(self.queue.counts(), {})

    def test_addresses_are_blanked_once_finished(self):
        self.queue.enqueue("a@example.test", "export_ready", {"produced_on": "2026-10-12"}, "export-1")
        item = self.queue.claim(1)[0]
        self.queue.mark(item["id"], "sent")
        import sqlite3
        with sqlite3.connect(self.root / "mail.sqlite3") as db:
            self.assertEqual(db.execute("SELECT address FROM messages").fetchone()[0], "")
        with self.assertRaises(ValueError):
            self.queue.enqueue("not an address", "export_ready", {"produced_on": "x"}, "k")


def recipient(address):
    return {"email": address, "email_hash": templates.email_hash(address)}


class FakeRecipientAPI:
    def __init__(self, pages):
        self.pages = list(pages)
        self.calls = []

    def call(self, operation, **payload):
        self.calls.append((operation, payload))
        return self.pages.pop(0)


class BlastTests(unittest.TestCase):
    CONTEXT = {"headline": "New sound pack", "body": "Forty new hits are in the library."}

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.now = [1_800_000_000.0]
        self.queue = EmailQueue(self.root / "mail.sqlite3", clock=lambda: self.now[0])
        self.unsub = lambda h, c: "https://www.example.test/unsubscribe?c=%s&h=%s" % (c, h[:8])

    def test_blast_honours_suppression_cadence_and_dedup(self):
        people = [recipient("a@example.test"), recipient("b@example.test"), recipient("c@example.test")]
        blocked = {templates.email_hash("c@example.test")}
        first = self.queue.enqueue_blast(people, "marketing_campaign", self.CONTEXT, "spring-1", self.unsub,
                                         suppressed=lambda h: h in blocked)
        self.assertEqual((first["queued"], first["suppressed"]), (2, 1))
        claimed = self.queue.claim(10)
        self.assertTrue(all("One-click unsubscribe: https://www.example.test/unsubscribe?c=marketing" in c["body"] for c in claimed))
        # A retry of the same blast is a no-op; a new campaign inside the window is held by cadence.
        retry = self.queue.enqueue_blast(people[:2], "marketing_campaign", self.CONTEXT, "spring-1", self.unsub)
        self.assertEqual(retry["cadence"], 2)
        second = self.queue.enqueue_blast(people[:2], "product_update", self.CONTEXT, "update-1", self.unsub)
        self.assertEqual((second["queued"], second["cadence"]), (0, 2))
        # Transactional mail never counts towards the cadence and never blocks it.
        self.queue.enqueue("b@example.test", "export_ready", {"produced_on": "2026-10-18"}, "export-1")
        self.now[0] += BLAST_MIN_INTERVAL_SECONDS + 1
        third = self.queue.enqueue_blast(people[:2], "marketing_campaign", self.CONTEXT, "spring-2", self.unsub)
        self.assertEqual(third["queued"], 2)

    def test_failed_or_suppressed_messages_do_not_hold_the_cadence(self):
        person = [recipient("a@example.test")]
        self.queue.enqueue_blast(person, "marketing_campaign", self.CONTEXT, "c-1", self.unsub)
        item = self.queue.claim(1)[0]
        self.queue.mark(item["id"], "bounced", "550")
        self.assertIsNone(self.queue.last_opt_in(templates.email_hash("a@example.test")))

    def test_blast_refuses_transactional_templates_bad_rows_and_limits(self):
        with self.assertRaises(ValueError):
            self.queue.enqueue_blast([recipient("a@example.test")], "export_ready", {"produced_on": "x"}, "c", self.unsub)
        with self.assertRaises(ValueError):
            self.queue.enqueue_blast([], "marketing_campaign", self.CONTEXT, "", self.unsub)
        with self.assertRaises(ValueError):
            self.queue.enqueue_blast([], "marketing_campaign", self.CONTEXT, "c", self.unsub, min_interval=60)
        forged = {"email": "x@example.test", "email_hash": templates.email_hash("y@example.test")}
        rows = [forged, "nonsense", recipient("a@example.test"), recipient("b@example.test")]
        summary = self.queue.enqueue_blast(rows, "marketing_campaign", self.CONTEXT, "c", self.unsub, max_recipients=1)
        self.assertEqual((summary["invalid"], summary["queued"], summary["over_cap"]), (2, 1, 1))
        self.assertNotIn("example.test", str(summary))

    def test_fetch_recipients_pages_and_checks_the_category(self):
        api = FakeRecipientAPI([{"category": "marketing", "recipients": [recipient("a@example.test")], "has_more": True},
                                {"category": "marketing", "recipients": [recipient("b@example.test")], "has_more": False}])
        rows = fetch_recipients(api, "marketing", batch=1)
        self.assertEqual([r["email"] for r in rows], ["a@example.test", "b@example.test"])
        self.assertEqual(api.calls[1], ("email_recipients", {"category": "marketing", "batch": 1, "page": 1}))
        with self.assertRaises(RuntimeError):
            fetch_recipients(FakeRecipientAPI([{"category": "product", "recipients": [], "has_more": False}]), "marketing")
        with self.assertRaises(RuntimeError):
            fetch_recipients(FakeRecipientAPI([{"error": "Category, batch and page required."}]), "marketing")


class SenderTests(unittest.TestCase):
    def setUp(self):
        self.sink = SinkServer()
        self.thread = threading.Thread(target=self.sink.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.sink.server_address[1]
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.queue = EmailQueue(self.root / "mail.sqlite3")

    def tearDown(self):
        self.sink.shutdown()
        self.sink.server_close()

    def test_remote_hosts_need_owner_activation(self):
        with self.assertRaises(ValueError):
            SMTPSender("smtp.example.test", 587, "noreply@example.test")
        SMTPSender("smtp.example.test", 587, "noreply@example.test", allow_remote=True)

    def test_worker_delivers_to_the_local_sink_with_correct_headers(self):
        sender = SMTPSender("127.0.0.1", self.port, "StickDeath Infinity <noreply@example.test>")
        self.queue.enqueue("member@example.test", "support_receipt", {"receipt": "SDI-9", "category": "studio"}, "SDI-9")
        self.queue.enqueue("fan@example.test", "marketing_campaign", {"headline": "New brushes", "body": "Try them."}, "campaign-1", UNSUB)
        self.queue.enqueue("gone@example.test", "export_ready", {"produced_on": "2026-10-12"}, "export-2")
        self.sink.reject.add("gone@example.test")
        bounced = []
        worker = EmailWorker(self.queue, sender, on_bounce=bounced.append, unsubscribe_url_for=lambda h, c: UNSUB)
        summary = worker.run_once()
        self.assertEqual(summary, {"sent": 2, "queued": 0, "failed": 0, "bounced": 1})
        self.assertEqual(bounced, [templates.email_hash("gone@example.test")])
        self.assertEqual(len(self.sink.messages), 2)
        by_recipient = {rcpts[0]: email.message_from_bytes(raw, policy=email.policy.default) for rcpts, raw in self.sink.messages}
        notice = by_recipient["member@example.test"]
        self.assertEqual(notice["Auto-Submitted"], "auto-generated")
        self.assertIsNone(notice["List-Unsubscribe"])
        self.assertEqual(notice.get_content_type(), "text/plain")
        self.assertIn("SDI-9", notice["Subject"])
        campaign = by_recipient["fan@example.test"]
        self.assertEqual(campaign["List-Unsubscribe"], "<%s>" % UNSUB)
        self.assertEqual(campaign["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click")
        self.assertIn(UNSUB, campaign.get_content())
        self.assertEqual(self.queue.counts(), {"sent": 2, "bounced": 1})
        self.assertEqual(worker.run_once(), {"sent": 0, "queued": 0, "failed": 0, "bounced": 0})

    def test_unreachable_server_requeues_for_retry(self):
        self.sink.shutdown()
        self.sink.server_close()
        sender = SMTPSender("127.0.0.1", self.port, "noreply@example.test", timeout=2)
        self.queue.enqueue("member@example.test", "export_ready", {"produced_on": "2026-10-12"}, "export-3")
        summary = EmailWorker(self.queue, sender).run_once()
        self.assertEqual(summary["queued"], 1)
        self.assertEqual(self.queue.counts(), {"queued": 1})
        self.sink = SinkServer()      # tearDown expects a live server
        self.thread = threading.Thread(target=self.sink.serve_forever, daemon=True)
        self.thread.start()


if __name__ == "__main__":
    unittest.main()
