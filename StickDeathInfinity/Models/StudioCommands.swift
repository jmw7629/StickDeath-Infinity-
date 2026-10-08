import Foundation

/// Explicit local export intent, independent of renderer and presentation ownership.
struct StudioMovieExportRequest: Equatable {
    let editRequestID: UUID
    let projectID: UUID
    let revision: Int
    let accountID: String?
}

/// Local command transport for the current canonical editor. This is neither a
/// provider client nor authorization to publish, send messages, or operate a host.
enum StudioCommandError: LocalizedError, Equatable {
    case malformed, unsupportedCommand, unsupportedTool, unsupportedCapability
    case wrongProject, staleRevision, limitExceeded, invalidReference, invalidGeometry
    case invalidSettings, missingSelection, cannotDeleteLastFrame, cannotMove, noHistory, staleClipboard

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
        case .staleClipboard: return "The copied artwork changed. Refresh the clipboard context before pasting. Nothing changed."
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
    var eraser: StudioEraserDescriptor? = nil
    var text: StudioTextDescriptor? = nil
    var brush: StudioBrushDescriptor? = nil
}

enum StudioCommandDirection: String, Codable { case earlier, later
    var offset: Int { self == .earlier ? -1 : 1 }
}
enum StudioCommandLock: String, Codable { case free, full, position, alpha }
enum StudioCommandBlend: String, Codable { case normal, multiply, screen, overlay, darken, lighten }

struct StudioCommandLayerSettings: Codable {
    var name: String? = nil
    var visible: Bool? = nil
    var opacity: Double? = nil
    var lock: StudioCommandLock? = nil
    var blend: StudioCommandBlend? = nil
    var glowEnabled: Bool? = nil
    var glowColor: String? = nil
    var glowRadius: Double? = nil
    var glowStrength: Double? = nil
}

enum StudioCommand: Codable {
    struct RenameProject: Codable { let name: String }
    struct Draw: Codable { let frame: StudioCommandReference; let layer: StudioCommandReference; let strokes: [StudioCommandStroke] }
    struct EraseSelectedElements: Codable {
        let frame: StudioCommandReference
        let layer: StudioCommandReference
        let elementIDs: [String]
        let points: [StrokePoint]
        let width: Double
        let opacity: Double
        let mode: StudioEraserMode
    }
    struct TweenFrames: Codable { let after: StudioCommandReference; let to: StudioCommandReference; let inbetweenCount: Int; let easing: StudioTweenEasing }
    struct SetFrameHold: Codable { let frame: StudioCommandReference; let ticks: Int }
    struct AddFrame: Codable { let after: StudioCommandReference; let result: String }
    struct Duplicate: Codable { let source: StudioCommandReference; let result: String }
    struct Move: Codable { let target: StudioCommandReference; let direction: StudioCommandDirection }
    struct AddLayer: Codable { let name: String; let result: String }
    struct UpdateLayer: Codable { let layer: StudioCommandReference; let settings: StudioCommandLayerSettings }
    struct DeleteElements: Codable { let frame: StudioCommandReference; let elementIDs: [String] }
    struct TranslateElements: Codable { let frame: StudioCommandReference; let elementIDs: [String]; let dx: Double; let dy: Double }
    struct ReflectElements: Codable { let frame: StudioCommandReference; let elementIDs: [String]; let axis: StudioReflectionAxis }
    struct OrderElements: Codable { let frame: StudioCommandReference; let elementIDs: [String]; let direction: StudioCommandDirection }
    struct PasteElements: Codable { let frame: StudioCommandReference; let layer: StudioCommandReference; let clipboardID: String }
    struct SelectedArtworkImage: Codable { let assetID: String; let layerID: String }
    struct TransformSelectedArtwork: Codable {
        let frame: StudioCommandReference; let elementIDs: [String]; let image: SelectedArtworkImage?
        let dx: Double; let dy: Double; let scale: Double; let rotation: Double
        let flipHorizontal: Bool; let flipVertical: Bool
    }
    struct DeleteSelectedArtwork: Codable {
        let frame: StudioCommandReference; let elementIDs: [String]; let image: SelectedArtworkImage?
    }
    struct OrderSelectedArtwork: Codable {
        let frame: StudioCommandReference; let elementIDs: [String]; let image: SelectedArtworkImage?
        let direction: StudioCommandDirection
    }
    struct TransformElements: Codable { let frame: StudioCommandReference; let elementIDs: [String]; let scaleX: Double; let scaleY: Double; let rotation: Double }
    struct UpdateText: Codable { let frame: StudioCommandReference; let elementID: String; let text: StudioTextDescriptor; let color: String; let opacity: Double }
    struct CropImage: Codable { let frame: StudioCommandReference; let assetID: String; let crop: StudioImageCrop; var layer: StudioCommandReference? = nil }
    struct RotateImage: Codable { let frame: StudioCommandReference; let assetID: String; let direction: StudioImageQuarterTurn; var layer: StudioCommandReference? = nil }
    struct ReflectImage: Codable { let frame: StudioCommandReference; let assetID: String; let axis: StudioReflectionAxis; var layer: StudioCommandReference? = nil }
    struct DeleteImage: Codable { let frame: StudioCommandReference; let assetID: String; var layer: StudioCommandReference? = nil }
    struct UpdateImagePlacement: Codable {
        let frame: StudioCommandReference
        let assetID: String
        let placement: StudioRasterPlacement
        var rotationDegrees: Double? = nil
        var layer: StudioCommandReference? = nil
    }
    struct SplitAudioClip: Codable { let clipID: String; let seconds: Double; let newClipID: String }
    struct DeleteAudioClip: Codable { let clipID: String }
    struct DuplicateAudioClip: Codable { let clipID: String; let newClipID: String }
    struct UpdateAudioClip: Codable { let clipID: String; let settings: StudioAudioClipSettings }
    struct CanvasOptions: Codable {
        let grid: Bool?
        let onion: Bool?
        let gridSettings: StudioGridSettings?
        let onionSettings: StudioOnionSettings?
        init(grid: Bool? = nil, onion: Bool? = nil, gridSettings: StudioGridSettings? = nil, onionSettings: StudioOnionSettings? = nil) {
            self.grid = grid; self.onion = onion; self.gridSettings = gridSettings; self.onionSettings = onionSettings
        }
    }

    case eraseSelectedElements(EraseSelectedElements)
    case renameProject(RenameProject)
    case cropImage(CropImage)
    case setFrameHold(SetFrameHold)
    case tweenFrames(TweenFrames)
    case splitAudioClip(SplitAudioClip), deleteAudioClip(DeleteAudioClip)
    case duplicateAudioClip(DuplicateAudioClip)
    case updateAudioClip(UpdateAudioClip)
    case draw(Draw), addFrame(AddFrame), duplicateFrame(Duplicate), deleteFrame(StudioCommandReference)
    case moveFrame(Move), selectFrame(StudioCommandReference), addLayer(AddLayer), duplicateLayer(Duplicate)
    case updateLayer(UpdateLayer), moveLayer(Move), selectLayer(StudioCommandReference), deleteLayer(StudioCommandReference)
    case deleteElements(DeleteElements), translateElements(TranslateElements), orderElements(OrderElements), reflectElements(ReflectElements), canvasOptions(CanvasOptions)
    case transformSelectedArtwork(TransformSelectedArtwork), deleteSelectedArtwork(DeleteSelectedArtwork), orderSelectedArtwork(OrderSelectedArtwork)
    case rotateImage(RotateImage), reflectImage(ReflectImage), deleteImage(DeleteImage), updateImagePlacement(UpdateImagePlacement)
    case cutElements(DeleteElements)
    case copyElements(DeleteElements), pasteElements(PasteElements), updateText(UpdateText), transformElements(TransformElements)

    init(from decoder: Decoder) throws {
        let (container, key) = try singleCommandKey(decoder)
        switch key.stringValue {
        case "eraseSelectedElements": self = .eraseSelectedElements(try container.decode(EraseSelectedElements.self, forKey: key))
        case "renameProject": self = .renameProject(try container.decode(RenameProject.self, forKey: key))
        case "cropImage": self = .cropImage(try container.decode(CropImage.self, forKey: key))
        case "tweenFrames": self = .tweenFrames(try container.decode(TweenFrames.self, forKey: key))
        case "setFrameHold": self = .setFrameHold(try container.decode(SetFrameHold.self, forKey: key))
        case "splitAudioClip": self = .splitAudioClip(try container.decode(SplitAudioClip.self, forKey: key))
        case "deleteAudioClip": self = .deleteAudioClip(try container.decode(DeleteAudioClip.self, forKey: key))
        case "duplicateAudioClip": self = .duplicateAudioClip(try container.decode(DuplicateAudioClip.self, forKey: key))
        case "updateAudioClip": self = .updateAudioClip(try container.decode(UpdateAudioClip.self, forKey: key))
        case "rotateImage": self = .rotateImage(try container.decode(RotateImage.self, forKey: key))
        case "reflectImage": self = .reflectImage(try container.decode(ReflectImage.self, forKey: key))
        case "deleteImage": self = .deleteImage(try container.decode(DeleteImage.self, forKey: key))
        case "updateImagePlacement": self = .updateImagePlacement(try container.decode(UpdateImagePlacement.self, forKey: key))
        case "transformSelectedArtwork": self = .transformSelectedArtwork(try container.decode(TransformSelectedArtwork.self, forKey: key))
        case "deleteSelectedArtwork": self = .deleteSelectedArtwork(try container.decode(DeleteSelectedArtwork.self, forKey: key))
        case "orderSelectedArtwork": self = .orderSelectedArtwork(try container.decode(OrderSelectedArtwork.self, forKey: key))
        case "transformElements": self = .transformElements(try container.decode(TransformElements.self, forKey: key))
        case "updateText": self = .updateText(try container.decode(UpdateText.self, forKey: key))
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
        case "deleteLayer": self = .deleteLayer(try container.decode(StudioCommandReference.self, forKey: key))
        case "deleteElements": self = .deleteElements(try container.decode(DeleteElements.self, forKey: key))
        case "translateElements": self = .translateElements(try container.decode(TranslateElements.self, forKey: key))
        case "reflectElements": self = .reflectElements(try container.decode(ReflectElements.self, forKey: key))
        case "orderElements": self = .orderElements(try container.decode(OrderElements.self, forKey: key))
        case "cutElements": self = .cutElements(try container.decode(DeleteElements.self, forKey: key))
        case "copyElements": self = .copyElements(try container.decode(DeleteElements.self, forKey: key))
        case "pasteElements": self = .pasteElements(try container.decode(PasteElements.self, forKey: key))
        case "canvasOptions": self = .canvasOptions(try container.decode(CanvasOptions.self, forKey: key))
        default: throw StudioCommandError.unsupportedCommand
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StudioWireKey.self)
        switch self {
        case .renameProject(let value): try container.encode(value, forKey: StudioWireKey("renameProject"))
        case .cropImage(let value): try container.encode(value, forKey: StudioWireKey("cropImage"))
        case .tweenFrames(let value): try container.encode(value, forKey: StudioWireKey("tweenFrames"))
        case .setFrameHold(let value): try container.encode(value, forKey: StudioWireKey("setFrameHold"))
        case .splitAudioClip(let value): try container.encode(value, forKey: StudioWireKey("splitAudioClip"))
        case .deleteAudioClip(let value): try container.encode(value, forKey: StudioWireKey("deleteAudioClip"))
        case .duplicateAudioClip(let value): try container.encode(value, forKey: StudioWireKey("duplicateAudioClip"))
        case .updateAudioClip(let value): try container.encode(value, forKey: StudioWireKey("updateAudioClip"))
        case .rotateImage(let value): try container.encode(value, forKey: StudioWireKey("rotateImage"))
        case .reflectImage(let value): try container.encode(value, forKey: StudioWireKey("reflectImage"))
        case .deleteImage(let value): try container.encode(value, forKey: StudioWireKey("deleteImage"))
        case .updateImagePlacement(let value): try container.encode(value, forKey: StudioWireKey("updateImagePlacement"))
        case .transformSelectedArtwork(let value): try container.encode(value, forKey: StudioWireKey("transformSelectedArtwork"))
        case .deleteSelectedArtwork(let value): try container.encode(value, forKey: StudioWireKey("deleteSelectedArtwork"))
        case .orderSelectedArtwork(let value): try container.encode(value, forKey: StudioWireKey("orderSelectedArtwork"))
        case .transformElements(let value): try container.encode(value, forKey: StudioWireKey("transformElements"))
        case .updateText(let value): try container.encode(value, forKey: StudioWireKey("updateText"))
        case .eraseSelectedElements(let value): try container.encode(value, forKey: StudioWireKey("eraseSelectedElements"))
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
        case .deleteLayer(let value): try container.encode(value, forKey: StudioWireKey("deleteLayer"))
        case .deleteElements(let value): try container.encode(value, forKey: StudioWireKey("deleteElements"))
        case .translateElements(let value): try container.encode(value, forKey: StudioWireKey("translateElements"))
        case .reflectElements(let value): try container.encode(value, forKey: StudioWireKey("reflectElements"))
        case .orderElements(let value): try container.encode(value, forKey: StudioWireKey("orderElements"))
        case .cutElements(let value): try container.encode(value, forKey: StudioWireKey("cutElements"))
        case .copyElements(let value): try container.encode(value, forKey: StudioWireKey("copyElements"))
        case .pasteElements(let value): try container.encode(value, forKey: StudioWireKey("pasteElements"))
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
    let changedAudioClipIDs: [String]
    let clipboardElementCount: Int
    let clipboardID: String?
}

/// Actual editable context only. Existing managed clip settings are supported;
/// audio asset import, rendering and export remain separate bounded interfaces.
struct StudioCommandContext {
    struct Frame {
        let id: String
        let elementCount: Int
        let durationTicks: Int
        let hasOriginalRecord: Bool
        let imageAssetID: String?
        let imageLayerID: String?
        let imagePlacement: StudioRasterPlacement?
        let imageReflection: StudioRasterReflection?
        let imageQuarterTurns: Int?
        let imageCrop: StudioImageCrop?
        var imageRotationDegrees: Double? = nil
    }
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
    let supportedAudioEdits = ["clipVolume", "clipMute", "clipFades", "clipPlacement", "clipTrim", "clipDuplicate", "clipSplit", "clipDelete"]
    let supportedTools: [DrawingTool]
    let supportedBrushFamilies = StudioBrushFamily.allCases
    let supportedTweenEasings = StudioTweenEasing.allCases
    let maximumTweenInbetweens = 24
    let gridEnabled: Bool
    let gridSettings: StudioGridSettings
    let onionEnabled: Bool
    let onionSettings: StudioOnionSettings
    let unavailableCommands = ["export", "importMedia", "audioMix", "publish", "sendMessage", "call", "shell", "admin"]

    init(document: StudioDocument) {
        projectID = document.id; revision = document.revision; name = document.name
        width = document.width; height = document.height; fps = document.fps
        gridEnabled = document.gridEnabled; gridSettings = document.gridSettings ?? .init()
        onionEnabled = document.onionEnabled; onionSettings = document.onionSettings ?? .init()
        activeFrameID = document.activeFrameID; activeLayerID = document.activeLayerID
        frames = document.frames.map { frame in
            let image = frame.preferredRasterInstance(activeLayerID: document.activeLayerID)
            return Frame(id: frame.id, elementCount: frame.elements.count, durationTicks: frame.durationTicks,
                hasOriginalRecord: frame.rasterAssetID != nil,
                imageAssetID: image.flatMap { $0.placement == nil ? nil : frame.rasterAssetID(on: $0.layerID) },
                imageLayerID: image?.placement == nil ? nil : image?.layerID,
                imagePlacement: image?.placement, imageReflection: image?.reflection,
                imageQuarterTurns: image?.quarterTurns, imageCrop: image?.crop, imageRotationDegrees: image?.rotationDegrees)
        }
        layers = document.layers; editableAudioClips = document.audioClips
        supportedTools = StudioCommandExecutor.supportedTools
    }
}

enum StudioCommandExecutor {
    static let maximumRequestBytes = 1_048_576
    static let maximumCommands = 96
    static let maximumStrokes = 512
    static let maximumPointsPerStroke = 4096
    static let maximumInputPoints = 16_384
    static let maximumGeneratedElements = 1024
    static let maximumGeneratedPoints = 65_536
    static let supportedTools: [DrawingTool] = [.pencil, .pen, .brush, .marker, .crayon, .eraser, .line, .rectangle, .circle, .text]

    /// Only these plain primitives have identical append semantics and can share
    /// one whole-document validation/history step. General tools stay unchanged.
    static func batchesPrimitiveDrawing(_ strokes: [StudioCommandStroke]) -> Bool {
        (2...32).contains(strokes.count) && strokes.allSatisfy {
            ($0.tool == .line || $0.tool == .circle) && $0.brush == nil
                && $0.shape == nil && $0.eraser == nil && $0.text == nil
                && $0.points.count == 2 && $0.points.allSatisfy { $0.pressure == nil && $0.tilt == nil }
        }
    }

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
            "cropImage": ["layer", "frame", "assetID", "crop"],
            "setFrameHold": ["frame", "ticks"],
            "tweenFrames": ["after", "to", "inbetweenCount", "easing"],
            "eraseSelectedElements": ["frame", "layer", "elementIDs", "points", "width", "opacity", "mode"],
            "renameProject": ["name"],
            "splitAudioClip": ["clipID", "seconds", "newClipID"],
            "deleteAudioClip": ["clipID"],
            "duplicateAudioClip": ["clipID", "newClipID"],
            "updateAudioClip": ["clipID", "settings"],
            "rotateImage": ["layer", "frame", "assetID", "direction"],
            "reflectImage": ["layer", "frame", "assetID", "axis"],
            "deleteImage": ["layer", "frame", "assetID"],
            "updateImagePlacement": ["layer", "frame", "assetID", "placement", "rotationDegrees"],
            "transformSelectedArtwork": ["frame", "elementIDs", "image", "dx", "dy", "scale", "rotation", "flipHorizontal", "flipVertical"],
            "deleteSelectedArtwork": ["frame", "elementIDs", "image"],
            "orderSelectedArtwork": ["frame", "elementIDs", "image", "direction"],
            "transformElements": ["frame", "elementIDs", "scaleX", "scaleY", "rotation"],
            "updateText": ["frame", "elementID", "text", "color", "opacity"],
            "draw": ["frame", "layer", "strokes"], "addFrame": ["after", "result"],
            "duplicateFrame": ["source", "result"], "duplicateLayer": ["source", "result"],
            "moveFrame": ["target", "direction"], "moveLayer": ["target", "direction"],
            "addLayer": ["name", "result"], "updateLayer": ["layer", "settings"],
            "translateElements": ["frame", "elementIDs", "dx", "dy"],
            "orderElements": ["frame", "elementIDs", "direction"],
            "reflectElements": ["frame", "elementIDs", "axis"],
            "cutElements": ["frame", "elementIDs"],
            "copyElements": ["frame", "elementIDs"], "pasteElements": ["frame", "layer", "clipboardID"],
            "deleteElements": ["frame", "elementIDs"], "canvasOptions": ["grid", "onion", "gridSettings", "onionSettings"]
        ]
        func textDescriptor(_ value: Any) throws {
            let fields = try object(value, keys: ["version", "content", "style"])
            guard let style = fields["style"] else { throw StudioCommandError.malformed }
            _ = try object(style, keys: ["font", "size", "alignment", "bold", "italic", "boxWidth", "boxHeight", "rotation"])
        }
        var inputPoints = 0, strokes = 0
        for command in commands {
            guard let command = command as? [String: Any], command.count == 1, let kind = command.keys.first,
                  let body = command[kind] else { throw StudioCommandError.malformed }
            if ["selectFrame", "selectLayer", "deleteFrame", "deleteLayer"].contains(kind) { try reference(body); continue }
            guard let keys = arguments[kind] else { throw StudioCommandError.unsupportedCommand }
            let fields = try object(body, keys: keys)
            for key in ["frame", "layer", "after", "to", "source", "target"] where keys.contains(key) {
                if key == "layer", ["cropImage", "rotateImage", "reflectImage", "deleteImage", "updateImagePlacement"].contains(kind), fields[key] == nil { continue }
                try reference(fields[key])
            }
            if ["transformSelectedArtwork", "deleteSelectedArtwork", "orderSelectedArtwork"].contains(kind), let image = fields["image"], !(image is NSNull) {
                _ = try object(image, keys: ["assetID", "layerID"])
            }
            if kind == "canvasOptions" {
                if let settings = fields["gridSettings"] { _ = try object(settings, keys: ["spacing", "opacity", "tint"]) }
                if let settings = fields["onionSettings"] { _ = try object(settings, keys: ["previousCount", "nextCount", "opacity", "tinted"]) }
            }
            if kind == "updateAudioClip" {
                guard let settings = fields["settings"] else { throw StudioCommandError.malformed }
                let values = try object(settings, keys: ["volume", "isMuted", "fades", "placement", "trim"])
                if let trim = values["trim"] {
                    _ = try object(trim, keys: ["sourceOffset", "duration"])
                }
                if let placement = values["placement"] {
                    _ = try object(placement, keys: ["startTime", "track"])
                }
                if let fades = values["fades"] {
                    _ = try object(fades, keys: ["fadeIn", "fadeOut"])
                }
            }
            if kind == "cropImage" {
                guard let crop = fields["crop"] else { throw StudioCommandError.malformed }
                _ = try object(crop, keys: ["x", "y", "width", "height"])
            }
            if kind == "updateImagePlacement" {
                guard let placement = fields["placement"] else { throw StudioCommandError.malformed }
                _ = try object(placement, keys: ["x", "y", "width", "height"])
            }
            if kind == "updateLayer" {
                guard let settings = fields["settings"] else { throw StudioCommandError.malformed }
                _ = try object(settings, keys: ["name", "visible", "opacity", "lock", "blend", "glowEnabled", "glowColor", "glowRadius", "glowStrength"])
            }
            if kind == "updateText" { guard let text = fields["text"] else { throw StudioCommandError.malformed }; try textDescriptor(text) }
            if kind == "eraseSelectedElements" {
                guard let points = fields["points"] as? [Any] else { throw StudioCommandError.malformed }
                guard points.count <= maximumPointsPerStroke, points.count <= maximumInputPoints - inputPoints,
                      strokes < maximumStrokes else { throw StudioCommandError.limitExceeded }
                inputPoints += points.count; strokes += 1
                for point in points {
                    let fields = try object(point, keys: ["x", "y", "pressure", "timestamp", "tilt"])
                    if let tilt = fields["tilt"] { _ = try object(tilt, keys: ["altitude", "azimuth"]) }
                }
            }
            if kind == "draw" {
                guard let values = fields["strokes"] as? [Any] else { throw StudioCommandError.malformed }
                guard values.count <= maximumStrokes - strokes else { throw StudioCommandError.limitExceeded }; strokes += values.count
                for value in values {
                    let stroke = try object(value, keys: ["id", "tool", "points", "color", "width", "opacity", "shape", "eraser", "text", "brush"])
                    if let text = stroke["text"] { try textDescriptor(text) }
                    if let brush = stroke["brush"] {
                        let fields = try object(brush, keys: ["version", "family", "seed", "smoothing", "pressureEnabled", "tipAngleDegrees", "texture", "grain", "gradientEndColor", "tiltEnabled"])
                        if let endpoint = fields["gradientEndColor"] { _ = try object(endpoint, keys: ["red", "green", "blue", "alpha"]) }
                    }
                    if let eraser = stroke["eraser"] {
                        _ = try object(eraser, keys: ["version", "mode"])
                    }
                    if let shape = stroke["shape"] {
                        _ = try object(shape, keys: ["version", "fillColor", "cornerRadius", "arrowEnds", "arrowLength"])
                    }
                    guard let points = stroke["points"] as? [Any] else { throw StudioCommandError.malformed }
                    guard points.count <= maximumPointsPerStroke, points.count <= maximumInputPoints - inputPoints else { throw StudioCommandError.limitExceeded }
                    inputPoints += points.count
                    for point in points {
                        let fields = try object(point, keys: ["x", "y", "pressure", "timestamp", "tilt"])
                        if let tilt = fields["tilt"] { _ = try object(tilt, keys: ["altitude", "azimuth"]) }
                    }
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
        let originalClipboardVersion = editor.clipboardVersion
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
            let stagedClipboard = candidate
            candidate = editor
            try candidate.change { $0 = result }
            try candidate.adoptClipboard(from: stagedClipboard)
            // These operations preserve the same selection as their manual paths.
            // A mixed batch containing any other operation keeps existing clearing semantics.
            let preservesSelection = commands.allSatisfy {
                switch $0 {
                case .renameProject, .eraseSelectedElements: return true
                default: return false
                }
            }
            if candidate.document != original && !preservesSelection { candidate.selectedElementIDs.removeAll() }
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
        guard editor.clipboardVersion == originalClipboardVersion else { throw StudioCommandError.staleClipboard }
        let receipt = receipt(request, original: original, final: candidate.document, created: created, outcome: outcome,
                              clipboardElementCount: candidate.clipboardElementCount,
                              clipboardID: candidate.clipboardElementCount > 0 ? candidate.clipboardVersion.uuidString : nil)
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
                let masks = value.selectionErasures ?? []
                guard masks.count <= maximumGeneratedElements - elements else { throw StudioCommandError.limitExceeded }
                elements += masks.count
                guard value.points.count <= maximumGeneratedPoints - points else { throw StudioCommandError.limitExceeded }
                points += value.points.count
                for mask in masks {
                    guard mask.points.count <= maximumGeneratedPoints - points else { throw StudioCommandError.limitExceeded }
                    points += mask.points.count
                }
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
    static func isValidLayerName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 120 &&
        value.utf8.count <= 4096 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static func apply(_ command: StudioCommand, editor: inout StudioDocumentEditor,
                              created: inout [String: StudioCommandReceipt.Identity], budget: inout Budget,
                              checkCancellation: () throws -> Void) throws {
        let document = editor.document
        func frame(_ reference: StudioCommandReference) throws -> String { try resolve(reference, kind: .frame, document: document, created: created) }
        func layer(_ reference: StudioCommandReference) throws -> String { try resolve(reference, kind: .layer, document: document, created: created) }
        func imageLayer(_ reference: StudioCommandReference?, frame referenceFrame: StudioCommandReference, assetID: String) throws -> String {
            let id = try frame(referenceFrame)
            guard let selected = document.frames.first(where: { $0.id == id }) else {
                throw StudioCommandError.invalidReference
            }
            let instance: StudioRasterLayerInstance?
            if let reference { instance = selected.rasterInstance(on: try layer(reference)) }
            else { instance = selected.rasterLayerInstances.count == 1 ? selected.rasterLayerInstances.first : nil }
            guard let instance, instance.placement != nil, selected.rasterAssetID(on: instance.layerID) == assetID else { throw StudioCommandError.invalidReference }
            return instance.layerID
        }
        switch command {
        case .renameProject(let value):
            try editor.renameProject(value.name)
        case .splitAudioClip(let value):
            try editor.splitAudioClip(value.clipID, at: value.seconds, newClipID: value.newClipID)
        case .deleteAudioClip(let value):
            try editor.deleteAudioClip(value.clipID)
        case .duplicateAudioClip(let value):
            try editor.duplicateAudioClip(value.clipID, newClipID: value.newClipID)
        case .updateAudioClip(let value):
            try editor.updateAudioClip(value.clipID, settings: value.settings)
        case .eraseSelectedElements(let value):
            // Erasure is explicitly bound to existing identities, never aliases
            // created by an earlier command or a silently changed selection.
            guard case .id = value.frame, case .id = value.layer else { throw StudioCommandError.invalidReference }
            let frameID = try frame(value.frame), layerID = try layer(value.layer)
            guard !value.elementIDs.isEmpty, value.elementIDs.count <= 256,
                  Set(value.elementIDs).count == value.elementIDs.count,
                  value.elementIDs.allSatisfy({ !$0.isEmpty && $0.count <= 160 }) else { throw StudioCommandError.missingSelection }
            guard Set(value.elementIDs) == editor.selectedElementIDs else { throw StudioCommandError.missingSelection }
            guard !value.points.isEmpty, value.points.count <= maximumPointsPerStroke,
                  value.points.count <= maximumInputPoints - budget.inputPoints,
                  budget.strokes < maximumStrokes,
                  value.elementIDs.count <= maximumGeneratedElements - budget.elements,
                  value.points.count <= (maximumGeneratedPoints - budget.points) / value.elementIDs.count else {
                throw StudioCommandError.limitExceeded
            }
            for (index, point) in value.points.enumerated() {
                if index % 256 == 0 { try checkCancellation() }
                guard point.x.isFinite, point.y.isFinite,
                      (0...Double(document.width)).contains(Double(point.x)),
                      (0...Double(document.height)).contains(Double(point.y)),
                      point.pressure.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                      point.timestamp.map({ $0.isFinite && $0 >= 0 }) ?? true,
                      point.tilt?.isValid ?? true else { throw StudioCommandError.invalidGeometry }
            }
            budget.strokes += 1; budget.inputPoints += value.points.count
            budget.elements += value.elementIDs.count; budget.points += value.points.count * value.elementIDs.count
            let eraser = DrawnElement(id: "typed-selected-erasure", tool: .eraser,
                points: value.points, color: "#000000", width: value.width, opacity: value.opacity,
                fillColor: nil, layerID: layerID, eraser: .init(mode: value.mode))
            try editor.eraseSelectedElements(eraser, frameID: frameID,
                elementIDs: Set(value.elementIDs), checkCancellation: checkCancellation)
        case .draw(let draw):
            let frameID = try frame(draw.frame), layerID = try layer(draw.layer)
            guard !draw.strokes.isEmpty, draw.strokes.count <= maximumStrokes - budget.strokes else { throw StudioCommandError.limitExceeded }
            budget.strokes += draw.strokes.count
            let batched = batchesPrimitiveDrawing(draw.strokes)
            var primitives: [DrawnElement] = []
            for stroke in draw.strokes {
                try checkCancellation()
                guard stroke.tool != .text || stroke.text != nil else { throw StudioCommandError.invalidSettings }
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
                if let brush = stroke.brush {
                    guard [.pencil, .pen, .brush, .marker, .crayon].contains(stroke.tool),
                          stroke.shape == nil, stroke.eraser == nil, stroke.text == nil else { throw StudioCommandError.invalidSettings }
                    do { _ = try brush.settings(width: stroke.width, opacity: stroke.opacity) }
                    catch { throw StudioCommandError.invalidSettings }
                } else if stroke.points.contains(where: { $0.tilt != nil }) { throw StudioCommandError.invalidSettings }
                if let shape = stroke.shape {
                    do { try shape.validate(tool: stroke.tool) }
                    catch { throw StudioCommandError.invalidSettings }
                }
                let element = DrawnElement(id: stroke.id, tool: stroke.tool, points: stroke.points, color: stroke.color,
                    width: CGFloat(stroke.width), opacity: stroke.opacity, layerID: layerID, brush: stroke.brush, shape: stroke.shape, eraser: stroke.eraser, text: stroke.text)
                try budget.generate([element])
                if batched { primitives.append(element) }
                else { try editor.commit(element, frameID: frameID) }
            }
            if batched { try editor.commitCommandPrimitives(primitives, frameID: frameID, checkCancellation: checkCancellation) }
        case .updateText(let value):
            try editor.updateText(frameID: frame(value.frame), elementID: value.elementID,
                text: value.text, color: value.color, opacity: value.opacity)
        case .tweenFrames(let value):
            guard (1...24).contains(value.inbetweenCount) else { throw StudioCommandError.limitExceeded }
            let first = try frame(value.after), last = try frame(value.to)
            // Charge generated geometry before interpolation; the actual editor
            // validates endpoint compatibility and owns interpolation/undo.
            let elements = document.frames.first { $0.id == first }!.elements
            for _ in 0..<value.inbetweenCount {
                try checkCancellation()
                try budget.generate(elements)
            }
            _ = try editor.tweenFrames(after: first, to: last, inbetweenCount: value.inbetweenCount,
                easing: value.easing, checkCancellation: checkCancellation)
        case .setFrameHold(let value):
            let id = try frame(value.frame)
            guard (1...600).contains(value.ticks) else { throw StudioCommandError.invalidSettings }
            try editor.change { document in
                let index = document.frames.firstIndex { $0.id == id }!
                document.frames[index].holdTicks = value.ticks == 1 ? nil : value.ticks
                if value.ticks > 1 { document.schemaVersion = max(21, document.schemaVersion) }
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
            guard isValidLayerName(value.name) else { throw StudioCommandError.invalidSettings }
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
            guard settings.name.map(isValidLayerName) ?? true,
                  settings.opacity.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  settings.glowRadius.map({ $0.isFinite && (0...128).contains($0) }) ?? true,
                  settings.glowStrength.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  settings.glowColor.map(validColor) ?? true else { throw StudioCommandError.invalidSettings }
            try editor.updateLayer(id) { target in
                if let name = settings.name { target.name = name }
                if let visible = settings.visible { target.visible = visible }
                if let opacity = settings.opacity { target.opacity = opacity }
                if let lock = settings.lock { target.lockMode = lock.rawValue; target.locked = lock == .full }
                if let blend = settings.blend { target.blendMode = blend.rawValue }
                if let enabled = settings.glowEnabled { target.glowEnabled = enabled }
                if let color = settings.glowColor { target.glowColor = color }
                if let radius = settings.glowRadius { target.glowRadius = radius }
                if let strength = settings.glowStrength { target.glowStrength = strength }
            }
        case .moveLayer(let value):
            let id = try layer(value.target), index = document.layers.firstIndex { $0.id == id }!
            guard document.layers.indices.contains(index + value.direction.offset) else { throw StudioCommandError.cannotMove }
            try editor.moveLayer(id, offset: value.direction.offset)
        case .selectLayer(let reference): editor.selectLayer(try layer(reference))
        case .deleteLayer(let reference):
            try editor.deleteLayer(try layer(reference), checkCancellation: checkCancellation)
        case .cutElements(let value):
            guard case .id = value.frame else { throw StudioCommandError.invalidReference }
            let id = try frame(value.frame), ids = Set(value.elementIDs)
            guard id == document.activeFrameID, !ids.isEmpty, ids.count <= maximumGeneratedElements,
                  ids.count == value.elementIDs.count, ids == editor.selectedElementIDs else {
                throw StudioCommandError.missingSelection
            }
            let selected = document.frames.first { $0.id == id }!.elements.filter { ids.contains($0.id) }
            guard selected.count == ids.count else { throw StudioCommandError.invalidReference }
            for element in selected {
                try checkCancellation()
                guard let targetLayer = document.layers.first(where: { $0.id == element.layerID }),
                      targetLayer.visible, targetLayer.opacity > 0, !targetLayer.isFullyLocked,
                      targetLayer.lockMode == "free" else { throw StudioDocumentError.locked }
            }
            // Both operations stage in the executor's private editor. Neither
            // artwork nor the prior clipboard is published on any later failure.
            try editor.copyElements(frameID: id, ids: ids, checkCancellation: checkCancellation)
            try checkCancellation()
            try editor.deleteSelected()
            try checkCancellation()
        case .copyElements(let value):
            let id = try frame(value.frame)
            guard !value.elementIDs.isEmpty, value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            try editor.copyElements(frameID: id, ids: Set(value.elementIDs), checkCancellation: checkCancellation)
        case .pasteElements(let value):
            let frameID = try frame(value.frame), layerID = try layer(value.layer)
            guard value.clipboardID == editor.clipboardVersion.uuidString else { throw StudioCommandError.staleClipboard }
            guard let elements = editor.clipboardElements else { throw StudioCommandError.invalidReference }
            try budget.generate(elements)
            try editor.pasteElements(frameID: frameID, layerID: layerID, checkCancellation: checkCancellation)
        case .deleteElements(let value):
            let id = try frame(value.frame)
            guard !value.elementIDs.isEmpty, value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            let existing = Set(document.frames.first { $0.id == id }!.elements.map(\.id))
            guard Set(value.elementIDs).isSubset(of: existing) else { throw StudioCommandError.invalidReference }
            editor.selectFrame(id); editor.selectedElementIDs = Set(value.elementIDs); try editor.deleteSelected()
        case .translateElements(let value):
            let id = try frame(value.frame)
            guard !value.elementIDs.isEmpty, value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            try editor.translateElements(frameID: id, ids: Set(value.elementIDs), dx: value.dx, dy: value.dy,
                                         checkCancellation: checkCancellation)
        case .transformSelectedArtwork(let value):
            guard value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            try editor.transformSelectedArtwork(frameID: frame(value.frame), ids: Set(value.elementIDs),
                imageAssetID: value.image?.assetID, imageLayerID: value.image?.layerID,
                dx: value.dx, dy: value.dy, scale: value.scale, rotation: value.rotation,
                flipHorizontal: value.flipHorizontal, flipVertical: value.flipVertical, checkCancellation: checkCancellation)
        case .deleteSelectedArtwork(let value):
            guard value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            try editor.deleteSelectedArtwork(frameID: frame(value.frame), ids: Set(value.elementIDs),
                imageAssetID: value.image?.assetID, imageLayerID: value.image?.layerID, checkCancellation: checkCancellation)
        case .transformElements(let value):
            let id = try frame(value.frame)
            guard !value.elementIDs.isEmpty, value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            try editor.transformElements(frameID:id,ids:Set(value.elementIDs),scaleX:value.scaleX,scaleY:value.scaleY,
                                         rotation:value.rotation,checkCancellation:checkCancellation)
        case .reflectElements(let value):
            let id = try frame(value.frame)
            guard !value.elementIDs.isEmpty, value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            try editor.reflectElements(frameID: id, ids: Set(value.elementIDs), axis: value.axis, checkCancellation: checkCancellation)
        case .orderElements(let value):
            let id = try frame(value.frame)
            guard !value.elementIDs.isEmpty, value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            try editor.orderElements(frameID: id, ids: Set(value.elementIDs), forward: value.direction == .later,
                                     checkCancellation: checkCancellation)
        case .orderSelectedArtwork(let value):
            guard value.elementIDs.count <= maximumGeneratedElements,
                  Set(value.elementIDs).count == value.elementIDs.count else { throw StudioCommandError.missingSelection }
            try editor.orderSelectedArtwork(frameID: frame(value.frame), elementIDs: Set(value.elementIDs),
                imageAssetID: value.image?.assetID, imageLayerID: value.image?.layerID,
                forward: value.direction == .later, checkCancellation: checkCancellation)
        case .cropImage(let value):
            try editor.cropImage(frameID: frame(value.frame), assetID: value.assetID, crop: value.crop,
                layerID: imageLayer(value.layer, frame: value.frame, assetID: value.assetID), checkCancellation: checkCancellation)
        case .rotateImage(let value):
            try editor.rotateImage(frameID: frame(value.frame), assetID: value.assetID, direction: value.direction,
                layerID: imageLayer(value.layer, frame: value.frame, assetID: value.assetID), checkCancellation: checkCancellation)
        case .reflectImage(let value):
            try editor.reflectImage(frameID: frame(value.frame), assetID: value.assetID, axis: value.axis,
                layerID: imageLayer(value.layer, frame: value.frame, assetID: value.assetID), checkCancellation: checkCancellation)
        case .deleteImage(let value):
            try editor.deleteImage(frameID: frame(value.frame), assetID: value.assetID,
                layerID: imageLayer(value.layer, frame: value.frame, assetID: value.assetID), checkCancellation: checkCancellation)
        case .updateImagePlacement(let value):
            try editor.updateImagePlacement(frameID: frame(value.frame), assetID: value.assetID, placement: value.placement, rotationDegrees: value.rotationDegrees,
                layerID: imageLayer(value.layer, frame: value.frame, assetID: value.assetID), checkCancellation: checkCancellation)
        case .canvasOptions(let value):
            guard value.grid != nil || value.onion != nil || value.gridSettings != nil || value.onionSettings != nil else { throw StudioCommandError.invalidSettings }
            try editor.change {
                if let grid = value.grid { $0.gridEnabled = grid }
                if let onion = value.onion { $0.onionEnabled = onion }
                if let settings = value.gridSettings { $0.gridSettings = settings }
                if let settings = value.onionSettings { $0.onionSettings = settings }
            }
        }
    }
    private static func receipt(_ request: StudioCommandRequest, original: StudioDocument, final: StudioDocument,
                                created: [String: StudioCommandReceipt.Identity], outcome: StudioCommandReceipt.Outcome,
                                clipboardElementCount: Int, clipboardID: String?) -> StudioCommandReceipt {
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
            createdElementIDs: added(oldElements, newElements), deletedElementIDs: added(newElements, oldElements),
            changedAudioClipIDs: final.audioClips.filter { clip in
                original.audioClips.first(where: { $0.id == clip.id }) != clip
            }.map(\.id) + original.audioClips.filter { clip in
                !final.audioClips.contains(where: { $0.id == clip.id })
            }.map(\.id),
            clipboardElementCount: clipboardElementCount, clipboardID: clipboardID)
    }
}
