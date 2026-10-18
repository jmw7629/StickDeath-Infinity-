"""Deterministic server-side content-rule check for Spatter prompts and submission metadata (#261).

The categories mirror ``docs/CONTENT_POLICY.md`` section 2. The check is a small,
conservative, auditable phrase/pattern list: it refuses text that plainly falls in a
refused category and lets everything else through to the existing human review. It
is not a classifier, does not decide that anything is acceptable, and never claims
legal or platform compliance. ``allowed`` means only "no rule matched".

Stick-figure cartoon violence is the product's genre and is deliberately not a
category: "the stick figure gets knocked off the ledge" must pass.

A result carries a stable reason code (``content_rule.<category>``) and the rule id
that matched. Neither the matched text nor the input is echoed, so a refusal can be
logged or returned to a client without repeating the content.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Iterable, Mapping, Optional, Sequence, Tuple

# Category keys, in evaluation order (the most severe first so its code wins).
MINOR_SEXUAL = "minor_sexual_content"
SEXUAL = "sexual_content"
REAL_WORLD_HARM = "real_world_harm"
TARGETED_HARASSMENT = "targeted_harassment"
THIRD_PARTY_RIGHTS = "third_party_rights"
PERSONAL_DATA = "personal_data"
CREDENTIALS = "credentials"

CATEGORIES: Tuple[str, ...] = (MINOR_SEXUAL, SEXUAL, REAL_WORLD_HARM, TARGETED_HARASSMENT,
                               THIRD_PARTY_RIGHTS, PERSONAL_DATA, CREDENTIALS)

# Public, non-sensitive explanation per category. Wording never says the remaining
# content is compliant.
EXPLANATIONS: Mapping[str, str] = {
    MINOR_SEXUAL: "Sexual content involving minors is never accepted.",
    SEXUAL: "Sexual content is not accepted.",
    REAL_WORLD_HARM: "Instructions or encouragement for real-world harm, self-harm or illegal acts are not accepted.",
    TARGETED_HARASSMENT: "Content that targets a real person or group with threats, harassment or hate is not accepted.",
    THIRD_PARTY_RIGHTS: "Copying third-party characters, music, logos or footage without documented rights is not accepted.",
    PERSONAL_DATA: "Personal contact or identity data must not be included.",
    CREDENTIALS: "Passwords, keys or access tokens must not be included.",
}


@dataclass(frozen=True)
class Rule:
    id: str
    category: str
    pattern: "re.Pattern[str]"


@dataclass(frozen=True)
class RuleResult:
    allowed: bool
    code: str = ""            # "content_rule.<category>" when refused
    category: str = ""
    rule: str = ""            # stable rule id, never the matched text
    field: str = ""           # which input field matched (metadata checks)

    @property
    def explanation(self) -> str:
        return EXPLANATIONS.get(self.category, "")


ALLOWED = RuleResult(True)


def _words(*phrases: str) -> str:
    """Whole-word alternation; spaces in a phrase match any run of separators."""
    return r"\b(?:%s)\b" % "|".join(re.escape(p).replace(r"\ ", r"[\s\-_]+") for p in phrases)


def _compile(expression: str) -> "re.Pattern[str]":
    return re.compile(expression, re.IGNORECASE)


# Minor-sexual content is decided by co-occurrence of a minor term and a sexual term
# (see check_text), so neither list alone refuses on that category.
_MINOR_TERMS = _compile(_words("child", "children", "kid", "kids", "minor", "minors", "underage", "under age", "preteen",
                               "pre teen", "toddler", "schoolgirl", "schoolboy", "loli", "shota")
                        + r"|\b(?:1[0-7]|[1-9])[\s\-]*(?:yo|y/o|years?[\s\-]*old)\b")
_SEXUAL_TERMS = _compile(_words("sex", "sexual", "sexy", "nude", "nudes", "naked", "porn", "porno", "pornographic", "nsfw",
                                "hentai", "erotic", "erotica", "explicit sex", "strip tease", "striptease", "fetish",
                                "genitals", "onlyfans", "xxx"))

BUILTIN_RULES: Tuple[Rule, ...] = (
    Rule("harm.weapons", REAL_WORLD_HARM, _compile(
        r"\b(?:how\s+(?:do\s+i|to|can\s+i)|instructions?\s+(?:for|to)|steps?\s+to|recipe\s+for|guide\s+to)\s+"
        r"(?:make|build|assemble|manufacture|synthesi[sz]e|cook)\s+(?:an?\s+|the\s+|some\s+)?"
        r"(?:real\s+)?(?:bomb|pipe\s*bomb|explosives?|ied|napalm|nerve\s+agent|ghost\s+gun|meth|methamphetamine|poison)\b")),
    Rule("harm.self", REAL_WORLD_HARM, _compile(_words("kill myself", "end my life", "suicide method", "suicide methods",
                                                       "how to self harm", "ways to self harm"))),
    Rule("harm.real_attack", REAL_WORLD_HARM, _compile(_words("school shooting", "mass shooting plan", "swat someone",
                                                              "swatting"))),
    Rule("harass.dox", TARGETED_HARASSMENT, _compile(_words("dox", "doxx", "doxxing", "doxing", "home address of",
                                                            "where does he live", "where does she live", "where do they live"))),
    Rule("harass.threat", TARGETED_HARASSMENT, _compile(
        r"\b(?:i\s+(?:will|am\s+going\s+to|'?m\s+gonna)|we\s+(?:will|are\s+going\s+to))\s+(?:kill|hurt|find|shoot|stab)\s+"
        r"(?:you|him|her|them)\s+(?:in\s+real\s+life|irl|for\s+real)\b")),
    Rule("harass.hate", TARGETED_HARASSMENT, _compile(_words("ethnic cleansing", "gas the", "race war", "exterminate the"))),
    Rule("rights.rip", THIRD_PARTY_RIGHTS, _compile(
        r"\b(?:rip|ripped|copy|copied|use|reupload|re-upload|download(?:ed)?)\s+(?:the\s+)?(?:official\s+)?"
        r"(?:soundtrack|theme\s+song|footage|episode|logo|trailer)\s+(?:from|of)\b")),
    Rule("rights.pirated", THIRD_PARTY_RIGHTS, _compile(_words("pirated", "torrent", "cracked copy", "no copyright intended",
                                                               "copyright free remix of"))),
    Rule("personal.email", PERSONAL_DATA, _compile(r"\b[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\b")),
    Rule("personal.phone", PERSONAL_DATA, _compile(r"(?<![\w.])(?:\+?\d{1,3}[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}(?![\w.])")),
    Rule("personal.ssn", PERSONAL_DATA, _compile(r"\b\d{3}-\d{2}-\d{4}\b")),
    Rule("credentials.key", CREDENTIALS, _compile(
        r"\b(?:sk|pk|rk)_(?:live|test)_[a-z0-9]{8,}|\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}|\bxox[abpr]-[A-Za-z0-9\-]{10,}"
        r"|-----BEGIN [A-Z ]*PRIVATE KEY-----|\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.")),
    Rule("credentials.password", CREDENTIALS, _compile(r"\b(?:password|passcode|passwd|api[\s_\-]?key|secret[\s_\-]?key)\s*[:=]\s*\S{4,}")),
)


def _card_number(text: str) -> bool:
    """Luhn-valid 13-19 digit runs (spaces or dashes allowed) are treated as card numbers."""
    for match in re.finditer(r"(?<!\d)(?:\d[\s\-]?){12,18}\d(?!\d)", text):
        digits = [int(c) for c in match.group(0) if c.isdigit()]
        total = 0
        for index, digit in enumerate(reversed(digits)):
            if index % 2:
                digit *= 2
                if digit > 9:
                    digit -= 9
            total += digit
        if total % 10 == 0:
            return True
    return False


def normalize(text: str) -> str:
    """NFKC, strip zero-width/format characters and collapse whitespace so trivial
    obfuscation (full-width letters, joiners) does not bypass a rule."""
    folded = unicodedata.normalize("NFKC", text)
    folded = "".join(c for c in folded if unicodedata.category(c) != "Cf")
    return re.sub(r"\s+", " ", folded).strip()


class ContentRules:
    """A rule set. ``extra_rules`` lets an owner-managed deployment (or a test) add
    rules without editing source; the built-in rules always apply."""

    def __init__(self, extra_rules: Iterable[Rule] = (), skip_categories: Iterable[str] = ()):
        extra = tuple(extra_rules)
        for rule in extra:
            if rule.category not in CATEGORIES:
                raise ValueError("unknown content-rule category %r" % rule.category)
        self.rules = BUILTIN_RULES + extra
        self.skip = frozenset(skip_categories)
        unknown = self.skip - set(CATEGORIES)
        if unknown:
            raise ValueError("unknown content-rule categories %r" % sorted(unknown))

    def check_text(self, text: str, skip: Iterable[str] = ()) -> RuleResult:
        if not isinstance(text, str) or not text:
            return ALLOWED
        skipped = self.skip | frozenset(skip)
        value = normalize(text)
        if MINOR_SEXUAL not in skipped and _MINOR_TERMS.search(value) and _SEXUAL_TERMS.search(value):
            return _refuse(MINOR_SEXUAL, "minor.sexual")
        if SEXUAL not in skipped and _SEXUAL_TERMS.search(value):
            return _refuse(SEXUAL, "sexual.terms")
        for category in CATEGORIES:
            if category in skipped:
                continue
            for rule in self.rules:
                if rule.category == category and rule.pattern.search(value):
                    return _refuse(category, rule.id)
            if category == PERSONAL_DATA and _card_number(value):
                return _refuse(PERSONAL_DATA, "personal.card")
        return ALLOWED

    def check_messages(self, messages: Sequence[Mapping[str, str]]) -> RuleResult:
        """Checks every message the client supplied except assistant turns (those are
        prior model output the client echoes back; they are not new user content)."""
        for message in messages:
            if message.get("role") == "assistant":
                continue
            result = self.check_text(message.get("content", ""))
            if not result.allowed:
                return result
        return ALLOWED

    def check_submission(self, metadata: Mapping[str, object]) -> RuleResult:
        """Submission metadata: the title gets every rule; the rights summary is an
        attribution field where a licensor's contact address is legitimate, so
        personal-data rules are skipped there."""
        for field, skip in (("title", ()), ("description", ()), ("rights_summary", (PERSONAL_DATA,))):
            value = metadata.get(field)
            if isinstance(value, str):
                result = self.check_text(value, skip)
                if not result.allowed:
                    return RuleResult(False, result.code, result.category, result.rule, field)
        return ALLOWED


def _refuse(category: str, rule: str) -> RuleResult:
    return RuleResult(False, "content_rule." + category, category, rule)


DEFAULT_RULES = ContentRules()


def check_text(text: str) -> RuleResult:
    return DEFAULT_RULES.check_text(text)


def check_messages(messages: Sequence[Mapping[str, str]]) -> RuleResult:
    return DEFAULT_RULES.check_messages(messages)


def check_submission(metadata: Mapping[str, object], rules: Optional[ContentRules] = None) -> RuleResult:
    return (rules or DEFAULT_RULES).check_submission(metadata)
