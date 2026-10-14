# Publishing — wave 4 status (#174, #188, #190, #242, #245)

Source mapping and evidence only. Nothing here was uploaded, posted, charged or
deployed. Native verification is deferred to macOS CI and device acceptance (#124, #265).

| Issue | State | What exists now | Still open |
|---|---|---|---|
| #174 consent and rights | partial | Separate feed / official channel / social-marketing toggles, audience, rights declaration and terms version in `SDIRenderUploadView`; `sdi_consent_verify` before registration; `release_allowed` binds approval to digest, version, consent version and destinations; withdrawal cancels unpublished jobs (SQL 090); rights changes move published jobs to removal (SQL 020, 130). | Native verification; owner-published policy text. |
| #188 validated, moderated submissions | partial | Media probe (`backend/ingestion/media.py`), licensed-asset manifest check (`assets.py`), consent gate, owner approval for Spatter renders, and now creator-visible review states through `sdi_publish_status`. | Native screens still show the older list (below). |
| #190 bounded staging and cleanup | partial | Quotas and expiry existed; `upload-retention.sql` + `backend/publishing/cleanup.py` now delete the staging copy only after verified publication on every destination, fenced, idempotent and crash-safe. | Host scheduling of `cleanup --execute`; encrypted volume is a host responsibility (`OPERATING_RUNBOOK.md`). |
| #242 six quick-share shortcuts | partial | Export panel QUICK SHARE row: six configurable shortcuts (default YouTube, Instagram, TikTok, Facebook, X, Reddit; also Threads, Pinterest, Files, Photos), per-destination file choice, persisted per device, handing real rendered files to the iOS share sheet. Model: `StudioQuickShareDestinations.swift`; test: `Tests/StudioQuickShare`. | Direct provider APIs need the owner's developer registration and platform terms; Android parity; native compile and device acceptance (cancellation, missing apps). |
| #245 progress, cancel, retry, removal | partial | `sdi_publish_status` with one stage per job, confirmed links only, retry/cancel eligibility, removal tracking and staging-copy state; failure reasons sanitized by trigger; expired leases already reconcile on claim. | Wire native `PublishingJobsView` and admin to the new RPC. |

## Patches outside the publishing ownership

1. `backend/sql/tests/080_rls_review.sql` — add `'sdi_publication_release_candidates'`
   after `'sdi_provision_owner'` and `'sdi_release_published_upload'` after
   `'sdi_register_upload'` in `service_expected` (the service-only surface list).
2. `backend/sql/dist/sdi-backend-install.sql` — regenerate with
   `python3 scripts/backend/build_install_bundle.py` after merging.
3. `.github/workflows/spatter-client-verify.yml` — add a step:
   `swiftc -swift-version 5 -parse-as-library StickDeathInfinity/Views/Studio/Panels/StudioQuickShareDestinations.swift Tests/StudioQuickShare/main.swift -o /tmp/sdi-studio-quick-share && timeout 60s /tmp/sdi-studio-quick-share`
4. `StickDeathInfinity/Views/Profile/ProfileView.swift` (`PublishingJobsView`) — call
   `sdi_publish_status` and show `stage`, `server_copy` and `review_state` per review;
   offer Retry only when `can_retry`, Cancel/Request removal only when `can_cancel`, and
   a link only from `result_url`.
