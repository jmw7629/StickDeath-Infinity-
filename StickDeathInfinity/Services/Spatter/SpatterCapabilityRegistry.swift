// ═══════════════════════════════════════════════════════════════════
// SpatterCapabilityRegistry — App capability lookup derived from
// real screens, actions, and StudioViewModel operations.
// Spatter uses this to answer "how do I…?" questions.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Capability Model

struct SpatterCapability: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let description: String
    let steps: [String]
    let screen: String
    let relatedTools: [String]
    let isProFeature: Bool
}

// MARK: - Registry

enum SpatterCapabilityRegistry {

    static let allCapabilities: [SpatterCapability] = studioCapabilities + exportCapabilities + socialCapabilities + collabCapabilities

    // MARK: - Studio Capabilities

    private static let studioCapabilities: [SpatterCapability] = [
        SpatterCapability(
            id: "draw_stroke", name: "Draw a Stroke", category: "Drawing",
            description: "Use the brush, pencil, or pen tool to draw on the canvas.",
            steps: ["Tap the tool strip to select a drawing tool", "Choose color from the color picker", "Drag on the canvas to draw"],
            screen: "studio", relatedTools: ["brush", "pencil", "pen", "marker"], isProFeature: false
        ),
        SpatterCapability(
            id: "add_frame", name: "Add a New Frame", category: "Timeline",
            description: "Insert a blank frame after the current frame in the timeline.",
            steps: ["Go to the timeline at the bottom", "Tap the + button to add a new frame"],
            screen: "studio", relatedTools: ["addFrame"], isProFeature: false
        ),
        SpatterCapability(
            id: "duplicate_frame", name: "Duplicate a Frame", category: "Timeline",
            description: "Clone the current frame with all its elements.",
            steps: ["Go to the timeline", "Tap the duplicate icon on the frame thumbnail"],
            screen: "studio", relatedTools: ["duplicateFrame"], isProFeature: false
        ),
        SpatterCapability(
            id: "delete_frame", name: "Delete a Frame", category: "Timeline",
            description: "Remove the current frame from the timeline.",
            steps: ["Go to the timeline", "Swipe or tap delete on the frame thumbnail"],
            screen: "studio", relatedTools: ["deleteFrame"], isProFeature: false
        ),
        SpatterCapability(
            id: "onion_skin", name: "Toggle Onion Skin", category: "Timeline",
            description: "Show previous/next frames as translucent overlays for smooth animation.",
            steps: ["Tap the onion skin icon in the timeline header", "Adjust frame count and opacity in settings"],
            screen: "studio", relatedTools: ["onionSkin"], isProFeature: false
        ),
        SpatterCapability(
            id: "add_layer", name: "Add a Layer", category: "Layers",
            description: "Create a new drawing layer for independent element control.",
            steps: ["Open the layer panel", "Tap the + button to add a layer"],
            screen: "studio", relatedTools: ["layerPanel"], isProFeature: false
        ),
        SpatterCapability(
            id: "lock_layer", name: "Lock a Layer", category: "Layers",
            description: "Prevent editing on a specific layer.",
            steps: ["Open the layer panel", "Tap the lock icon on the layer"],
            screen: "studio", relatedTools: ["layerPanel"], isProFeature: false
        ),
        SpatterCapability(
            id: "set_layer_opacity", name: "Set Layer Opacity", category: "Layers",
            description: "Adjust the transparency of a layer.",
            steps: ["Open the layer panel", "Drag the opacity slider for the layer"],
            screen: "studio", relatedTools: ["layerPanel"], isProFeature: false
        ),
        SpatterCapability(
            id: "undo", name: "Undo", category: "History",
            description: "Revert the last action.",
            steps: ["Tap the undo button in the bottom bar", "Or use a two-finger tap gesture"],
            screen: "studio", relatedTools: ["undo"], isProFeature: false
        ),
        SpatterCapability(
            id: "redo", name: "Redo", category: "History",
            description: "Re-apply an undone action.",
            steps: ["Tap the redo button in the bottom bar"],
            screen: "studio", relatedTools: ["redo"], isProFeature: false
        ),
        SpatterCapability(
            id: "playback", name: "Play Animation", category: "Timeline",
            description: "Preview the animation at the project's FPS.",
            steps: ["Tap the play button in the timeline header", "Animation loops through all frames"],
            screen: "studio", relatedTools: ["play", "timeline"], isProFeature: false
        ),
        SpatterCapability(
            id: "set_tool", name: "Select a Tool", category: "Drawing",
            description: "Switch between the 27 available drawing tools.",
            steps: ["Tap the tool in the horizontal tool strip at the top", "Each tool has its own settings panel"],
            screen: "studio", relatedTools: ["brush", "pencil", "pen", "eraser", "fill", "line", "rectangle", "circle", "text", "lasso", "wand", "arrow", "gradient", "blur", "airbrush", "neon", "calligraphy", "move", "hand", "zoom"], isProFeature: false
        ),
        SpatterCapability(
            id: "set_colors", name: "Set Stroke/Fill Colors", category: "Drawing",
            description: "Change the active drawing and fill colors.",
            steps: ["Tap the color swatch in the tool strip", "Select a color from the color picker panel", "Toggle between stroke and fill mode"],
            screen: "studio", relatedTools: ["colorPicker"], isProFeature: false
        ),
        SpatterCapability(
            id: "canvas_settings", name: "Change Canvas Size or FPS", category: "Project",
            description: "Modify the canvas dimensions and playback frame rate.",
            steps: ["Open the project settings panel", "Adjust width, height, and FPS values"],
            screen: "studio", relatedTools: ["projectSettings"], isProFeature: false
        ),
        SpatterCapability(
            id: "clear_canvas", name: "Clear Canvas", category: "Drawing",
            description: "Remove all elements from the current frame.",
            steps: ["Tap the clear/clean button or use the eraser tool", "This action can be undone"],
            screen: "studio", relatedTools: ["eraser", "clear"], isProFeature: false
        ),
        SpatterCapability(
            id: "fill_tool", name: "Fill a Region", category: "Drawing",
            description: "Flood fill an enclosed area with a color.",
            steps: ["Select the fill tool", "Tap inside the enclosed region to fill"],
            screen: "studio", relatedTools: ["fill"], isProFeature: false
        ),
        SpatterCapability(
            id: "add_audio", name: "Add Audio Clip", category: "Audio",
            description: "Add a sound effect to the timeline.",
            steps: ["Open the audio panel", "Browse the sound library", "Tap a sound to add it to the current playhead position"],
            screen: "studio", relatedTools: ["audioTimeline", "soundLibrary"], isProFeature: false
        ),
    ]

    // MARK: - Export Capabilities

    private static let exportCapabilities: [SpatterCapability] = [
        SpatterCapability(
            id: "export_mp4", name: "Export as MP4", category: "Export",
            description: "Export the animation as an MP4 video file.",
            steps: ["Tap the export button in the header bar", "Select MP4 format", "Choose quality (Standard/HD/Full HD)", "Tap Export"],
            screen: "studio", relatedTools: ["export"], isProFeature: false
        ),
        SpatterCapability(
            id: "export_gif", name: "Export as GIF", category: "Export",
            description: "Export the animation as an animated GIF.",
            steps: ["Tap the export button", "Select GIF format", "Tap Export"],
            screen: "studio", relatedTools: ["export"], isProFeature: false
        ),
        SpatterCapability(
            id: "export_share", name: "Share to Social", category: "Export",
            description: "Share the animation directly to TikTok, YouTube, or Instagram.",
            steps: ["Tap the export button", "Select a share target", "Sign in if needed", "Share"],
            screen: "studio", relatedTools: ["export"], isProFeature: true
        ),
    ]

    // MARK: - Social Capabilities

    private static let socialCapabilities: [SpatterCapability] = [
        SpatterCapability(
            id: "browse_feed", name: "Browse Home Feed", category: "Social",
            description: "View posts from other creators in the community feed.",
            steps: ["Tap the Home tab", "Scroll through posts", "Like, comment, or share"],
            screen: "home", relatedTools: [], isProFeature: false
        ),
        SpatterCapability(
            id: "create_post", name: "Create a Post", category: "Social",
            description: "Share an animation or image to the community.",
            steps: ["Tap the create button on the Home tab", "Select content to share", "Add a caption", "Post"],
            screen: "home", relatedTools: [], isProFeature: false
        ),
        SpatterCapability(
            id: "join_challenge", name: "Join a Challenge", category: "Community",
            description: "Participate in a community animation challenge.",
            steps: ["Tap the Challenges tab", "Browse active challenges", "Create and submit an entry"],
            screen: "challenges", relatedTools: [], isProFeature: false
        ),
    ]

    // MARK: - Collaboration Capabilities

    private static let collabCapabilities: [SpatterCapability] = [
        SpatterCapability(
            id: "start_call", name: "Start a Voice/Video Call", category: "Collaboration",
            description: "Start a real-time call with another creator.",
            steps: ["Go to Messages tab", "Open a chat room", "Tap the call button"],
            screen: "messages", relatedTools: ["livekit"], isProFeature: false
        ),
        SpatterCapability(
            id: "watch_together", name: "Watch Together", category: "Collaboration",
            description: "Watch an animation in sync with friends.",
            steps: ["Start a call", "Share a project link", "Playback syncs for all viewers"],
            screen: "messages", relatedTools: ["livekit", "watchTogether"], isProFeature: false
        ),
        SpatterCapability(
            id: "creator_room", name: "Creator Room", category: "Collaboration",
            description: "Open a collaborative studio space.",
            steps: ["Go to Messages", "Tap 'Creator Room'", "Invite collaborators"],
            screen: "messages", relatedTools: ["creatorRoom"], isProFeature: true
        ),
    ]

    // MARK: - Lookup

    static func search(_ query: String) -> [SpatterCapability] {
        let q = query.lowercased()
        return allCapabilities.filter {
            $0.name.lowercased().contains(q) ||
            $0.description.lowercased().contains(q) ||
            $0.category.lowercased().contains(q) ||
            $0.id.lowercased().contains(q) ||
            $0.steps.contains { $0.lowercased().contains(q) }
        }
    }

    static func forScreen(_ screen: String) -> [SpatterCapability] {
        allCapabilities.filter { $0.screen.lowercased() == screen.lowercased() }
    }

    static func byCategory(_ category: String) -> [SpatterCapability] {
        allCapabilities.filter { $0.category.lowercased() == category.lowercased() }
    }

    static func answerHowTo(_ question: String) -> String? {
        let results = search(question)
        guard let best = results.first else { return nil }
        var answer = "**\(best.name)** — \(best.description)\n\n"
        answer += "Steps:\n"
        for (i, step) in best.steps.enumerated() {
            answer += "\(i + 1). \(step)\n"
        }
        if best.isProFeature {
            answer += "\n*This is a PRO feature.*"
        }
        return answer
    }
}
