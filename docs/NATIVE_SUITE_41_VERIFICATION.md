# Expanded native suite and Text journey correction

Source 802880c built the native app and passed every preceding production stage.
Run 35502963713 then reached the 3,300-second UI suite deadline. Its original
raw log records 38 starts: 36 passes, one Text journey exceeding its individual
180-second allowance, and one interrupted Spatter journey. Three journeys did
not start. Split and numeric trim both passed with undo and cold reopen.

The interrupted XCResult could not export its summary or attachments; its full
original contents, raw logs, diagnostics and successfully finalized recording
are retained. These counts come from raw test events, not a complete XCResult.
The mandatory native gate remains failed.

The Text test completed its edit and pixel assertions before spending its
remaining time reopening Text solely to reset preferences. Reset now occurs
immediately after Apply while the existing popup is open. The fixture uses its
ordinary color instead of making an unrelated color-picker excursion. Every
original undo/redo, cancellation, editable-content and changed-glyph assertion
remains. The final pixel comparison also checks the result after preference reset.
No production Text behavior, per-test limit or retry policy changes.

The 36 completed durations plus prior measured durations for the other five
journeys total 3,350.804 seconds before runner overhead. The complete 41-journey
suite therefore receives a finite 3,900-second allowance within the unchanged
95-minute job. Each journey retains 180 seconds, all production stages and all
41 tests remain, and timeouts/failures still fail the native gate. A new full
native run must pass; the failed run is not reclassified or rerun unchanged.
