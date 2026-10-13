# Audio workspace entry verification

Native run 35521875012 at source a4fed965414a58421a944eb75627e85fffae40ac built the actual app and ran all 44 UI journeys: 43 passed, one failed. Welcome/guide navigation and image deletion with Cancel, Undo/Redo and cold reopen passed. The track-volume journey failed before adding audio or editing gain.

The original synthesized Audio tap was at (28.667, 709.662), while the subsequent native hierarchy placed Audio at y803.7 through y830.4. The original movie shows the new-project keyboard and then the bare Studio. This supports a layout-transition tap immediately after project creation; it does not establish a mixer failure.

The track-volume and new fade journeys now wait for the keyboard to disappear and reuse the existing bounded canvas-geometry readiness check before one normal accessibility tap. Library existence and hittability are asserted before tapping Add. No coordinate fallback, repeated tap, skipped case, expanded runner budget or weakened gain/history/persistence assertion is used. The other 43 existing journey bodies are unchanged.

All original logs, artifact checksums, application, XCResult, captures and recordings are retained privately. The changed source needs its own full native result; production PCM checks or UI definition compilation do not substitute for that result.

The guide journey passed, but its landscape-named screenshot caught an unfinished rotation. That capture must not be used to claim landscape visual acceptance; a settled orientation capture remains required.
