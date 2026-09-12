import Foundation

/// Local command transport for the current canonical editor. This is neither a
/// provider client nor authorization to publish, send messages, or operate a host.
enum StudioCommandError: LocalizedError, Equatable {
    case malformed, unsupportedCommand, unsupportedTool, unsupportedCapability
    case wrongProject, staleRevision, limitExceeded, invalidReference, invalidGeometry
    case invalidSettings, missingSelection, cannotDeleteLastFrame, cannotMove, noHistory

    var errorDescription: String? {
        switch self {
        case .malformed: return "The Studio command request is malformed. Nothing changed."
        case .unsupportedCommand: return "That Studio command is not supported. Nothing changed."
        case .unsupportedTool: return "That tool is not implemented by the current command renderer. Nothing changed."
        case .unsupportedCapability: return "That capability is unavailable in this command interface. Nothing changed."
        case .wrongProject: return "The command belongs to a different project. Nothing changed."
        case .staleRevision: return "The project changed after this command was prepared. Refresh its context before retrying."
        case .limitExceeded: return "The Studio command exceeds the bounded edit limit. Nothing changed."
        case .invalidReference: return "A referenced frame, layer, element, or command result is unavailable. Nothing changed."
        case .invalidGeometry: return "A drawing has invalid geometry, color, or opacity. Nothing changed."
        case .invalidSettings: return "The requested settings are invalid or unsupported. Nothing changed."
        case .missingSelection: return "Deletion requires explicit existing element IDs. Nothing changed."
        case .cannotDeleteLastFrame: return "The last frame cannot be deleted. Nothing changed."
        case .cannotMove: return "The requested item cannot move in that direction. Nothing changed."
        case .noHistory: return "There is no matching undo or redo history. Nothing changed."
        }
    }
}

private struct StudioWireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private func singleCommandKey(_ decoder: Decoder) throws -> (KeyedDecodingContainer<StudioWireKey>, StudioWireKey) {
    let container = try decoder.container(keyedBy: StudioWireKey.self)
    guard container.allKeys.count == 1, let key = container.allKeys.first else { throw StudioCommandError.malformed }
    return (container, key)
}

/// A created reference resolves only within this request, to a typed result of an
/// earlier operation. It cannot address another project or a filesystem resource.
enum StudioCommandReference: Codable, Equatable {
    case id(String), created(String)
    init(from decoder: Decoder) throws {
        let (container, key) = try singleCommandKey(decoder)
        switch key.stringValue {
        case "id": self = .id(try container.decode(String.self, forKey: key))
        case "created": self = .created(try container.decode(String.self, forKey: key))
        default: throw StudioCommandError.invalidReference
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StudioWireKey.self)
        switch self {
        case .id(let value): try container.encode(value, forKey: StudioWireKey("id"))
        case .created(let value): try container.encode(value, forKey: StudioWireKey("created"))
        }
    }
}

/// Transport geometry becomes an actual DrawnElement after validation. The
/// command's explicit frame/layer reference supplies the canonical ownership.
struct StudioCommandStroke: Codable {
    let id: String
    let tool: DrawingTool
    let points: [StrokePoint]
    let color: String
    let width: Double
    let opacity: Double
    var shape: StudioShapeDescriptor? = nil
}

enum StudioCommandDirection: String, Codable { case earlier, later
    var offset: Int { self == .earlier ? -1 : 1 }
}
enum StudioCommandLock: String, Codable { case free, full, position }
enum StudioCommandBlend: String, Codable { case normal, multiply, screen, overlay, darken, lighten }

struct StudioCommandLayerSettings: Codable {
    var name: String? = nil
    var visible: Bool? = nil
    var opacity: Double? = nil
    var lock: StudioCommandLock? = nil
    var blend: StudioCommandBlend? = nil
    var glowEnabled: Bool? = nil
    var glowColor: String? = nil
}

enum StudioCommand: Codable {
    struct Draw: Codable { let frame: StudioCommandReference; let layer: StudioCommandReference; let strokes: [StudioCommandStroke] }
    struct AddFrame: Codable { let after: StudioCommandReference; let result: String }
    struct Duplicate: Codable { let source: StudioCommandReference; let result: String }
    struct Move: Codable { let target: StudioCommandReference; let direction: StudioCommandDirection }
    struct AddLayer: Codable { let name: String; let result: String }
    struct UpdateLayer: Codable { let layer: StudioCommandReference; let settings: StudioCommandLayerSettings }
    struct DeleteElements: Codable { let frame: StudioCommandReference; let elementIDs: [String] }
    struct CanvasOptions: Codable { let grid: Bool?; let onion: Bool? }

    case draw(Draw), addFrame(AddFrame), duplicateFrame(Duplicate), deleteFrame(StudioCommandReference)
    case moveFrame(Move), selectFrame(StudioCommandReference), addLayer(AddLayer), duplicateLayer(Duplicate)
    case updateLayer(UpdateLayer), moveLayer(Move), selectLayer(StudioCommandReference)
    case deleteElements(DeleteElements), canvasOptions(CanvasOptions)

    init(from decoder: Decoder) throws {
        let (container, key) = try singleCommandKey(decoder)
        switch key.stringValue {
        case "draw": self = .draw(try container.decode(Draw.self, forKey: key))
        case "addFrame": self = .addFrame(try container.decode(AddFrame.self, forKey: key))
        case "duplicateFrame": self = .duplicateFrame(try container.decode(Duplicate.self, forKey: key))
        case "deleteFrame": self = .deleteFrame(try container.decode(StudioCommandReference.self, forKey: key))
        case "moveFrame": self = .moveFrame(try container.decode(Move.self, forKey: key))
        case "selectFrame": self = .selectFrame(try container.decode(StudioCommandReference.self, forKey: key))
        case "addLayer": self = .addLayer(try container.decode(AddLayer.self, forKey: key))
        case "duplicateLayer": self = .duplicateLayer(try container.decode(Duplicate.self, forKey: key))
        case "updateLayer": self = .updateLayer(try container.decode(UpdateLayer.self, forKey: key))
        case "moveLayer": self = .moveLayer(try container.decode(Move.self, forKey: key))
        case "selectLayer": self = .selectLayer(try container.decode(StudioCommandReference.self, forKey: key))
        case "deleteElements": self = .deleteElements(try container.decode(DeleteElements.self, forKey: key))
        case "canvasOptions": self = .canvasOptions(try container.decode(CanvasOptions.self, forKey: key))
        default: throw StudioCommandError.unsupportedCommand
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StudioWireKey.self)
        switch self {
        case .draw(let value): try container.encode(value, forKey: StudioWireKey("draw"))
        case .addFrame(let value): try container.encode(value, forKey: StudioWireKey("addFrame"))
        case .duplicateFrame(let value): try container.encode(value, forKey: StudioWireKey("duplicateFrame"))
        case .deleteFrame(let value): try container.encode(value, forKey: StudioWireKey("deleteFrame"))
        case .moveFrame(let value): try container.encode(value, forKey: StudioWireKey("moveFrame"))
        case .selectFrame(let value): try container.encode(value, forKey: StudioWireKey("selectFrame"))
        case .addLayer(let value): try container.encode(value, forKey: StudioWireKey("addLayer"))
        case .duplicateLayer(let value): try container.encode(value, forKey: StudioWireKey("duplicateLayer"))
        case .updateLayer(let value): try container.encode(value, forKey: StudioWireKey("updateLayer"))
        case .moveLayer(let value): try container.encode(value, forKey: StudioWireKey("moveLayer"))
        case .selectLayer(let value): try container.encode(value, forKey: StudioWireKey("selectLayer"))
        case .deleteElements(let value): try container.encode(value, forKey: StudioWireKey("deleteElements"))
        case .canvasOptions(let value): try container.encode(value, forKey: StudioWireKey("canvasOptions"))
        }
    }
}

enum StudioCommandAction: Codable {
    case apply([StudioCommand]), undo, redo
    init(from decoder: Decoder) throws {
        let (container, key) = try singleCommandKey(decoder)
        switch key.stringValue {
        case "apply": self = .apply(try container.decode([StudioCommand].self, forKey: key))
        case "undo": guard try container.decode(Bool.self, forKey: key) else { throw StudioCommandError.malformed }; self = .undo
        case "redo": guard try container.decode(Bool.self, forKey: key) else { throw StudioCommandError.malformed }; self = .redo
        default: throw StudioCommandError.unsupportedCommand
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StudioWireKey.self)
        switch self {
        case .apply(let value): try container.encode(value, forKey: StudioWireKey("apply"))
        case .undo: try container.encode(true, forKey: StudioWireKey("undo"))
        case .redo: try container.encode(true, forKey: StudioWireKey("redo"))
        }
    }
}

struct StudioCommandRequest: Codable {
    var schemaVersion = 1
    let requestID: UUID
    let projectID: UUID
    let expectedRevision: Int
    let action: StudioCommandAction
}

struct StudioCommandReceipt {
    enum Outcome: String { case applied, unchanged, undone, redone }
    enum IdentityKind: String { case frame, layer }
    struct Identity { let kind: IdentityKind; let id: String }
    let requestID: UUID
    let projectID: UUID
    let previousRevision: Int
    let revision: Int
    let outcome: Outcome
    let created: [String: Identity]
    let createdFrameIDs: [String]
    let deletedFrameIDs: [String]
    let createdLayerIDs: [String]
    let deletedLayerIDs: [String]
    let createdElementIDs: [String]
    let deletedElementIDs: [String]
}

/// Actual editable context only. Audio assets and export are unavailable to this
/// bounded interface; this snapshot does not imply the rest of the app lacks them.
struct StudioCommandContext {
    struct Frame { let id: String; let elementCount: Int; let hasOriginalRecord: Bool }
    let projectID: UUID
    let revision: Int
    let name: String
    let width: Int
    let height: Int
    let fps: Int
    let activeFrameID: String
    let activeLayerID: String
    let frames: [Frame]
    let layers: [CanvasLayer]
    let editableAudioClips: [AudioClip]
    let supportedTools: [DrawingTool]
    let unavailableCommands = ["export", "importMedia", "audioMix", "publish", "sendMessage", "call", "shell", "admin"]

    init(document: StudioDocument) {
        projectID = document.id; revision = document.revision; name = document.name
        width = document.width; height = document.height; fps = document.fps
        activeFrameID = document.activeFrameID; activeLayerID = document.activeLayerID
        frames = document.frames.map { Frame(id: $0.id, elementCount: $0.elements.count, hasOriginalRecord: $0.rasterAssetID != nil) }
        layers = document.layers; editableAudioClips = document.audioClips
        supportedTools = StudioCommandExecutor.supportedTools
    }
}

enum StudioCommandExecutor {
    static let maximumRequestBytes = 1_048_576
    static let maximumCommands = 64
    static let maximumStrokes = 256
    static let maximumPointsPerStroke = 4096
    static let maximumInputPoints = 16_384
    static let maximumGeneratedElements = 1024
    static let maximumGeneratedPoints = 65_536
    static let supportedTools: [DrawingTool] = [.pencil, .pen, .brush, .marker, .crayon, .eraser, .line, .rectangle, .circle]

    static func decode(_ data: Data) throws -> StudioCommandRequest {
        guard data.count <= maximumRequestBytes else { throw StudioCommandError.limitExceeded }
        do {
            try validateWire(JSONSerialization.jsonObject(with: data))
            let request = try JSONDecoder().decode(StudioCommandRequest.self, from: data)
            guard request.schemaVersion == 1 else { throw StudioCommandError.unsupportedCommand }
            return request
        } catch let error as StudioCommandError { throw error }
        catch { throw StudioCommandError.malformed }
    }

    /// Reject unknown transport fields rather than quietly ignoring a future or
    /// misspelled instruction. String values remain data, never executable input.
    private static func validateWire(_ value: Any) throws {
        func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
            guard let value = value as? [String: Any], Set(value.keys).isSubset(of: keys) else { throw StudioCommandError.malformed }
            return value
        }
        func reference(_ value: Any?) throws {
            guard let value = value else { throw StudioCommandError.malformed }
            let fields = try object(value, keys: ["id", "created"])
            guard fields.count == 1 else { throw StudioCommandError.invalidReference }
        }
        let root = try object(value, keys: ["schemaVersion", "requestID", "projectID", "expectedRevision", "action"])
        guard let action = root["action"] as? [String: Any], action.count == 1, let kind = action.keys.first else { throw StudioCommandError.malformed }
        if kind == "undo" || kind == "redo" { return }
        guard kind == "apply" else { throw StudioCommandError.unsupportedCommand }
        guard let commands = action[kind] as? [Any] else { throw StudioCommandError.malformed }
        guard !commands.isEmpty, commands.count <= maximumCommands else { throw StudioCommandError.limitExceeded }
        let arguments: [String: Set<String>] = [
            "draw": ["frame", "layer", "strokes"], "addFrame": ["after", "result"],
            "duplicateFrame": ["source", "result"], "duplicateLayer": ["source", "result"],
            "moveFrame": ["target", "direction"], "moveLayer": ["target", "direction"],
            "addLayer": ["name", "result"], "updateLayer": ["layer", "settings"],
            "deleteElements": ["frame", "elementIDs"], "canvasOptions": ["grid", "onion"]
        ]
        var inputPoints = 0, strokes = 0
        for command in commands {
            guard let command = command as? [String: Any], command.count == 1, let kind = command.keys.first,
                  let body = command[kind] else { throw StudioCommandError.malformed }
            if ["selectFrame", "selectLayer", "deleteFrame"].contains(kind) { try reference(body); continue }
            guard let keys = arguments[kind] else { throw StudioCommandError.unsupportedCommand }
            let fields = try object(body, keys: keys)
            for key in ["frame", "layer", "after", "source", "target"] where keys.contains(key) { try reference(fields[key]) }
            if kind == "updateLayer" {
                guard let settings = fields["settings"] else { throw StudioCommandError.malformed }
                _ = try object(settings, keys: ["name", "visible", "opacity", "lock", "blend", "glowEnabled", "glowColor"])
            }
            if kind == "draw" {
                guard let values = fields["strokes"] as? [Any] else { throw StudioCommandError.malformed }
                guard values.count <= maximumStrokes - strokes else { throw StudioCommandError.limitExceeded }; strokes += values.count
                for value in values {
                    let stroke = try object(value, keys: ["id", "tool", "points", "color", "width", "opacity", "shape"])
                    if let shape = stroke["shape"] {
                        _ = try object(shape, keys: ["version", "fillColor", "cornerRadius"])
                    }
                    guard let points = stroke["points"] as? [Any] else { throw StudioCommandError.malformed }
                    guard points.count <= maximumPointsPerStroke, points.count <= maximumInputPoints - inputPoints else { throw StudioCommandError.limitExceeded }
                    inputPoints += points.count
                    for point in points { _ = try object(point, keys: ["x", "y", "pressure", "timestamp"]) }
                }
            }
        }
    }

    /// Non-suspending commit: the caller keeps exclusive editor ownership for the
    /// complete operation. Cancellation is polled before/through staging and just
    /// before assignment. No partial document or history reaches the live editor.
    /// Future asynchronous preparation must re-enter with a fresh revision check.
    /// Project/revision binding is not account authorization: a trusted caller
    /// must establish the user's edit permission before invoking this local API.
    @discardableResult
    static func execute(_ request: StudioCommandRequest, editor: inout StudioDocumentEditor,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandReceipt {
        try checkCancellation()
        let original = editor.document
        try checkPreconditions(request, document: original)
        var candidate = editor
        var created: [String: StudioCommandReceipt.Identity] = [:]
        var outcome: StudioCommandReceipt.Outcome
        switch request.action {
        case .apply(let commands):
            guard !commands.isEmpty, commands.count <= maximumCommands else { throw StudioCommandError.limitExceeded }
            var budget = Budget()
            for command in commands {
                try checkCancellation()
                try apply(command, editor: &candidate, created: &created, budget: &budget, checkCancellation: checkCancellation)
            }
            // Staging used the actual editor's commands; internal revision/history
            // increments are replaced with a single full-document commit below.
            var result = candidate.document
            result.revision = original.revision; result.modifiedAt = original.modifiedAt
            try result.validate()
            candidate = editor
            try candidate.change { $0 = result }
            if candidate.document != original { candidate.selectedElementIDs.removeAll() }
            outcome = candidate.document == original ? .unchanged : .applied
        case .undo:
            guard candidate.canUndo else { throw StudioCommandError.noHistory }
            candidate.undo(); outcome = .undone
        case .redo:
            guard candidate.canRedo else { throw StudioCommandError.noHistory }
            candidate.redo(); outcome = .redone
        }
        try candidate.document.validate()
        try checkCancellation()
        try checkPreconditions(request, document: editor.document)
        let receipt = receipt(request, original: original, final: candidate.document, created: created, outcome: outcome)
        editor = candidate
        return receipt
    }

    private static func checkPreconditions(_ request: StudioCommandRequest, document: StudioDocument) throws {
        guard request.schemaVersion == 1 else { throw StudioCommandError.unsupportedCommand }
        guard request.projectID == document.id else { throw StudioCommandError.wrongProject }
        guard request.expectedRevision == document.revision else { throw StudioCommandError.staleRevision }
        // Leaves room for bounded staging revisions as well as the final commit.
        guard document.revision >= 0,
              document.revision < Int.max - maximumStrokes - maximumCommands * 3 - 4 else { throw StudioCommandError.limitExceeded }
        try document.validate()
    }

    private struct Budget {
        var strokes = 0, inputPoints = 0, elements = 0, points = 0
        mutating func generate(_ values: [DrawnElement]) throws {
            guard values.count <= maximumGeneratedElements - elements else { throw StudioCommandError.limitExceeded }
            elements += values.count
            for value in values {
                guard value.points.count <= maximumGeneratedPoints - points else { throw StudioCommandError.limitExceeded }
                points += value.points.count
            }
        }
    }
    private static func resolve(_ reference: StudioCommandReference, kind: StudioCommandReceipt.IdentityKind,
                                document: StudioDocument, created: [String: StudioCommandReceipt.Identity]) throws -> String {
        let id: String
        switch reference {
        case .id(let value): id = value
        case .created(let alias):
            guard let value = created[alias], value.kind == kind else { throw StudioCommandError.invalidReference }
            id = value.id
        }
        guard !id.isEmpty, id.count <= 160,
              kind == .frame ? document.frames.contains(where: { $0.id == id }) : document.layers.contains(where: { $0.id == id }) else {
            throw StudioCommandError.invalidReference
        }
        return id
    }
    private static func validateAlias(_ alias: String, created: [String: StudioCommandReceipt.Identity]) throws {
        guard !alias.isEmpty, alias.utf8.count <= 64, created[alias] == nil,
              alias.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else {
            throw StudioCommandError.invalidReference
        }
    }
    private static func validColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 7 && bytes[0] == 35 && bytes.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    private static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 120
    }
    private static func apply(_ command: StudioCommand, editor: inout StudioDocumentEditor,
                              created: inout [String: StudioCommandReceipt.Identity], budget: inout Budget,
                              checkCancellation: () throws -> Void) throws {
        let document = editor.document
        func frame(_ reference: StudioCommandReference) throws -> String { try resolve(reference, kind: .frame, document: document, created: created) }
        func layer(_ reference: StudioCommandReference) throws -> String { try resolve(reference, kind: .layer, document: document, created: created) }
        switch command {
        case .draw(let draw):
            let frameID = try frame(draw.frame), layerID = try layer(draw.layer)
            guard !draw.strokes.isEmpty, draw.strokes.count <= maximumStrokes - budget.strokes else { throw StudioCommandError.limitExceeded }
            budget.strokes += draw.strokes.count
            for stroke in draw.strokes {
                try checkCancellation()
                guard supportedTools.contains(stroke.tool) else { throw StudioCommandError.unsupportedTool }
                guard !stroke.id.isEmpty, stroke.id.count <= 128, validColor(stroke.color),
                      stroke.width.isFinite, (0.1...1024).contains(stroke.width),
                      stroke.opacity.isFinite, (0...1).contains(stroke.opacity), !stroke.points.isEmpty else { throw StudioCommandError.invalidGeometry }
                guard stroke.points.count <= maximumPointsPerStroke, stroke.points.count <= maximumInputPoints - budget.inputPoints else { throw StudioCommandError.limitExceeded }
                budget.inputPoints += stroke.points.count
                if [.line, .rectangle, .circle].contains(stroke.tool), stroke.points.count != 2 { throw StudioCommandError.invalidGeometry }
                for (index, point) in stroke.points.enumerated() {
                    if index % 256 == 0 { try checkCancellation() }
                    guard point.x.isFinite, point.y.isFinite, (0...Double(document.width)).contains(Double(point.x)),
                          (0...Double(document.height)).contains(Double(point.y)),
                          point.pressure.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                          point.timestamp.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw StudioCommandError.invalidGeometry }
                }
                if let shape = stroke.shape {
                    do { try shape.validate(tool: stroke.tool) }
                    catch { throw StudioCommandError.invalidSettings }
                }
                let element = DrawnElement(id: stroke.id, tool: stroke.tool, points: stroke.points, color: stroke.color,
                    width: CGFloat(stroke.width), opacity: stroke.opacity, layerID: layerID, shape: stroke.shape)
                try budget.generate([element])
                try editor.commit(element, frameID: frameID)
            }
        case .addFrame(let value):
            let after = try frame(value.after); try validateAlias(value.result, created: created)
            editor.selectFrame(after); try editor.addFrame()
            created[value.result] = .init(kind: .frame, id: editor.document.activeFrameID)
        case .duplicateFrame(let value):
            let source = try frame(value.source); try validateAlias(value.result, created: created)
            try budget.generate(document.frames.first { $0.id == source }!.elements)
            editor.selectFrame(source); try editor.duplicateFrame()
            created[value.result] = .init(kind: .frame, id: editor.document.activeFrameID)
        case .deleteFrame(let reference):
            let id = try frame(reference)
            guard document.frames.count > 1 else { throw StudioCommandError.cannotDeleteLastFrame }
            try editor.deleteFrame(id)
        case .moveFrame(let value):
            let id = try frame(value.target), index = document.frames.firstIndex { $0.id == id }!
            guard document.frames.indices.contains(index + value.direction.offset) else { throw StudioCommandError.cannotMove }
            try editor.moveFrame(id, offset: value.direction.offset)
        case .selectFrame(let reference): editor.selectFrame(try frame(reference))
        case .addLayer(let value):
            try validateAlias(value.result, created: created)
            guard validName(value.name) else { throw StudioCommandError.invalidSettings }
            try editor.addLayer()
            let id = editor.document.activeLayerID
            try editor.updateLayer(id) { $0.name = value.name }
            created[value.result] = .init(kind: .layer, id: id)
        case .duplicateLayer(let value):
            let source = try layer(value.source); try validateAlias(value.result, created: created)
            for frame in document.frames { try checkCancellation(); try budget.generate(frame.elements.filter { $0.layerID == source }) }
            try editor.duplicateLayer(source)
            created[value.result] = .init(kind: .layer, id: editor.document.activeLayerID)
        case .updateLayer(let value):
            let id = try layer(value.layer), settings = value.settings
            guard settings.name.map(validName) ?? true,
                  settings.opacity.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  settings.glowColor.map(validColor) ?? true else { throw StudioCommandError.invalidSettings }
            try editor.updateLayer(id) { target in
                if let name = settings.name { target.name = name }
                if let visible = settings.visible { target.visible = visible }
                if let opacity = settings.opacity { target.opacity = opacity }
                if let lock = settings.lock { target.lockMode = lock.rawValue; target.locked = lock == .full }
                if let blend = settings.blend { target.blendMode = blend.rawValue }
                if let enabled = settings.glowEnabled { target.glowEnabled = enabled }
                if let color = settings.glowColor { target.glowColor = color }
            }
        case .moveLayer(let value):
            let id = try layer(value.target), index = document.layers.firstIndex { $0.id == id }!
            guard document.layers.indices.contains(index + value.direction.offset) else { throw StudioCommandError.cannotMove }
            try editor.moveLayer(id, offset: value.direction.offset)
        case .selectLayer(let reference): editor.selectLayer(try layer(reference))
        case .deleteElements(let value):
            let id = try frame(value.frame)
            guard !value.elementIDs.isEmpty, value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            let existing = Set(document.frames.first { $0.id == id }!.elements.map(\.id))
            guard Set(value.elementIDs).isSubset(of: existing) else { throw StudioCommandError.invalidReference }
            editor.selectFrame(id); editor.selectedElementIDs = Set(value.elementIDs); try editor.deleteSelected()
        case .canvasOptions(let value):
            guard value.grid != nil || value.onion != nil else { throw StudioCommandError.invalidSettings }
            try editor.change {
                if let grid = value.grid { $0.gridEnabled = grid }
                if let onion = value.onion { $0.onionEnabled = onion }
            }
        }
    }
    private static func receipt(_ request: StudioCommandRequest, original: StudioDocument, final: StudioDocument,
                                created: [String: StudioCommandReceipt.Identity], outcome: StudioCommandReceipt.Outcome) -> StudioCommandReceipt {
        func added(_ old: [String], _ new: [String]) -> [String] { let existing = Set(old); return new.filter { !existing.contains($0) } }
        let oldFrames = original.frames.map(\.id), newFrames = final.frames.map(\.id)
        let oldLayers = original.layers.map(\.id), newLayers = final.layers.map(\.id)
        let oldElements = original.frames.flatMap { $0.elements.map(\.id) }, newElements = final.frames.flatMap { $0.elements.map(\.id) }
        let survivingResults = created.filter { _, value in
            value.kind == .frame ? newFrames.contains(value.id) : newLayers.contains(value.id)
        }
        return .init(requestID: request.requestID, projectID: request.projectID, previousRevision: original.revision,
            revision: final.revision, outcome: outcome, created: survivingResults,
            createdFrameIDs: added(oldFrames, newFrames), deletedFrameIDs: added(newFrames, oldFrames),
            createdLayerIDs: added(oldLayers, newLayers), deletedLayerIDs: added(newLayers, oldLayers),
            createdElementIDs: added(oldElements, newElements), deletedElementIDs: added(newElements, oldElements))
    }
}
