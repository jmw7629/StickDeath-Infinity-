# Expanded offline sound library

The candidate catalogue contains 2,127 real CC0 sound effects in 21 categories. All 88 existing sound IDs, files and metadata are preserved. The new assets come from the verified Kenney and OpenGameArt publisher packs, with author, source URL, original and shipped SHA256, licence, duration, format and measured waveform metadata retained per sound. Recovered legacy corpus is not included.

The audio files total 98,538,127 bytes; the production JSON manifest is 7,535,180 bytes, within the existing 16 MiB cap. The production importer decoded every file and reproduced all 256 measured peaks, sample rate, channel count and duration. Newly added AAC audio was auditioned, attached twice as separate editable clips, undone/redone, saved and reopened with project-owned bytes. Integrity failures cannot attach audio or invent a receipt.

The existing library rows are already lazy. Production metadata loading previously ran synchronously when the panel appeared. On the development Mac, this 2,127-sound manifest took 641 ms to decode and validate. The panel now awaits the same production validation on a detached task; disappearance propagates cancellation and suppresses stale results. A genuine loading indicator occupies the existing library content area. Toolbars, categories, search, timeline and clip controls retain their layout.

The actual asynchronous loader took 647 ms in a separate Mac measurement while its MainActor serviced 93 scheduled ticks, with a maximum measured interval of 8.8 ms. Search across six real queries had a 9.5 ms median and 13.8 ms maximum. These are Mac framework measurements, not physical iPhone or simulator UI latency claims.

Seven production groups pass, including asynchronous content equivalence, cancellation before I/O, all actual file decodes and the full import/edit/persistence journey. The changed catalogue and SwiftUI audio panel pass the iPhone SDK check with all 120 application declarations. The current catalogue source and UI need a fresh native app/simulator run after integration. Source staging alone is not a bundled library or release.
