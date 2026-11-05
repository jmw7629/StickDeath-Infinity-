import Foundation

/// The on-device model proposes text, never authority. Production grammar parsers
/// turn one proposal into bounded typed commands; only the existing edit session
/// may commit them after the person reviews and explicitly applies the draft.
enum SpatterOnDevicePlan {
    static let maximumBriefBytes = 2048
    static let maximumInstructionBytes = 1024

    enum Failure: LocalizedError {
        case invalidBrief, invalidProposal, unsupported, duration
        var errorDescription: String? {
            switch self {
            case .invalidBrief: return "Describe a Studio edit in at most 2,048 UTF-8 bytes. Your brief was kept."
            case .invalidProposal: return "The on-device proposal exceeded the instruction limit or contained invalid text. Nothing changed."
            case .duration: return "On-device scene drafts currently support 0.5–10 seconds. Nothing changed."
            case .unsupported: return "The on-device model could not express this request as a supported local edit. Nothing changed; use the existing instruction examples."
            }
        }
    }

    static func validateBrief(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, text.utf8.count <= maximumBriefBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) else { throw Failure.invalidBrief }
        return value
    }

    /// This small initial surface deliberately excludes export, downloads, source
    /// rights changes, deletion, shell/admin operations and permission changes.
    /// No batch can smuggle an additional grammar through this allowlist.
    static func prepare(_ proposal: String, in context: StudioCommandContext,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard !proposal.isEmpty, proposal.utf8.count <= maximumInstructionBytes,
              !proposal.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidProposal }
        guard let kind = SpatterInstructionRouter.classify(proposal) else { throw Failure.unsupported }
        let request: StudioCommandRequest
        switch kind {
        case .multiClauseBrief:
            let brief = try SpatterMultiClauseBrief.parse(proposal)
            guard brief.seconds <= 10 else { throw Failure.duration }
            request = try brief.prepare(in: context, checkCancellation: checkCancellation).prepared.request
        case .sceneBrief:
            request = try SpatterSceneBrief.parse(proposal).prepare(in: context, checkCancellation: checkCancellation).request
        case .twoActorBrief:
            let brief = try SpatterTwoActorBrief.parse(proposal)
            guard (0.5...10).contains(brief.seconds) else { throw Failure.duration }
            request = try brief.prepare(in: context, checkCancellation: checkCancellation).request
        case .shape, .grid, .onionSkin, .frameExposure, .audioTrack, .layerUpdate, .projectRename:
            request = try SpatterInstructionRouter.prepareContextOnly(proposal, kind: kind, in: context, requestID: UUID(), checkCancellation: checkCancellation)
        default: throw Failure.unsupported
        }
        try checkCancellation()
        // Exercise the same strict transport/count/geometry boundary as Apply.
        return try StudioCommandExecutor.decode(JSONEncoder().encode(request))
    }
}
