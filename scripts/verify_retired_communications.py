#!/usr/bin/env python3
"""Guard retired communication code out of both native build definitions.

This checks the real manifests, not a duplicate runtime model. It does not prove
that old backend endpoints have been retired or that connected rooms work.
"""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
RETIRED = {
    "LiveKitService.swift", "MessageService.swift", "MessagesViewModel.swift",
    "MessagesView.swift", "ChatRoomView.swift", "CallsView.swift",
    "ContactsView.swift", "VideoCallView.swift", "WatchPartyView.swift",
    "CreatorRoomView.swift", "WatchTogetherView.swift",
}
EXCLUSIONS = {
    "Services/LiveKitService.swift", "Services/LiveKit", "Services/Message",
    "ViewModels/MessagesViewModel.swift", "Views/Messages/MessagesView.swift",
    "Views/Messages/ChatRoomView.swift", "Views/Messages/CallsView.swift",
    "Views/Messages/ContactsView.swift", "Views/Messages/VideoCall",
    "Views/Messages/WatchParty", "Views/Collab/CreatorRoomView.swift",
    "Views/Collab/WatchTogetherView.swift",
}


def verify(root: Path = ROOT) -> None:
    pbx = (root / "StickDeathInfinity.xcodeproj/project.pbxproj").read_text()
    spec = (root / "project.yml").read_text()
    # Keep this deliberately fail-closed if source membership format changes.
    sources = set(re.findall(r"/\* ([^*]+\.swift) in Sources \*/", pbx))
    assert {"StudioView.swift", "MainTabView.swift", "CollabRoomView.swift",
            "WarRoomView.swift", "SpatterService.swift", "View+SD.swift"} <= sources
    assert not sources & RETIRED, "Retired communication source is in the app target"
    assert not re.search(r"productName\s*=\s*LiveKit|github.com/livekit/", pbx)
    assert "client-sdk-swift" not in spec
    excludes = set(re.findall(r"^          - (.+)$", spec, re.M))
    assert EXCLUSIONS <= excludes, "XcodeGen can reintroduce retired code"
    plist = plistlib.loads((root / "StickDeathInfinity/Info.plist").read_bytes())
    assert not {"NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                "NSContactsUsageDescription", "LIVEKIT_WS_URL"} & plist.keys()
    main = (root / "StickDeathInfinity/Views/Main/MainTabView.swift").read_text()
    assert "case .rooms:" in main and "CollabRoomView()" in main
    assert "case .messages:" not in main and "MessagesView()" not in main
    helper = (root / "StickDeathInfinity/Extensions/View+SD.swift").read_text()
    assert "struct RoundedCorner: Shape" in helper and "func cornerRadius(" in helper
    # Inspect every built Swift source for a path back to retired providers.
    for path in (root / "StickDeathInfinity").rglob("*.swift"):
        if path.name not in sources:
            continue
        content = path.read_text()
        assert not re.search(r"^import LiveKit\b|\b(?:LiveKitService|MessageService)\.shared",
                             content, re.M), str(path)
    for name in ("CollabRoomView", "WarRoomView"):
        content = (root / f"StickDeathInfinity/Views/Collab/{name}.swift").read_text()
        assert "URLSession" not in content and ".samples" not in content
        assert "MatchmakingView()" not in content
    print("RETIRED_COMMUNICATIONS_NATIVE_BOUNDARY=PASS")
    print("Backend retirement and real collaboration are separate unverified gates.")


if __name__ == "__main__":
    verify()
