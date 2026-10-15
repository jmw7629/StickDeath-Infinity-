#!/usr/bin/env python3
"""Guard retired communication code out of every delivered surface (#260).

Native: the real build manifests, Info.plist and every built Swift source.
Cross-surface: deep-link routes, the Spatter system prompt, Android build and
manifest, the backend SQL candidates and Python services, and that the SQL
retirement candidate (security-retire-communications.sql) is in the apply order.
It does not inspect a live database (run sdi_legacy_communication_exposure there)
and does not prove connected rooms work.
"""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
RETIRED = {
    "LiveKitService.swift", "MessageService.swift", "MessagesViewModel.swift",
    "MessagesView.swift", "ChatRoomView.swift", "CallsView.swift",
    "ContactsView.swift", "VideoCallView.swift", "WatchPartyView.swift",
    "CreatorRoomView.swift",
}
# Retired sources were deleted from the tree on 2026-10-12; they must not
# return under any path, so XcodeGen's whole-folder source scan cannot pick
# them up and no exclude list is needed.
DELETED_PATHS = {
    "Services/LiveKitService.swift", "Services/LiveKit", "Services/Message",
    "ViewModels/MessagesViewModel.swift", "Views/Messages/MessagesView.swift",
    "Views/Messages/ChatRoomView.swift", "Views/Messages/CallsView.swift",
    "Views/Messages/ContactsView.swift", "Views/Messages/VideoCall",
    "Views/Messages/WatchParty", "Views/Collab/CreatorRoomView.swift",
}


# Object names the backend must never create; mirrors
# sdi_private.legacy_communication_name in backend/sql/security-retire-communications.sql.
LEGACY_NAME = re.compile(
    r"^(chats?|chat_[a-z0-9_]+|[a-z0-9_]+_chats?|messages?|message_[a-z0-9_]+|[a-z0-9_]+_messages?|direct_messages?|dms?|dm_[a-z0-9_]+"
    r"|conversations?|conversation_[a-z0-9_]+|calls?|call_[a-z0-9_]+|[a-z0-9_]+_calls?|voice_[a-z0-9_]+|video_calls?|video_call_[a-z0-9_]+"
    r"|livekit_[a-z0-9_]+|[a-z0-9_]+_livekit[a-z0-9_]*|typing_[a-z0-9_]+|watch_part(y|ies)[a-z0-9_]*)$")
RETIRED_DEPENDENCIES = re.compile(r"livekit|webrtc|stream-chat|getstream|agora|twilio|jitsi|sendbird|vonage|daily-co|pusher-chat", re.I)
# Phrases that advertise removed features as available (negations are allowed).
ADVERTISING = re.compile(r"livekit calls|voice/video flow|start (?:a )?(?:voice|video) call|open (?:the )?messenger|send (?:a )?direct message", re.I)


def legacy_name(name: str) -> bool:
    return not name.startswith("sdi_") and "spatter" not in name and bool(LEGACY_NAME.match(name))


def verify_cross_surface(root: Path = ROOT) -> None:
    # Deep links: only the auth routes exist.
    app = (root / "StickDeathInfinity/App/StickDeathInfinityApp.swift").read_text()
    routes = set(re.findall(r'case \("([a-z]+)", "(/[a-z]*)"\)', app))
    assert routes and {host for host, _ in routes} == {"auth"}, f"unexpected deep-link routes: {sorted(routes)}"
    plist = plistlib.loads((root / "StickDeathInfinity/Info.plist").read_bytes())
    schemes = {scheme for entry in plist.get("CFBundleURLTypes", []) for scheme in entry.get("CFBundleURLSchemes", [])}
    assert schemes == {"stickdeath"}, f"unexpected URL schemes: {schemes}"
    assert not {"voip", "audio"} & set(plist.get("UIBackgroundModes", [])), "call background modes present"
    # Spatter must not advertise removed communication features.
    for relative in ("StickDeathInfinity/Services/Spatter/SpatterService.swift", "StickDeathInfinity/ViewModels/SpatterAIViewModel.swift",
                     "StickDeathInfinity/Views/Onboarding/OnboardingView.swift", "StickDeathInfinity/Views/Components/AppTutorialView.swift"):
        path = root / relative
        if path.exists():
            text = path.read_text()
            # The owner approved correcting the pinned Spatter prompt (2026-10-14), so the
            # prompt is checked like every other surface again.
            hit = ADVERTISING.search(text)
            assert not hit, f"{relative} advertises a removed feature: {hit.group(0)!r}"
    # Calendar stays a read-only schedule view in the legacy Messages folder.
    calendar = (root / "StickDeathInfinity/Views/Messages/CalendarView.swift").read_text()
    assert "sdi_calendar_range" in calendar and "TextField" not in calendar and "ChatMessage" not in calendar
    assert sorted(p.name for p in (root / "StickDeathInfinity/Views/Messages").iterdir()) == ["CalendarView.swift"], "Messages folder holds more than Calendar"
    # Dependencies on every platform.
    for relative in ("Package.swift", "project.yml", "android/app/build.gradle.kts", "android/build.gradle.kts", "android/settings.gradle.kts"):
        path = root / relative
        if path.exists():
            code = "\n".join(line for line in path.read_text().splitlines() if not line.strip().startswith(("//", "#")))
            assert not RETIRED_DEPENDENCIES.search(code), f"{relative} declares a retired communication dependency"
    manifest = (root / "android/app/src/main/AndroidManifest.xml").read_text()
    assert "android.permission.RECORD_AUDIO" not in manifest and "MANAGE_OWN_CALLS" not in manifest and "READ_CONTACTS" not in manifest
    # Backend: no candidate creates a messaging/calling object; the closing candidate is installed.
    created = re.compile(r"create\s+(?:or\s+replace\s+)?(?:table|view|function|procedure)\s+(?:if\s+not\s+exists\s+)?(?:[a-z_]+\.)?([a-z0-9_]+)", re.I)
    for path in sorted((root / "backend/sql").glob("*.sql")):
        for name in created.findall(path.read_text()):
            assert not legacy_name(name.lower()), f"{path.name} creates retired communication object {name}"
    readme = (root / "backend/sql/README.md").read_text()
    order = readme.split("<!-- apply-order -->", 1)[1].split("<!-- /apply-order -->", 1)[0]
    assert "security-retire-communications.sql" in order, "SQL retirement candidate missing from the apply order"
    for path in sorted((root / "backend").rglob("*.py")):
        assert not re.search(r"^\s*(?:import|from)\s+(?:livekit|twilio|agora|stream_chat)", path.read_text(), re.M), str(path)


def verify(root: Path = ROOT) -> None:
    pbx = (root / "StickDeathInfinity.xcodeproj/project.pbxproj").read_text()
    spec = (root / "project.yml").read_text()
    # Keep this deliberately fail-closed if source membership format changes.
    sources = set(re.findall(r"/\* ([^*]+\.swift) in Sources \*/", pbx))
    assert {"StudioView.swift", "MainTabView.swift", "CollabRoomView.swift",
            "WarRoomView.swift", "WatchTogetherView.swift", "SpatterService.swift", "View+SD.swift"} <= sources
    assert not sources & RETIRED, "Retired communication source is in the app target"
    assert not re.search(r"productName\s*=\s*LiveKit|github.com/livekit/", pbx)
    assert "client-sdk-swift" not in spec
    for relative in DELETED_PATHS:
        assert not (root / "StickDeathInfinity" / relative).exists(), f"retired source returned: {relative}"
    present = {path.name for path in (root / "StickDeathInfinity").rglob("*.swift")}
    assert not present & RETIRED, "Retired communication source returned to the tree"
    assert not re.findall(r"/\* (?:%s) \*/" % "|".join(map(re.escape, sorted(RETIRED))), pbx), "project still references retired files"
    excludes = set(re.findall(r"^          - (.+)$", spec, re.M))
    assert "Views/Collab/WatchTogetherView.swift" not in excludes, "XcodeGen excludes approved shared playback"
    plist = plistlib.loads((root / "StickDeathInfinity/Info.plist").read_bytes())
    assert not {"NSMicrophoneUsageDescription",
                "NSContactsUsageDescription", "LIVEKIT_WS_URL"} & plist.keys()
    # Camera is limited to explicit still-image acquisition inside Studio.
    # Calls/rooms retain no camera or microphone path.
    assert plist.get("NSCameraUsageDescription") == "Take a still photo to preview and add to your Studio project on this device."
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
        if "AVCaptureDevice" in content or "UIImagePickerController" in content:
            assert path.relative_to(root).as_posix() == "StickDeathInfinity/Views/Studio/Panels/StudioImageImportPanel.swift", str(path)
            assert "picker.cameraCaptureMode = .photo" in content
            assert "picker.mediaTypes = [UTType.image.identifier]" in content
            assert "requestAccess(for: .audio)" not in content

        assert not re.search(r"^import LiveKit\b|\b(?:LiveKitService|MessageService)\.shared",
                             content, re.M), str(path)
    for name in ("CollabRoomView", "WarRoomView", "WatchTogetherView"):
        content = (root / f"StickDeathInfinity/Views/Collab/{name}.swift").read_text()
        assert "URLSession" not in content and ".samples" not in content
        assert "MatchmakingView()" not in content
    print("RETIRED_COMMUNICATIONS_NATIVE_BOUNDARY=PASS")
    verify_cross_surface(root)
    print("RETIRED_COMMUNICATIONS_CROSS_SURFACE=PASS (source only; live database exposure is checked with sdi_legacy_communication_exposure)")
    print("Real connected collaboration is a separate unverified gate.")


if __name__ == "__main__":
    verify()
