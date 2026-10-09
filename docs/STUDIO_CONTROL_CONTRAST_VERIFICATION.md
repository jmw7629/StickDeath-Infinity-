# Studio control readability — issue #264

Original native captures from `dfbfe30` exposed low-contrast Audio actions and
Text popup controls. Small labels used the dark brand red or translucent white
against dark panels. This slice improves those labels within the existing layout.

`sdStudioActionText` (`#FF6B6B`) supplies red text and icons on dark Studio
surfaces. `sdStudioSecondaryText` (`#B8B8C2`) supplies labels, timing values,
instructions and the popup close control. The original `sdRed` (`#C80000`)
remains the fill for Audio transport, selection and existing red artwork.
Tool-specific slider accents remain intact. The single popup supplies a readable
tint to inherited Text actions and the font picker.

The Audio and tool-popup diffs contain only foreground/tint changes. Bindings,
action bodies, document edits, history, disabled conditions, text, geometry,
identifiers and all 43 native test bodies are unchanged. No new test-only model,
dependency, asset or Xcode source membership is introduced.

## Measurements and checks

The production SwiftUI colors were compiled and resolved to sRGB using AppKit.
The following ratios use those values, the source-declared surface opacity and
the [W3C relative-luminance contrast method](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).
Its 4.5:1 normal-text threshold is the benchmark for this bounded measurement;
this is not a claim of complete app accessibility compliance.

| Surface | Previous red text | New red text | New secondary text |
| --- | ---: | ---: | ---: |
| Audio workspace | 3.190:1 | 6.985:1 | 9.851:1 |
| Selected clip inspector | 3.077:1 | 6.738:1 | 9.504:1 |
| Numeric trim editor | 2.814:1 | 6.162:1 | 8.690:1 |
| Audio category | 3.139:1 | 6.873:1 | 9.693:1 |
| Audible clip card | 2.894:1 | 6.338:1 | 8.939:1 |
| Tool popup over white canvas | 2.700:1 | 5.913:1 | 8.340:1 |
| Popup secondary surface | 2.133:1 | 4.671:1 | 6.588:1 |

Unrounded values meet the benchmark in all seven measured contexts. Previously,
40%-white labels measured 3.443–3.827:1 in these contexts. The production fill
color is unchanged. Alpha compositing includes the popup's 98% background over
white artwork and its additional 8%-white secondary surface.

The iOS 26.2 SDK checked all three changed production bodies with 120 source
inputs successfully. A source comparison verifies that only foreground/tint
modifiers changed in the two views. Existing runtime tests are retained rather
than adding tests that merely mirror color assignments.

## Remaining verification

These are calculated production color measurements, not retouched native
screenshots. New exact-source native screenshots and the complete iOS runtime
suite remain required. Inspect enabled/disabled controls, platform pickers,
selected states, thin typewriter text, and each tool's own accent at actual size.
Dynamic Type, VoiceOver, Reduce Motion, landscape space use, iPad and physical
device acceptance remain open under #264. This slice does not close that issue
or establish independent review approval.
