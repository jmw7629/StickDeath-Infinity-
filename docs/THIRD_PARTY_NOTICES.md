# Third-party notices

Consolidated from the files bundled in the native app at `e48e789`. The bundled
notice files are authoritative; this page summarises them and must be updated
whenever they change. Nothing here is a rights opinion beyond the licenses the
upstream authors published.

## Fonts

**Special Elite Regular** — `StickDeathInfinity/Resources/Fonts/SpecialElite-Regular.ttf`
Copyright (c) 2010 by Brian J. Bonislawsky DBA Astigmatic (AOETI). All rights reserved.
Apache License, Version 2.0. The app includes the unmodified font from the Google Fonts repository
(`https://github.com/google/fonts/tree/e4a915e4354d27f402ca8e8bfce7dbea89a83b60/apache/specialelite`);
font SHA-256 `a776fcb4ceb8bdf03e2967688ebdad42680de5b91a7e62c17e718ae212d14bc4`.
Bundled notice and full license text: `Resources/Licenses/SpecialElite-NOTICE.txt`,
`Resources/Licenses/SpecialElite-Apache-2.0.txt` (also mirrored for Android in
`android/app/src/main/assets/licenses/` and the website in `website/assets/SpecialElite-NOTICE.txt`).

## Ported behaviour (no third-party code files)

**ArtCraft Crafting Apps — PhotoCraft and SoundCraft** — `Resources/Licenses/ArtCraft-NOTICE.txt`
Copyright (c) 2026 ArtCraft Team and the PhotoCraft contributors; Copyright (c) 2026 ArtCraft Team
and the SoundCraft contributors. Used under the MIT License (the projects are MIT OR Apache-2.0).
The Studio ports formulas, catalogues and design tokens only:

- PhotoCraft (`https://github.com/storytold/photocraft` at `14733b522385d5f876fe59f60d1118473393b960`): layer blend-mode catalogue, order and reference formulas, layer label colours, toolbar sections and tool names, "Studio (Dark)" theme tokens — see `Models/StudioCraftLayers.swift`, `Extensions/StudioCraftTheme.swift`.
- SoundCraft (`https://github.com/storytold/soundcraft` at `776b771f59cd9ffa13e2ed38d76fbca3c13347f0`): clip fade curve shapes, balance pan law, mute/solo rule, track colour palette and solo/mute state colours — see `Models/StudioCraftAudio.swift`.

The ArtCraft name, wordmark and logos are trademarks of the ArtCraft Team and are not used by this app. StickDeath Infinity is not affiliated with or endorsed by ArtCraft. The full MIT text is in the bundled notice.

## Sound library — `Resources/StudioSounds/`

`CREDITS.txt`: "StickDeath Infinity offline sound library — 2,127 real effects. All sound assets: CC0-1.0
(https://creativecommons.org/publicdomain/zero/1.0/). Each catalogue entry retains its original creator,
publisher source URL and original/installed SHA-256. M4A files are AAC derivatives produced with Apple
afconvert; WAV files retain original bytes." `catalogue.json` holds 2,127 entries with per-sound `author`,
`sourceURL`, `license`, `originalSHA256` and installed `sha256`. Counts per source at this commit:

| Creator | Source | Sounds |
| --- | --- | --- |
| Kenney | https://kenney.nl/assets/impact-sounds | 128 |
| Kenney | https://kenney.nl/assets/interface-sounds | 100 |
| Kenney | https://kenney.nl/assets/voiceover-pack | 92 |
| Kenney | https://kenney.nl/assets/sci-fi-sounds | 73 |
| Kenney | https://kenney.nl/assets/digital-audio | 62 |
| Kenney | https://kenney.nl/assets/casino-audio | 54 |
| Kenney | https://kenney.nl/assets/rpg-audio | 51 |
| Kenney | https://kenney.nl/assets/ui-audio | 51 |
| Kenney | https://kenney.nl/assets/voiceover-pack-fighter | 46 |
| SubspaceAudio | https://opengameart.org/content/512-sound-effects-8-bit-style | 512 |
| OwlishMedia | https://opengameart.org/content/202-more-sound-effects | 202 |
| rubberduck | https://opengameart.org/content/100-cc0-metal-and-wood-sfx | 100 |
| rubberduck | https://opengameart.org/content/100-cc0-sfx | 100 |
| rubberduck | https://opengameart.org/content/100-cc0-sfx-2 | 100 |
| rubberduck | https://opengameart.org/content/80-cc0-creature-sfx | 80 |
| rubberduck | https://opengameart.org/content/80-cc0-creture-sfx-2 | 80 |
| rubberduck | https://opengameart.org/content/80-cc0-rpg-sfx | 80 |
| rubberduck | https://opengameart.org/content/50-cc0-sci-fi-sfx | 50 |
| rubberduck | https://opengameart.org/content/40-cc0-water-splash-slime-sfx | 40 |
| rubberduck | https://opengameart.org/content/30-weird-cc0-sfx | 30 |
| artisticdude | https://opengameart.org/content/rpg-sound-pack | 96 |

All CC0-1.0. Attribution is optional under CC0 and is recorded anyway.

## Image library — `Resources/StudioImages/`

`catalogue.json` (207 bundled PNGs, every one hashed) declares three licenses, each with its license
text bundled beside the catalogue (`<sha256>.txt`) and the source archive SHA-256 recorded:

| License id | Author | Source | License | Bundled license file |
| --- | --- | --- | --- | --- |
| `kenney.scribble-platformer.cc0` | Kenney | https://kenney.nl/assets/scribble-platformer | CC0-1.0 | `2ac45344…c78973.txt` |
| `kenney.scribble-platformer-expansion.cc0` | Kenney | https://kenney.nl/assets/scribble-platformer-expansion | CC0-1.0 | `e95232e2…13617d.txt` |
| `kenney.scribble-dungeons.cc0` | Kenney | https://kenney.nl/assets/scribble-dungeons | CC0-1.0 | `55b8024d…a675b5c2.txt` |

Attribution text recorded in the catalogue: "Art by Kenney (kenney.nl), CC0; attribution is optional."

Optional on-demand packs (downloaded only when the user chooses, verified by archive, sheet and license
SHA-256 before use; `remote-pack.json` and `additional-packs.json`), all by Kenney, CC0-1.0, each with
`License.txt`/`license.txt` from the upstream archive recorded by hash:

| Pack id | Title | Source |
| --- | --- | --- |
| `kenney.1-bit-scenery.v1` | 1-Bit Scenery | https://kenney.nl/assets/1-bit-pack |
| `kenney.1-bit-expansion.v1` | 1-Bit Characters and Props | https://kenney.nl/assets/1-bit-pack |
| `kenney.1-bit-platformer.v1` | 1-Bit Platformer | https://kenney.nl/assets/1-bit-platformer-pack |
| `kenney.monochrome-rpg.v1` | Monochrome RPG | https://kenney.nl/assets/monochrome-rpg |
| `kenney.micro-roguelike.v1` | Micro Roguelike | https://kenney.nl/assets/micro-roguelike |
| `kenney.smoke-particles.v1` | Smoke and Explosions | https://kenney.nl/assets/smoke-particles |

Exports list the credits of licensed images actually used in a render
(`ExportPanel.swift:141-145`, `StudioMovieExportControls.swift:105-109`).

## Software dependencies

- **supabase-swift** (`https://github.com/supabase-community/supabase-swift.git`, `upToNextMajorVersion` from 2.0.0, declared in `StickDeathInfinity.xcodeproj/project.pbxproj`). No `Package.resolved` is committed, so the exact resolved version and its license text must be read from the resolved checkout on the build Mac before release; the upstream repository publishes an MIT license at the time of writing — verify, do not assume.
- `Package.swift` still lists `livekit/client-sdk-swift`; it is **not** linked by the Xcode project and `scripts/verify_retired_communications.py` fails if it reappears. No notice is owed for an unlinked package, but the stale manifest entry should be removed in a separate change.
- Apple frameworks (SwiftUI, AVFoundation, PhotosUI, StoreKit) are covered by the Apple SDK license.

## Owner-authored and other content

- Spatter knowledge modules in `Resources/SpatterBrain/*.json` are project-authored content (`createdFor: StickDeath Infinity / Spatter AI`), not third-party assets.
- Sticker/emoji shelf uses system emoji glyphs (`StickerEmojiPanel.swift`), no bundled artwork.
- Recovered StickDeath SWFs, original sounds, extracted artwork and other reference-corpus files are research inputs only and are **not** bundled or committed (`AGENTS.md`, reference-corpus boundary).
