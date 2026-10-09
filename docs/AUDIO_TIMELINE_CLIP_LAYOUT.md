# Timeline width and short-clip access

Actual native source 4228fcf passed the audio duplication journey but its captures
showed adjacent short clips overlapping visually. A 64-point minimum card width
was wider than each clip's true time span at the default timeline scale.

The Audio workspace now renders clip width directly from duration and the same
scale used for placement, ruler, playhead and gestures. Borders remain inside
the clip. Compact cards hide controls that cannot fit; no invisible enlarged
card covers the neighboring clip. Zoom spans 50–800 percent. Large enough cards
show their existing trim handles. A 44-point clip picker gives every clip an
explicit selection route, including clips too short to tap individually. The
existing inspector provides precise trim and other operations after selection.

Zoom is transient presentation state. It never edits project duration, placement,
managed source bytes or undo history. A gesture captured at another scale is
rejected rather than applying a changed pixel-to-time conversion.

The existing native duplication journey gains real accessibility-frame bounds,
adjacent-boundary and four-times-width assertions, explicit selection through the
clip picker, and an unchanged-timing assertion. Its original Undo/Redo, real
mixed playback and save/cold-reopen assertions remain. These strengthened native
assertions must execute before claiming native verification or updating captures.
No simulator timeout, retry policy or test count is weakened.
