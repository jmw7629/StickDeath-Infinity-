# Studio tool popup acceptance

The single floating toolbar opens the existing dismissible tool popup. This
checklist describes native interaction checks; source inspection alone does not
mark them passed.

## Line and shape controls (#147)

- Line exposes width, opacity, None/Start/End/Both arrowheads, conditional head
  length, angle snapping and ruler controls. Ruler disables angle snapping; fixed
  length reveals its independent length setting.
- Rectangle and ellipse expose their own equal-sides constraint, width, opacity
  and fill. Only rectangle exposes corner radius. Mirror remains available to
  all three tools. Reset restores the selected tool's persisted defaults.
- Verify actual drawing, a single Undo/Redo transaction, save/reopen, and exported
  PNG/MP4 at the same source revision. Confirm edits under zoom, reflection and
  layer state; cancelling an unfinished gesture must not commit artwork.

## Native interaction regression checks

- In portrait and short landscape, sliders retain a 44-point minimum control
  height within the popup's bounded scroll area. Dragging changes the bound tool
  setting, and lower controls remain reachable by scrolling.
- VoiceOver announces slider names and values with units, and Pressure
  Sensitivity/Pencil Tilt toggles retain meaningful names despite hidden visual
  labels. Adjustable controls retain the native accessibility actions.
- Move and Lasso expose the selected selection mode. Move action buttons have
  44-point minimum height; selection operations are disabled when no artwork is
  selected. Selecting artwork enables existing supported operations. Lock layers
  still requires its scope confirmation and eligibility capture.
- Closing the popup returns the canvas area without creating another toolbar.

The control sizing/accessibility patch has source review and `git diff --check`.
Device/VoiceOver and simulator interaction checks remain pending until explicitly
recorded with native evidence. Rendering/persistence tests belong to their
production suites and are not replaced by this checklist.
