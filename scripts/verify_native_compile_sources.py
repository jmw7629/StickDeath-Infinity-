#!/usr/bin/env python3
"""Fail early on broken standalone Swift source lists; never substitutes for Swift compilation."""
from pathlib import Path
import re
import shlex

ROOT = Path(__file__).resolve().parents[1]
# These production types refer to each other directly. Keep the real catalogue
# in tests that compile preview sessions; a test-only stand-in would hide wiring.
DEPENDENCIES = {
    "StickDeathInfinity/Services/Storage/StudioStorageCleanup.swift": {"StickDeathInfinity/Services/StudioAudioWaveformCache.swift", "StickDeathInfinity/Services/Storage/StudioStorageBudget.swift"},
    # Community clients share one model file and one transport protocol.
    "StickDeathInfinity/Services/Social/CommunityTransport.swift": {"StickDeathInfinity/Models/CommunityModels.swift"},
    "StickDeathInfinity/Services/Social/FeedClient.swift": {"StickDeathInfinity/Models/CommunityModels.swift", "StickDeathInfinity/Services/Social/CommunityTransport.swift"},
    "StickDeathInfinity/Services/Social/ProfileClient.swift": {"StickDeathInfinity/Models/CommunityModels.swift", "StickDeathInfinity/Services/Social/CommunityTransport.swift"},
    "StickDeathInfinity/Services/Social/AdminOperationsClient.swift": {"StickDeathInfinity/Models/CommunityModels.swift", "StickDeathInfinity/Services/Social/CommunityTransport.swift"},
    "StickDeathInfinity/Services/Rooms/RoomsClient.swift": {"StickDeathInfinity/Models/CommunityModels.swift", "StickDeathInfinity/Services/Social/CommunityTransport.swift"},
    "StickDeathInfinity/Services/Rooms/RoomSessionCoordinator.swift": {"StickDeathInfinity/Services/Rooms/RoomsClient.swift"},
    "StickDeathInfinity/Services/WarRoom/WarRoomClient.swift": {"StickDeathInfinity/Models/CommunityModels.swift", "StickDeathInfinity/Services/Social/CommunityTransport.swift"},
    "StickDeathInfinity/Services/Challenge/ChallengeLifecycleClient.swift": {"StickDeathInfinity/Models/CommunityModels.swift", "StickDeathInfinity/Services/Social/CommunityTransport.swift"},
    # The motion-recipe suite checks every catalogued instruction example.
    "Tests/SpatterMotionRecipe/main.swift": {
        "StickDeathInfinity/Services/Spatter/SpatterKnowledgeBase.swift",
    },
    # The planner suite routes every catalogue example and executes typed commands.
    "Tests/SpatterPlanner/main.swift": {
        "StickDeathInfinity/Services/Spatter/SpatterKnowledgeBase.swift",
        "StickDeathInfinity/Services/Spatter/SpatterStudioControlRegistry.swift",
        "StickDeathInfinity/Models/SpatterMotionRecipe.swift",
        "StickDeathInfinity/Models/StudioCommands.swift",
    },
    "StickDeathInfinity/Services/StudioAudioPreviewSession.swift": {
        "StickDeathInfinity/Services/StudioSoundCatalogue.swift",
        "StickDeathInfinity/Services/StudioAudioImportService.swift",
    },
    # AudioFadeEnvelope, CanvasLayer and their consumers use the ArtCraft ports.
    "StickDeathInfinity/Models/Models.swift": {
        "StickDeathInfinity/Models/StudioCraftAudio.swift",
        "StickDeathInfinity/Models/StudioCraftLayers.swift",
    },
    "StickDeathInfinity/Services/StudioSoundCatalogue.swift": {
        "StickDeathInfinity/Services/StudioAudioImportService.swift",
        "StickDeathInfinity/Services/StudioSoundCredits.swift",
    },
    # Wave 3 media logic (#191, #192, #177, #180): Foundation-only files that the
    # AVFoundation services now call. A step that compiles the service without
    # them fails on macOS, so the dependency is declared here.
    "StickDeathInfinity/Services/StudioAudioImportService.swift": {
        "StickDeathInfinity/Services/StudioAudioWaveformCache.swift",
    },
    "StickDeathInfinity/Services/StudioAudioTimelineSession.swift": {
        "StickDeathInfinity/Services/StudioAudioTimelineLogic.swift",
    },
    "StickDeathInfinity/Services/StudioMovieExportService.swift": {
        "StickDeathInfinity/Services/StudioSoundCredits.swift",
    },
    "StickDeathInfinity/Services/StudioMuxCapture.swift": {
        "StickDeathInfinity/Services/StudioSoundCredits.swift",
    },
    "StickDeathInfinity/Services/StudioAudioVideoMuxService.swift": {
        "StickDeathInfinity/Services/StudioSoundCredits.swift",
    },
    # Headless daily-draft renderer (#212): the job/planning half and the
    # macOS export half compile together with the production planner and exporter.
    "Tools/SpatterDraftRenderer/main.swift": {
        "Tools/SpatterDraftRenderer/SpatterDraftRenderJob.swift",
        "StickDeathInfinity/Services/StudioMovieExportService.swift",
    },
    "Tools/SpatterDraftRenderer/SpatterDraftRenderJob.swift": {
        "StickDeathInfinity/Models/SpatterMotionRecipe.swift",
        "StickDeathInfinity/Models/StudioCommands.swift",
        "StickDeathInfinity/Models/StudioDocument.swift",
    },
    "StickDeathInfinity/Services/StudioMovieExportSession.swift": {
        "StickDeathInfinity/Services/StudioSoundCredits.swift",
        "StickDeathInfinity/Services/StudioSoundCatalogue.swift",
    },
}


def verify(workflow: str, root: Path = ROOT) -> int:
    commands = re.findall(r"(?m)^\s*swiftc\s+[^\n]+", workflow.replace("\\\n", " "))
    if not commands:
        raise ValueError("No standalone Swift compilation commands found")
    for index, command in enumerate(commands, 1):
        sources = [token for token in shlex.split(command) if token.endswith(".swift")]
        if not sources:
            # Version diagnostics do not compile source.
            if shlex.split(command) == ["swiftc", "--version"]:
                continue
            raise ValueError(f"Swift command {index} has no explicit source list")
        if len(sources) != len(set(sources)):
            raise ValueError(f"Swift command {index} repeats a source file")
        for source in sources:
            path = root / source
            if Path(source).is_absolute() or ".." in Path(source).parts or not path.is_file():
                raise ValueError(f"Swift command {index} has an invalid source: {source}")
            missing = DEPENDENCIES.get(source, set()) - set(sources)
            if missing:
                raise ValueError(f"Swift command {index}: {source} requires {', '.join(sorted(missing))}")
    return len(commands)


if __name__ == "__main__":
    count = verify((ROOT / ".github/workflows/spatter-client-verify.yml").read_text())
    print(f"NATIVE_COMPILE_SOURCE_LISTS=PASS ({count} commands; native compilation remains required)")
