# Studio-first product scope — September 19, 2026

Joseph Willis's September 19 direction supersedes earlier requirements to retain messaging and calls. This is a product and implementation contract, not a claim that connected features are finished or legal advice.

## Delivery order

1. Finish and verify native SwiftUI Studio: preserve the current layout, one snapping primary toolbar and one dismissible options popup. Complete tools, editable selections, layers, full-document history, offline recovery, timing, audio, import and real export. Carry forward the existing tested clipboard work.
2. Invite-only Studio collaboration on the same canonical document and tested commands.
3. War Room video contests and optional profile records.
4. Consented official-channel publishing and approved social marketing renditions.

No in-app user messaging, direct/group text chat, voice calls, video calls, call billing, contact harvesting or device-wide broadcasting. Spatter remains a Studio assistant. No new paid service is authorized.

## Rooms

- A creator chooses a specific project and creates a room. An invite may be forwarded through the operating-system share sheet or copied as a code; there is no internal inbox.
- Invites are room-scoped, expiring, revocable and use-limited. They must never contain an account session, OAuth token or provider credential. Generate high-entropy secrets server-side, store only hashes, redact them from logs and rate-limit redemption.
- A recipient signs in and accepts collaboration. The room owner approves admission before the recipient can see the project; forwarding an invite alone grants no project access. Both parties explicitly choose the project and permissions they share.
- Server-enforced membership and roles apply to documents, revisions, assets, previews and downloads. Do not rely on hidden buttons or a code as the sole authorization check. Project sharing is not camera, microphone or screen sharing.
- Use versioned Studio commands, stable IDs, optimistic concurrency and explicit conflict handling. Preserve a local backup before applying remote edits; deduplicate retried operations. A revoked member cannot sync further changes. Warn truthfully that revocation cannot erase copies already downloaded.
- Provide leave, revoke invite, remove member, report and block. Blocking invalidates pending invites and membership access according to the room policy. No room is publicly discoverable by default.
- Current implementation: Rooms is an honest unavailable screen. No invite generation, redemption or collaboration sync is connected yet.

## War Room

- Two creators submit actual rendered videos and agree to the matchup. Viewers can watch both and choose their favorite animation, not rate a person's appearance.
- No chat or comments. Moderation, rights checks, reporting, blocking, age-appropriate access and takedown handling precede public exposure.
- One current vote per eligible authenticated viewer per matchup, enforced by the server. Disallow participant self-votes. Use transactional unique constraints, rate limits, idempotency and an auditable closing time. Decide ties explicitly; do not create a win or loss for a tie or cancelled contest.
- Finalized eligible votes determine the result. Never populate sample wins, losses, watching counts or rankings as real data.
- Users independently choose public badge and win/loss visibility; both default off. Keep preferences account-scoped and server-enforced across profiles, leaderboards and API responses. Hiding counts does not erase the internal contest record. Public video participation can still be visible to viewers; do not promise anonymity.
- Current implementation: no live submissions, voting, records or badges. The prior sample scoreboard and fake matchmaking were removed.

## Official-channel publishing and marketing

The owner's requested automation becomes an automatic pipeline for explicitly approved publications. Creating, autosaving, reopening or locally exporting a project must never upload it. Private drafts and room projects stay private until the relevant creators authorize a particular rendered revision and destination.

- Before submission, show the rendered video, official SDI channel identity, intended visibility, title, description, audio attribution and a preview of the small bottom-right watercolor SDI mark. Use the approved SDI brand asset; do not substitute a third-party logo or modify the editable original. Normal local exports remain separate from the channel rendition.
- Record separate permissions for official-channel publication and social marketing reuse. Explain proposed edits, watermark, platforms, attribution and license scope in plain language. Marketing refusal must not silently become consent via a collaboration invite or local save.
- Confirm rights to imported art, music, sound, footage and contributors' work. A collaborator cannot grant another contributor's rights. Bind approvals to the exact render digest and permission version; a changed render or new marketing purpose requires approval again.
- Keep owner OAuth credentials on the authenticated backend. Upload actual binary media with resumable transfers, quotas and durable idempotent jobs. Recheck permission, moderation and revocation before upload and before visibility changes. Expose honest queued, uploading, processing, failed, cancelled and published states with actual resulting URLs.
- Provide cancel/retry, permission withdrawal, deletion/takedown requests and retention rules. Do not promise deletion of copies already shared by third parties. Handle races between cancellation, upload completion and public visibility explicitly.
- Respect YouTube's current upload, channel identification, visibility choice and express-consent requirements. Do not describe the owner channel as the creator's own channel. API audit, OAuth owner consent, channel access, quota and age/jurisdiction policies remain launch gates. Do not perform live uploads as tests.
- Current implementation: this is a contract only. No automatic uploader, marketing reuse or watermark renderer is enabled by this change.

## Privacy and release boundaries

Removing messaging and calls reduces exposure; it cannot eliminate privacy, intellectual-property, child-safety or legal responsibilities. Collect only necessary account/project/vote/permission data, document retention and deletion, secure access, and obtain qualified review of publication licenses and the age/jurisdiction model before public launch.

Existing historical messaging source is retained outside app target membership. Existing server endpoints/data require a separate authenticated inventory and retirement review; no production backend or historical user data was changed in this slice. Historical brain packs remain preserved, but the current Spatter capability prompt explicitly overrides their retired call/chat instructions.

The native project and XcodeGen specification both exclude retired messaging/call services and views, and no longer link LiveKit. The app no longer declares call camera/microphone permissions. Photos/Files image and video import and Studio audio playback/export remain in scope.

The owner subsequently resumed uninterrupted single-agent delivery. The complete remaining build contract is [GitHub issue #116](https://github.com/jmw7629/StickDeath-Infinity-/issues/116), with 145 concrete delivery tasks across 27 epics and a rolling next-work queue. This scope change does not represent a new native release, web deployment or independent approval. Native and browser evidence must always identify their actual source revision.

## Additional delivery requirements

- Complete the reference-faithful splash, welcome and onboarding; Apple, Google, GitHub and Microsoft sign-in with secure restoration after initial consent; real social video feed, likes, follows, sharing and challenges. Historical messaging screens are excluded.
- Audit and reuse the existing licensed sound catalog, then finish the searchable audio library and multitrack operations. Add thousands of distinct rights-cleared image assets useful for stick animation, with attribution and on-demand storage. Historical corpus remains private research material unless rights are resolved.
- Spatter provides grounded support and uses the same typed Studio operations as the user. Aim for at least one quality-controlled original private video draft per day after capacity is verified. The owner must approve the exact render before any feed, channel or social release; changed renders need new approval.
- The command center uses server-enforced admin roles, MFA, audit logs and private owner enrollment. Provider credentials remain server-side. Spatter has no shell or unrestricted admin authority.
- Monthly plans are requested at USD 4.99 and USD 9.99. Annual prices and entitlements remain configuration decisions. Reuse the verified existing Stripe account, use applicable native purchase rules, and test without live charges. Screenshot-only extra tiers, balances and coin systems are not authorized.
- Editable documents and source media remain on-device. The backend stores only essential identity/access, social, consent, billing and job metadata, plus bounded temporary media. Verify publication before cleaning staging; preserve the user's original. YouTube is not an editable-project backup.

## Verification of this scope slice

- Passed: actual iOS 26.2 SDK typecheck with all 117 app source files in the compilation and the 12 changed/dependent bodies selected. This includes the new shared panel geometry and all five Studio panels that use it. Source bytes were hashed before and after; 63.137 seconds, exit 0.
- Passed: compilation of all 24 native UI test definitions, including the new Rooms → War Room → Studio journey; 2.687 seconds, exit 0. These definitions have not been executed for this source.
- Passed: source/security checks, retired-communications build gate, Xcode object-reference integrity, both property-list syntax checks and Git whitespace checks. The retirement gate runs in source-security CI.
- Found and corrected: a broader all-body typecheck exposed the rounded-corner helper hidden in the retired chat file. That attempt was stopped after the real diagnostic; its original log and source hashes were preserved. The helper was moved verbatim into `Extensions/View+SD.swift`, registered in the app target, and its actual Studio consumers then passed compiler checks. This is not an all-body/link/simulator pass.
- Not run: a linked app build, simulator journeys, physical-device checks, independent review, live collaboration/voting/upload tests, or a deployment of this change. The existing published native run remains cancelled at the owner's September 13 pause. Earlier Studio evidence retains its original source scope.

Primary platform references checked September 19, 2026:

- [YouTube Developer Policies](https://developers.google.com/youtube/terms/developer-policies): channel identification, visibility, use of data and prior specific express consent for automated actions.
- [YouTube Required Minimum Functionality](https://developers.google.com/youtube/terms/required-minimum-functionality): upload UI and privacy choices.
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): user-generated content moderation and privacy requirements.
