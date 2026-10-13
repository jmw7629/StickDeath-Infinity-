# StickDeath blood and impact primitives — style spec v1 (#280)

Status: implemented as a deterministic, reusable primitive
(`SpatterImpactPrimitive` in `StickDeathInfinity/Models/SpatterMotionRecipe.swift`)
with golden-fingerprint tests in `Tests/SpatterPlanner`. The numbers below are
the shipped starting values. **Creative tuning is owner-managed ⭐**: changing a
palette, speed or pooling value is a deliberate decision that also updates the
pinned fingerprints (`Golden.impactBlood`, `Golden.explosionBrief`). No recovered
SWF, extracted artwork or copied asset is used anywhere; every stroke is generated.

## Inputs

| Field | Meaning | Range |
| --- | --- | --- |
| `seed` | SplitMix64 seed; same seed → identical geometry on every platform (coordinates quantized to 1/64 pt) | any `UInt64` |
| `origin` | Impact point in canvas points | finite |
| `directionRadians` | Main spray direction; 0 = +x, −π/2 = up | finite |
| `intensity` | Particle count and speed | 0…1 (8 + 16·intensity streaks) |
| `palette` | `blood`, `spark`, `dust` | enum |
| `frameCount` / `fps` | Burst length | 2…24 frames, 1…60 FPS |
| `scale` | Reference size (the figure height); speeds and ray lengths scale with it | > 0 |
| `groundY` | Pooling baseline; `nil` disables pooling | finite or nil |

## Behaviour per frame

1. **Burst** (frames 0–1): six short rays around the origin (radius 0.08·scale,
   then 0.16·scale), 1.2× line width, palette colour 0.
2. **Streaks**: each particle flies from the origin along `direction ± spread`
   (spread 0.35–0.6 rad, narrower at high intensity) with speed 1.2–3.2·scale/s
   (×0.5–1.3 by intensity), under gravity 6·scale/s² (blood) or 3·scale/s²
   (spark, dust). Each frame draws the segment travelled since the previous
   frame; width 0.6–1.4× line width; opacity fades from 1.0 to 0.4 across the burst.
3. **Pooling** (blood only, when `groundY` is set): a streak that reaches the
   ground becomes a droplet circle on the baseline that grows from 0.5 to 1.6×
   line width over the following frames and keeps at least 35% opacity.
4. **Clipping**: every point is clamped to the canvas with the widest stroke's
   half-width; zero-length segments are dropped, never drawn as dots.

## Palettes (starting values, owner-managed)

| Palette | Colours | Gravity | Pools |
| --- | --- | --- | --- |
| blood | `#B3001B`, `#8A0014`, `#E3192E` | 6·scale | yes |
| spark | `#FFD23F`, `#FF8C1A`, `#FFF2B3` | 3·scale | no |
| dust | `#8C8C8C`, `#B5B5B5`, `#5E5E5E` | 3·scale | no |

## Layer behaviour

* Briefs put the burst on the exploding actor's own layer, so the blood is
  editable alongside the figure and `Revert Spatter edit` removes it with the
  frames it created.
* The `explodes` action shows the intact figure for the first sixth of its clause,
  then replaces it with the burst plus six limb fragments (0.15–0.25·height) that
  fly on their own seeded arcs and spin.
* Quality gates (#213) treat an exploding layer as expected limb-length variance;
  pass `generatedLayerIDs` only for intact actors.

## Not in scope

Camera moves, screen shake, sound hooks and per-hit art direction. Those remain
owner-managed creative decisions; the primitive only guarantees determinism,
bounds and editability.
