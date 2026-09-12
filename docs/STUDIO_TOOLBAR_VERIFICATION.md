# Floating Studio toolbar

The white Studio tool rail can be dragged by its fixed grip to either canvas edge, where it becomes vertical. Moving it into the canvas restores horizontal orientation. Rotation clamps the rail to the usable workspace. The small right dock now shows settings, color or Hand/Zoom controls only for the applicable selected tool. Its close button has a 44-point touch target; selecting the same tool restores it. Drawing tool definitions and document/history operations remain unchanged.

The production geometry and context model passed 13 local test groups, including 1,440 bounded placement/drag samples. Source security, integration-reference checks and Git whitespace checks passed. Two new Swift sources are explicit members of the app target, and the production geometry suite is part of native CI.

A new real UI journey exercises left/right docking, undocking, dismissal, same-tool restoration, Picker hiding the dock and zoom/fit without adding undo history. The existing landscape journey selects Hand before accessing its contextual FIT control. These runtime checks remain pending until the exact proposed commit completes native CI.

The original five-file toolbar foundation received an author-separated source review. Final accessibility, Xcode membership and test integration were performed by the coordinator after the owner requested single-agent work. No independent approval of those final additions or native runtime pass is claimed here.

This change implements workspace controls. It does not complete unfinished fill, selection, text, effects, audio or media operations.
