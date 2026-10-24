"""SMTP delivery for the email queue.

Default policy is loopback only: a development or test host runs a local sink and
no member can receive mail. Sending through a remote relay requires
``allow_remote=True``, which the owner enables only after the sender domain and
relay configuration are verified (#276: "use an existing authorized sender").
Messages are plain text, carry ``Auto-Submitted`` for service notices and
``List-Unsubscribe`` headers for opt-in categories. Recipient refusals are
reported as bounces so the queue suppresses the address.
"""
from __future__ import annotations

import smtplib
from email.message import EmailMessage
from email.utils import formatdate, make_msgid, parseaddr
from typing import Callable, Dict, Optional

from ..ops.provider_health import classify_exception
from .queue import EmailQueue

LOOPBACK = ("localhost", "127.0.0.1", "::1")


class SMTPSender:
    def __init__(self, host: str, port: int, sender_address: str, *, allow_remote: bool = False, timeout: int = 15,
                 starttls: bool = False, credential: Optional[Callable[[], tuple]] = None):
        if host not in LOOPBACK and not allow_remote:
            raise ValueError("Remote SMTP requires explicit owner activation after the sender domain is verified.")
        name, address = parseaddr(sender_address)
        if "@" not in address:
            raise ValueError("sender address invalid")
        if not 1 <= port <= 65535:
            raise ValueError("port invalid")
        self.host, self.port, self.timeout = host, port, timeout
        self.sender = sender_address
        self.domain = address.rsplit("@", 1)[1]
        self.starttls = starttls
        self.credential = credential

    def build(self, to_address: str, subject: str, text: str, category: str, unsubscribe_url: Optional[str] = None) -> EmailMessage:
        message = EmailMessage()
        message["From"] = self.sender
        message["To"] = to_address
        message["Subject"] = subject
        message["Date"] = formatdate(localtime=False)
        message["Message-ID"] = make_msgid(domain=self.domain)
        if category == "transactional":
            message["Auto-Submitted"] = "auto-generated"
        else:
            if not unsubscribe_url:
                raise ValueError("opt-in email needs an unsubscribe url")
            message["List-Unsubscribe"] = "<%s>" % unsubscribe_url
            message["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
        message.set_content(text)
        return message

    def send(self, message: EmailMessage) -> None:
        with smtplib.SMTP(self.host, self.port, timeout=self.timeout) as smtp:
            smtp.ehlo()
            if self.starttls:
                smtp.starttls()
                smtp.ehlo()
            if self.credential:
                user, password = self.credential()
                smtp.login(user, password)
            smtp.send_message(message)


class EmailWorker:
    """Claims a batch, sends each message, records sent/retry/bounce."""

    def __init__(self, queue: EmailQueue, sender: SMTPSender, suppressed: Optional[Callable[[str], bool]] = None,
                 on_bounce: Optional[Callable[[str], None]] = None, unsubscribe_url_for: Optional[Callable[[str, str], str]] = None,
                 on_outcome: Optional[Callable[[bool, Optional[str]], object]] = None):
        self.queue = queue
        self.sender = sender
        self.suppressed = suppressed
        self.on_bounce = on_bounce
        self.unsubscribe_url_for = unsubscribe_url_for
        # Provider health (#248): called once per run that attempted a send, with
        # (succeeded, error_class). The class comes from the exception type only;
        # a recipient refusal is the recipient's, not a sender failure.
        self.on_outcome = on_outcome

    def run_once(self, batch: int = 50) -> Dict[str, int]:
        summary = {"sent": 0, "queued": 0, "failed": 0, "bounced": 0}
        last_error: Optional[BaseException] = None
        for item in self.queue.claim(batch, self.suppressed):
            unsubscribe = self.unsubscribe_url_for(item["address_hash"], item["category"]) if (self.unsubscribe_url_for and item["category"] != "transactional") else None
            try:
                message = self.sender.build(item["address"], item["subject"], item["body"], item["category"], unsubscribe)
                self.sender.send(message)
            except smtplib.SMTPRecipientsRefused:
                state = self.queue.mark(item["id"], "bounced", "recipient refused", self.on_bounce)
            except (smtplib.SMTPException, OSError, ValueError) as error:
                last_error = error
                state = self.queue.mark(item["id"], "retry", type(error).__name__)
            else:
                state = self.queue.mark(item["id"], "sent")
            summary[state] = summary.get(state, 0) + 1
        if self.on_outcome is not None and (last_error is not None or summary["sent"]):
            self.on_outcome(last_error is None, None if last_error is None else classify_exception(last_error))
        return summary
