# Native Studio MP4 candidate

The existing Export panel offers animation-only H.264 MP4 with a white background. It snapshots the current editable document, raster assets and revision. Progress, cancellation, completion metadata and shared file URLs come from the actual exporter. A later edit does not change the captured revision. Changing project/account or closing Studio cancels active work.

Canonical audio or retained historical audio is rejected; no silent soundtrack removal occurs. Transparent MP4 is rejected. The bounded implementation accepts at most 240 frames, 4 megapixels per frame, 134 million aggregate frame pixels and 64 MiB of output. These are temporary implementation limits, not an entitlement policy. Video preview, mixed audio, video import, GIF and publication remain unfinished.

Output files have checked identity and ownership. Cleanup never adopts arbitrary files or deletes a replacement or unknown sidecar. Conflicts preserve evidence and report recovery. Once a URL is offered to UIKit, only the real activity completion callback releases its consumer. Unknown completion retains one bounded share lease and blocks another share; dismissing a view does not prove another app has stopped reading. The original PNG workflow is preserved.

Verification comprises 37 production exporter cases using actual Apple H.264 encode/decode, 14 session cases and 8 panel/consumer cases, plus the existing regression suites. A new simulator journey draws real content, checks transparent-export rejection, creates a white MP4, checks its receipt and opens/cancels the actual native share sheet. It performs no public upload. Exact CI results must be recorded on the pull request; source typechecking alone does not prove this journey passed.

Physical-device resource behavior, iPad share popovers, successful destination save/reopen and third-party consumer behavior remain separate gates. No signing or TestFlight verification is implied.
