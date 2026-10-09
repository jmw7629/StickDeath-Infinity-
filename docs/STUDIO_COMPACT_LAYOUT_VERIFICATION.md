# Compact Studio popup placement

Native source 4228fcf passed interaction tests, but its original landscape
capture showed the Hand popup centered over the fitted portrait canvas. The
placement model centered the popup in the entire area beside a docked rail.

Docked popups now anchor immediately beside that rail: the leading edge for
the left rail and the trailing edge for the right rail. Horizontal floating
toolbar behavior, popup sizing, scrolling, close control, canvas dimensions,
zoom, editor history and document data are unchanged. This is the existing sole
popup, not a new secondary toolbar.

A production layout regression test requires adjacency, stage containment and
an unobscured central canvas point at three compact landscape widths and both
edges. The original placement fails this added test. Existing placement,
snapping, cancellation and bounded geometry sweep checks remain. The actual
native landscape journey additionally requires nonintersecting Hand-popup and
canvas bounds while retaining its existing FIT, size and settled geometry
checks. Native runtime and same-size capture review are separate pending gates.

The New Animation sheet also now accurately distinguishes on-device projects
and real file export from unavailable cloud publishing. This does not declare
all export formats, physical-device or connected publication acceptance done.
