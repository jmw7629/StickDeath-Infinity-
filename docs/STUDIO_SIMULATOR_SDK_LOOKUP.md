# Simulator SDK lookup

Workflow 34712276604 on source 12557c3d56052f9a0377c50a6e9b6a7425c7fab1 passed the production stages and built the real iOS application for both simulator architectures. Simulator setup then stopped before device creation or UI testing. Its retained setup receipt records the SDK-version query timing out after 4.503098 seconds within its five-second command allowance, with no output and the owned child reaped. This run does not verify any native UI journey.

The SDK-version query now has one 30-second allowance, bounded by the existing 100-second overall setup deadline. Output limits, exact SDK/runtime matching, exclusive run ownership, no fallback/download and no creation retry remain unchanged. No device is reset or deleted. The receipt continues to distinguish timeout, failed exit, output overflow and incomplete capture.

All 48 local harness tests pass. The cold-lookup regression executes a real six-second child process through the production bounded-pipe collector; simulator inventory and creation remain mocked. Another regression checks the SDK allowance shrinks to the remaining overall deadline. These checks verify the harness, not an installed runtime or the actual native UI. The next exact-head macOS workflow must still build and execute the complete native journey suite.
