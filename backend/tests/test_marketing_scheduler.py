"""Marketing cadence scheduler tests (#283). Fake RPC clients and a recording fake
transport; the email queue is a private SQLite file in a temp directory. Nothing is
posted or mailed."""
import json
import os
import tempfile
import unittest
from pathlib import Path

from backend.mail import templates
from backend.mail.queue import EmailQueue, enqueue_blast
from backend.publishing import marketing_scheduler as ms
from backend.publishing.destinations import DestinationConfig, MarketingWorker, default_registry

SECRET = b"k" * 32


def person(n):
    address = "member%d@example.test" % n
    return {"user_id": "u%d" % n, "email": address, "email_hash": templates.email_hash(address)}


class FakeMarketingAPI:
    def __init__(self, jobs, due=None):
        self.jobs = list(jobs)
        self.due = due if due is not None else {"queued": []}
        self.calls = []

    def call(self, operation, **payload):
        self.calls.append((operation, payload))
        if operation == "cadence_due":
            return self.due
        if operation == "claim":
            return self.jobs.pop(0) if self.jobs else {"empty": True}
        if operation == "finish":
            return True
        raise AssertionError(operation)

    def last_finish(self):
        return [c[1] for c in self.calls if c[0] == "finish"][-1]

    def ops(self):
        return [c[0] for c in self.calls]


class FakeRecipients:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def call(self, operation, **payload):
        self.calls.append(payload)
        assert operation == "email_recipients" and payload["category"] == "marketing"
        page = dict(self.pages[payload["page"]])
        if "error" not in page:
            page.setdefault("category", "marketing")
        return page


class RecordingTransport:
    def __init__(self, status=200, body=None):
        self.requests = []
        self.status, self.body = status, body or {"id": "m1", "channel_id": "c1"}

    def __call__(self, method, url, headers, body):
        self.requests.append((method, url, headers, body))
        return self.status, {}, json.dumps(self.body).encode()


def job(destination, draft="d1", copy="Fresh stick action.", **extra):
    value = {"draft": draft, "lease": "lease-" + draft, "destination": destination, "copy": copy, "digest": None, "media_url": None, "title": None}
    value.update(extra)
    return value


class EnqueueBlastTests(unittest.TestCase):
    def setUp(self):
        root = Path(tempfile.mkdtemp())
        os.chmod(root, 0o700)
        self.queue = EmailQueue(root / "mail" / "queue.db")
        self.url_for = ms.unsubscribe_url_factory("https://www.example.test/unsubscribe", SECRET)

    def test_blast_is_idempotent_and_refuses_mismatched_rows(self):
        rows = [person(1), person(2), {"email": "x@example.test", "email_hash": "0" * 64}]
        context = {"headline": "Hi", "body": "Plug"}
        first = enqueue_blast(self.queue, rows, "marketing_campaign", context, "marketing-draft:d1", self.url_for)
        self.assertEqual((first["queued"], first["invalid"]), (2, 1))
        again = enqueue_blast(self.queue, rows, "marketing_campaign", context, "marketing-draft:d1", self.url_for)
        self.assertEqual((again["queued"], again["cadence"], again["invalid"]), (0, 2, 1))
        self.assertEqual(self.queue.campaign_count("marketing-draft:d1"), 2)
        self.assertEqual(self.queue.counts(), {"queued": 2})
        claimed = self.queue.claim(10)
        self.assertIn("One-click unsubscribe: https://www.example.test/unsubscribe?token=", claimed[0]["body"])
        token = claimed[0]["body"].rsplit("token=", 1)[1].strip()
        self.assertEqual(templates.verify_unsubscribe_token(SECRET, token), (claimed[0]["address_hash"], "marketing"))

    def test_transactional_templates_cannot_be_blasted(self):
        with self.assertRaises(ValueError):
            self.queue.enqueue_blast([person(1)], "export_ready", {"produced_on": "today"}, "k", self.url_for)

    def test_unsubscribe_factory_requires_https_and_secret(self):
        with self.assertRaises(ValueError):
            ms.unsubscribe_url_factory("http://www.example.test/u", SECRET)
        with self.assertRaises(ValueError):
            ms.unsubscribe_url_factory("https://www.example.test/u", b"short")


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        root = Path(tempfile.mkdtemp())
        os.chmod(root, 0o700)
        self.queue = EmailQueue(root / "mail" / "queue.db")
        self.url_for = ms.unsubscribe_url_factory("https://www.example.test/unsubscribe", SECRET)

    def registry(self, live):
        return default_registry({"discord": DestinationConfig(enabled=True, dry_run=not live, target="123", credential=lambda: "hook-secret"),
                                 "facebook": DestinationConfig(enabled=True, dry_run=not live, target="456", credential=lambda: "page-secret")})

    def test_dry_run_schedules_but_never_claims_posts_or_mails(self):
        api = FakeMarketingAPI([job("discord")], due={"queued": [{"draft": "d1", "destination": "discord"}]})
        transport = RecordingTransport()
        report = ms.MarketingScheduler(api, MarketingWorker(api, self.registry(False), transport)).run_once()
        self.assertEqual(report["mode"], "dry_run")
        self.assertEqual(report["scheduled"], [{"draft": "d1", "destination": "discord"}])
        self.assertEqual(api.ops(), ["cadence_due"])
        self.assertEqual(transport.requests, [])

    def test_live_posts_social_and_queues_email_blast(self):
        api = FakeMarketingAPI([job("discord", "d1"), job("facebook", "d2"), job("email", "d3", title="Weekly picks")])
        transport = RecordingTransport()
        fb = RecordingTransport(body={"id": "456_789"})

        def route(method, url, headers, body):
            return (fb if "graph.facebook.com" in url else transport)(method, url, headers, body)

        recipients = FakeRecipients([{"recipients": [person(1), person(2)], "has_more": True},
                                     {"recipients": [person(3)], "has_more": False}])
        blaster = ms.EmailBlaster(recipients, self.queue, self.url_for, page_size=2)
        report = ms.MarketingScheduler(api, MarketingWorker(api, self.registry(True), route), live=True, blaster=blaster).run_once()
        states = [(j["draft"], j["state"]) for j in report["jobs"]]
        self.assertEqual(states, [("d1", "published"), ("d2", "published"), ("d3", "published")])
        finishes = [c[1] for c in api.calls if c[0] == "finish"]
        self.assertEqual(finishes[2], {"draft": "d3", "token": "lease-d3", "provider_ref": "email-queue:3"})
        self.assertEqual(self.queue.counts(), {"queued": 3})
        self.assertEqual(len(transport.requests) + len(fb.requests), 2)
        self.assertNotIn("request", json.dumps(report))

    def test_retried_email_draft_does_not_mail_twice(self):
        recipients = FakeRecipients([{"recipients": [person(1)], "has_more": False}] * 2)
        blaster = ms.EmailBlaster(recipients, self.queue, self.url_for)
        for _ in range(2):
            api = FakeMarketingAPI([job("email", "d9")])
            ms.MarketingScheduler(api, MarketingWorker(api, {}), live=True, blaster=blaster).run_once()
        self.assertEqual(self.queue.counts(), {"queued": 1})
        self.assertEqual(api.last_finish()["provider_ref"], "email-queue:1")

    def test_email_failures_are_reported_not_published(self):
        cases = [
            (None, FakeRecipients([]), "Email blast not configured"),
            ("blaster", FakeRecipients([{"recipients": [], "has_more": False}]), "No eligible recipients"),
            ("blaster", FakeRecipients([{"error": "Category, batch and page required."}]), "Recipient lookup failed"),
        ]
        for kind, recipients, expected in cases:
            api = FakeMarketingAPI([job("email")])
            blaster = ms.EmailBlaster(recipients, self.queue, self.url_for) if kind else None
            report = ms.MarketingScheduler(api, MarketingWorker(api, {}), live=True, blaster=blaster, email_reason="missing X").run_once()
            self.assertEqual(report["jobs"][0]["state"], "failed")
            self.assertIn(expected, api.last_finish()["failure"])
        api = FakeMarketingAPI([job("email", copy="Use <b>bold</b>")])
        recipients = FakeRecipients([{"recipients": [person(1)], "has_more": False}])
        ms.MarketingScheduler(api, MarketingWorker(api, {}), live=True, blaster=ms.EmailBlaster(recipients, self.queue, self.url_for)).run_once()
        self.assertIn("Draft content invalid", api.last_finish()["failure"])
        self.assertEqual(recipients.calls, [])

    def test_unconfigured_social_destination_fails_without_sending(self):
        api = FakeMarketingAPI([job("discord")])
        transport = RecordingTransport()
        report = ms.MarketingScheduler(api, MarketingWorker(api, default_registry(), transport), live=True).run_once()
        self.assertEqual(report["jobs"][0]["state"], "unavailable")
        self.assertEqual(transport.requests, [])

    def test_cli_live_requires_owner_switch_and_reports_configuration(self):
        api = FakeMarketingAPI([job("discord")])
        self.assertEqual(ms.main(["--live"], environment={}, api_factory=lambda: api, recipients_factory=lambda: FakeRecipients([])), 2)
        self.assertEqual(api.calls, [])
        self.assertEqual(ms.main([], environment={}, api_factory=lambda: api, recipients_factory=lambda: FakeRecipients([])), 0)
        self.assertEqual(api.ops(), ["cadence_due"])
        self.assertEqual(ms.main([], environment={}), 2)  # backend not configured

    def test_environment_registry_reads_credentials_from_files_only_when_live(self):
        root = Path(tempfile.mkdtemp())
        token = root / "discord.token"
        token.write_text("webhook-token\n")
        env = {"SDI_DISCORD_WEBHOOK_ID": "111", "SDI_DISCORD_WEBHOOK_TOKEN_FILE": str(token)}
        dry = ms.registry_from_environment(env, live=False)
        self.assertTrue(dry["discord"].configured and dry["discord"].config.dry_run)
        self.assertFalse(dry["facebook"].configured)
        outcome = dry["discord"].publish(ms_post("discord"), RecordingTransport())
        self.assertEqual(outcome.state, "dry_run")
        self.assertNotIn("webhook-token", json.dumps(outcome.request))
        live = ms.registry_from_environment(env, live=True)
        transport = RecordingTransport()
        self.assertEqual(live["discord"].publish(ms_post("discord"), transport).state, "published")
        self.assertIn("/111/webhook-token", transport.requests[0][1])
        blaster, reason = ms.blaster_from_environment({}, FakeRecipients([]))
        self.assertIsNone(blaster)
        self.assertIn("SDI_MAIL_QUEUE_PATH", reason)


def ms_post(destination):
    from backend.publishing.destinations import Post
    return Post(destination=destination, copy="Plug")


if __name__ == "__main__":
    unittest.main()
