# Preserve completed native test evidence

Run 34755587788 on source `d6d6e64b1ef158f90ce75b17e0e6cf3fdebc3b15` built the actual app and passed every production stage. Its original UI log reports 22 tests, zero failures, in 1696.324 seconds; Xcode's test process exited successfully. The new Forward/Back journey passed in 100.131 seconds, including real overlap pixels, Undo/Redo and save/cold reopen. The other 21 journeys also passed.

The native job is still **cancelled**, not green. The successful UI/recording receipt appeared at 12:58:00 UTC. At 12:58:17 UTC the 65-minute outer job limit interrupted attachment/summary finalization. The artifact contains the original successful UI log, recording receipt, source configuration, attachments and result bundle; the summary export was not reached. This outcome is not relabelled as a successful mandatory check.

The original artifact (10318605382) is retained and verified: 328,399,957 bytes, SHA-256 `5f337b970f92368f3dd4cf2e4a4c702a9a5585cc033fa9dbcb40e25c4db8b1c3`, 449 entries, valid CRCs and safe paths. Its 248,622,484-byte MP4 decodes at 1206×2622 and lasts 1767.675 seconds. The original raw job log is 2,705,379 bytes with SHA-256 `6446478ade5faa592f5dacbf629ab42ca7ce45b9f77a9ffbfe67e38c7f1d9e7e`. All five public service settings were blank; this preflight did not measure network traffic.

The outer native job now has a 75-minute bound. The UI suite remains bounded at 1860 seconds, each journey at 180 seconds, one simulator and two Xcode build jobs. No assertion, individual timeout, suite deadline, required production stage or evidence gate is weakened. The extra outer allowance accounts for preceding production compilation, app/test builds, simulator setup and evidence finalization, which the observed run could not finish within 65 minutes.

The next source also carries the already tested selection Flip operation and natural-height popup, preserving the same controls and sole dismissible options popup. Their 73 production regression checks, iOS SDK context and 23 compiled UI definitions retain identical inputs. They are tested together because they modify the same Move popup; this adds one native journey to the 22 that actually passed. Their native execution remains pending on the next exact source. Selection Copy/Paste is a separate private candidate and is not included here.

The original failed selector run and this cancelled finalization run remain in the evidence history. Independent release approval is still required; these results do not authorize merging a red mandatory check.
