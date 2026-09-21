# Image-delete confirmation — issue #196

Native run 35516870053 (`3193d73c75ace4e5be9dc4f0cc36f1b371e7f1f0`) passed the app build and all production stages but failed two of 44 journeys. The image-delete journey successfully imported the real licensed dragon image and cancelled its first deletion without changing pixels. After the second confirmation tap, the image and Delete option remained in the original recording. This is preserved as a native failure, not a successful deletion.

The popup previously used the optional captured image as both its presentation
flag and its action payload, clearing the payload when SwiftUI dismissed it.
Presentation now has a separate Boolean. The captured project/revision/frame/
asset remains immutable through action dispatch and is replaced only by a new
explicit request or cleared when the tool/popup closes. SwiftUI handles action
and Cancel dismissal. The production deletion command still rejects stale
context, locked layers and cancellation, and still preserves image history.

This follows [Apple's presenting-data contract](https://developer.apple.com/documentation/SwiftUI/View/confirmationDialog(_:isPresented:titleVisibility:presenting:actions:)-9ibgk), which requires the presentation data to remain stable. The captured-data lifecycle is the code defect being corrected; its connection to this observed interaction needs the next native run.

The existing native journey now captures the screen after confirmation and
waits up to five seconds for the same Delete control to disappear. It then
retains every original assertion for actual removed/restored pixels, one-step
Undo/Redo, surviving layers and cold reopening. The wait accommodates UI
publication after dialog dismissal; it does not accept a remaining Delete
control, repeat a deletion, skip a test or change per-case/suite limits.

Production deletion/library/persistence/export checks and an iOS SDK check are
required before publication. The real native journey and independent review
remain mandatory; local compilation alone does not verify this interaction.
