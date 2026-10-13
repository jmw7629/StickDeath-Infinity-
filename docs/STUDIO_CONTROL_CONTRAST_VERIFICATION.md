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

## Token re-measurement 2026-10-12 (#264, wave 3)

Offline WCAG 2.x relative-luminance ratios of the theme tokens in
`Extensions/StudioCraftTheme.swift` and `Extensions/Color+SD.swift` against
the surfaces they are drawn on (`python3` implementation of the W3C formula;
sRGB hex values straight from source, no alpha compositing). Benchmark for
muted/faint labels and icons is the 3:1 minimum for large text and
non-text UI; 4.5:1 remains the benchmark for body copy.

| Foreground | chrome `#12121A` | card `#1A1A28` | hover `#22222F` | pressed `#2A2A3A` | sdBackground `#0A0A0A` | sdSurface2 `#1A1A1A` | sdSurfaceLight `#1E1E1E` | sdSurface3 `#222222` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `textFaint` `#6B7280` (unchanged) | 3.85 | 3.55 | 3.25 | 2.91 | 4.10 | 3.60 | 3.45 | 3.29 |
| `textDim` `#9CA3AF` | 7.34 | 6.77 | 6.18 | 5.55 | 7.80 | 6.86 | 6.57 | 6.27 |
| `sdTextMuted` **before** `#666666` | 3.24 | 2.99 | 2.73 | 2.45 | 3.45 | 3.03 | **2.90** | **2.77** |
| `sdTextMuted` **after** `#757575` | 4.04 | 3.73 | 3.41 | 3.06 | 4.30 | 3.78 | 3.62 | 3.45 |
| `sdTextSecondary` `#999999` | 6.54 | 6.03 | 5.51 | 4.94 | 6.95 | 6.11 | 5.85 | 5.58 |
| `accentText` `#FF6B6B` | 6.71 | 6.19 | 5.66 | 5.08 | 7.13 | 6.27 | 6.01 | 5.73 |
| `sdRed` `#C80000` as text | 3.07 | 2.83 | 2.58 | 2.32 | 3.26 | 2.86 | 2.74 | 2.62 |

Findings and changes:

- `StudioCraftTheme.textFaint` is already `#6B7280` (the earlier gap note
  measured the superseded `#606068`). Its only uses are the four `LayerPanel`
  rows (`LayerPanel.swift:190,216,230,240`), which draw on `card`
  (`.studioCraftCard`) or `hover` when active (`LayerPanel.swift:244`): 3.55:1
  and 3.25:1. The 2.91:1 `pressed` cell is not a shipping pairing. **No change.**
- `Color.sdTextMuted` failed 3:1 on `sdSurfaceLight` and `sdSurface3`
  (68 call sites across Spatter, auth, settings, profile, onboarding and
  components). It is now `#757575`, ≥ 3.45:1 on every `sd*` surface and ≥ 3.06:1
  on every Studio surface. It stays below 4.5:1 on purpose-neutral surfaces, so
  the token comment forbids it for body copy or essential values.
- `sdRed` as *text* is below 3:1 on every dark surface; Studio already uses
  `sdStudioActionText` (`#FF6B6B`) for red text (section above). Remaining
  `sdRed` text uses outside Studio (sign-in links, pricing emphasis) are a
  file-owner change; listed for #264, not changed here.
- Verification: `swiftc -parse` on the two token files passes; the colour
  change needs the exact-source native run and the new audit journey
  (`testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize`, contrast
  category recorded, see `docs/ACCESSIBILITY_DYNAMIC_TYPE.md`) before any
  screenshot-based claim. **DEFERRED (not run).**
