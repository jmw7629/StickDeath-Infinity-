# Selected audio clip duplication

The Audio inspector adds **Duplicate after** for a selected managed clip. It appends a fresh clip identity immediately after that clip on the same track, preserving source offset, duration, volume, mute state and the managed asset ID. Source audio bytes and existing clips are unchanged; overlapping neighbors retain normal mixing semantics.

The shared typed view-model operation captures the project, document revision and canonical selected clip. Idle-project, source-availability, cancellation and exact-context checks surround the atomic edit. Production validation enforces the existing 128-clip and timeline-placement bounds. Undo/Redo retains the source needed by either history state. The operation is available to typed native callers; general remote Spatter audio planning remains unfinished.

## Local evidence

- 22 production AudioTimeline groups pass using Xcode 26.3 / Swift 6.2.4. Five new groups verify fresh identity and retained metadata, actual device-storage save/cold reopen and byte equality, one Undo/Redo, stale/unselected/wrong-project/playback rejection, both cancellation points, clip/timeline bounds, and decoded stereo samples from adjacent trimmed copies with exact gain and silent gaps. The 17 existing production playback/timing/trim/ownership groups also pass.
- The iOS 26.2 SDK context check passes with five primary implementation bodies (including the corrected tool popup) and 120 source inputs. All input hashes match the candidate. Earlier invocations with the reused module cache failed resolving `FileManager.default`, including on unchanged public source. With only a fresh private module-cache path, that source passes in 119.25 seconds; the final five-body popup check also passes. Original failures and the original cache are preserved; no speculative service edit remains.
- 39 native UI journey definitions compile. The new journey uses a real licensed bundled sound and asserts duplicate placement and counts, Undo/Redo, actual mixed-player completion, and save/cold reopen. **Its native runtime has not run.**
- Actual local Xcode builds against generic iOS and the existing simulator both stop before compilation because the required platform component is unavailable. Both original result bundles are preserved. These attempts are not successful app builds.
- Source/security/retired-communications gates and independent exact-source review are recorded separately. Author review is not independent review.

No schema, Xcode membership, dependency, source asset or paid-service change. Native runtime, physical-device interaction and independent review remain pending. This bounded slice does not complete the overall audio acceptance issue.
