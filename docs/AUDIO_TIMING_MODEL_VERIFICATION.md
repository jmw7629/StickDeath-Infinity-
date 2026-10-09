# Shared audio timing model

The audio split change referenced the mixer from StudioViewModel. Native run
35502291401 failed in the production StudioDocument harness because that target
intentionally does not compile the mixer. The app build and 41 UI journeys did
not run; the two successful Linux jobs do not make that native gate green.

The canonical 48 kHz sample grid now belongs to the existing timeline model.
Both clip splitting and the audio mixer read that same constant. This removes
the model's service dependency without expanding harness source membership,
changing saved documents, changing rendered timing, or weakening native checks.

Verification must include the original StudioDocument source list, the real
audio timeline and mixing harnesses, and the native app and 41 simulator
journeys. Local compilation alone is not native runtime verification. The prior
4228fcf source remains separately verified with 39 passing journeys.
