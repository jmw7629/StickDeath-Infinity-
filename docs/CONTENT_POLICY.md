# Content, age and moderation rules for animated submissions (#261)

Status 2026-10-13: policy text and enforcement points in source; the minimum age, the final
wording and the platform ratings are owner and legal decisions. This document does not promise
that the app can eliminate legal or privacy risk; it records what is enforced and where human
review and legal review are still required.

## 1. What members may submit

- Original frame-by-frame stick-figure animation made in the Studio, including the brand's
  cartoon violence between stick figures, with sounds and images the member has rights to
  (bundled licensed libraries, their own recordings, or assets whose licence allows it).
- Spatter-generated drafts follow the same rules and additionally require the owner's approval
  of the exact render before any release (`release_allowed` requires `owner_at_decision` for
  `spatter_generated` renders).

## 2. What is refused

- Sexual content; any sexual depiction involving minors (absolute, reported to the owner for
  escalation to the competent authority, never forwarded to a public service).
- Content that targets a real, identifiable person or group with harassment, threats or hate,
  or that depicts real people without their permission.
- Instructions or encouragement for real-world harm, self-harm or illegal acts.
- Third-party characters, music, logos or footage without documented rights
  (`render_reviews.rights_summary` is a declaration; `rights_cleared` is set by a reviewer and
  revoked with a reason).
- Personal data of others, credentials, or private project files uploaded as "media".
- Anything that would violate the destination platform's rules at the time of publication
  (YouTube Community Guidelines and the `made_for_kids` declaration, Discord/Facebook/X terms).

## 3. Age

- The content policy version carries `min_age` in its metadata (`policy_versions.metadata`).
  Publishing it requires the owner (`sdi_consent_action('publish','content', metadata =>
  '{"min_age":"<n>"}')`); the server refuses a content policy without it.
- Members accept the content policy with an explicit attestation (`attestation.age_ok`); the
  server records the attestation and never infers or verifies age itself.
- Submission requires the current publishing consent **and**, once a content policy is published,
  its current attested acceptance (`sdi_consent_verify`, called by the intake registrar before any
  render is registered). The native sign-up/consent copy must show the age rule verbatim; the
  App Store age rating is set by the owner in App Store Connect to match.

## 4. Enforcement points (source)

| Point | Where | Behaviour |
| --- | --- | --- |
| Consent and age gate | `backend/sql/consent-versions.sql`, `backend/ingestion/registration.py` | no registration without current, attested consent |
| Deterministic content rules | `backend/spatter/content_rules.py`, wired into `backend/spatter/handler.py` and `backend/ingestion/store.py` | Spatter prompts (every non-assistant message) and submission title/rights summary are checked against a small, conservative phrase/pattern list for the section 2 categories before any provider call or upload row; a refusal returns `content_rule.<category>` without echoing the text. Passing is not approval |
| Real media only | `backend/ingestion/media.py` | bounded `ffprobe` + full decode of the MP4; duration, dimensions, audio, integrity |
| Human review before release | `admin-approval.sql`, `review-rights.sql` | approve / reject / request changes bound to the exact digest, consent version and destinations; rights cleared separately |
| Private previews | `upload-preview.sql`, `preview-renewal.sql` | reviewers watch expiring private HTTPS previews; nothing is sent to a public service for review |
| Reports | `video-feed.sql`, `war-moderation.sql`, `rooms-v2.sql` | categories `rights`, `abuse`, `unsafe`, `spam`; one report per member per object; repeat reports do not reopen decided cases |
| Decisions and takedown | `moderation.sql`, `feed-publication.sql`, `publishing-withdrawal.sql` | removal revokes approval, hides the post, queues hosted-copy removal and channel withdrawal; actor separation (uninvolved administrator) |
| Appeals | `moderation.sql` (`moderation_appeals`), `war-appeals.sql`, `admin-users.sql` (`account_appeals`) | member-visible decisions; one appeal per action; decided by an uninvolved administrator |
| Account consequences | `admin-users.sql` | suspend / ban with reason, audited, reversible, sessions ended immediately |
| Automated generation | `agent-controls.sql` | paused by default, emergency stop, caps; drafts stay private until owner approval |

## 5. What is not enforced automatically

- No automated classifier decides on content: every public release passes human review. The
  deterministic content rules only refuse text that plainly matches a refused category (and
  personal data or credentials pasted into a prompt or title); they do not detect most
  violations, do not inspect video or audio, and never mark anything compliant. There is
  no claim that review catches everything; reports and appeals exist for that reason.
- Platform rule changes are not tracked automatically; the destination adapters report
  `unavailable` until the owner confirms each platform's current terms (#243).
- Legal review of this policy, the privacy notice and the terms is outstanding
  (`website/policies/*-v1.html` carry the draft banner).
