import SwiftUI
import ImageIO

struct StudioFrameThumbnail: View {
    @ObservedObject var vm: StudioViewModel
    let frame: AnimationFrame
    var isolatedLayerID: String? = nil
    var body: some View {
        let content = StudioFrameRenderer.thumbnailContent(frame: frame, layers: vm.layers, isolatedLayerID: isolatedLayerID)
        let frame = content.frame, layers = content.layers
        let prepared = Result { try StudioFrameRenderer.prepare(frame: frame) }
        let sources = vm.rasterSources(for: frame)
        let raster = Result { try StudioFrameRenderer.prepareRasters(frame: frame, layers: layers,
            sourceData: sources, maximumDimension: 128) }
        let smudges = Result { try StudioSmudgeReplay.viewCache.prepare(frame: frame, layers: layers,
            canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), rasterData: vm.rasterData(frame.rasterAssetID), rasterDataByID: sources) }
        Canvas { context, size in
            let scale = min(size.width / CGFloat(vm.canvasWidth), size.height / CGFloat(vm.canvasHeight))
            let fitted = CGSize(width: CGFloat(vm.canvasWidth) * scale, height: CGFloat(vm.canvasHeight) * scale)
            context.translateBy(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2)
            context.fill(Path(CGRect(origin: .zero, size: fitted)), with: .color(.white))
            switch (prepared, raster, smudges) {
            case (.success(let brushes), .success(let image), .success(let effects)):
                if let error = StudioFrameRenderer.draw(context: &context, frame: frame, layers: layers,
                    canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: fitted,
                    rasterData: vm.rasterData(frame.rasterAssetID), preparedBrushes: brushes, preparedSmudges: effects, rasterSources: sources, preparedRasters: image) {
                    StudioFrameRenderer.drawFailure(error, context: &context, size: fitted)
                }
            case (.failure(let error), _, _), (_, .failure(let error), _), (_, _, .failure(let error)):
                StudioFrameRenderer.drawFailure(error, context: &context, size: fitted)
            }
        }
    }
}

/// One compositing path for the live canvas, timeline and frames viewer.
struct StudioFrameRenderer {
    /// Isolated thumbnails show unhidden, full-opacity contents against a neutral
    /// background. This changes only the preview copy, never layer preferences.
    static func thumbnailContent(frame: AnimationFrame, layers: [CanvasLayer], isolatedLayerID: String?)
        -> (frame: AnimationFrame, layers: [CanvasLayer]) {
        guard let id = isolatedLayerID else { return (frame, layers) }
        var preview = frame
        preview.elements = frame.elements.filter { $0.layerID == id }
        if let isolatedRaster = frame.projectedRasterFrame(on: id) {
            preview = isolatedRaster
            preview.elements = frame.elements.filter { $0.layerID == id }
        } else {
            preview.rasterAssetID = nil; preview.rasterLayerID = nil; preview.rasterPlacement = nil
            preview.rasterCrop = nil; preview.rasterQuarterTurns = nil; preview.rasterRotationDegrees = nil; preview.rasterReflection = nil
            preview.rasterAliases = nil; preview.rasterRegionMask = nil
        }
        let isolated = layers.filter { $0.id == id }.map { source -> CanvasLayer in
            var layer = source; layer.visible = true; layer.opacity = 1; layer.blendMode = "normal"
            return layer
        }
        return (preview, isolated)
    }

    struct PreparedBrushes {
        fileprivate let elements: [DrawnElement]
        fileprivate let strokes: [String: (geometry: StudioBrushRenderer.Geometry, color: StudioBrushColor)]
    }
    /// Editor-only tint preserves coverage, including black artwork.
    static func onionContext(_ source: GraphicsContext, opacity: Double, previous: Bool, tinted: Bool) -> GraphicsContext {
        var context = source
        context.opacity *= opacity
        if tinted {
            var matrix = ColorMatrix()
            matrix.r1 = 0; matrix.g2 = 0; matrix.b3 = 0
            matrix.r4 = previous ? 1 : 0
            matrix.g4 = 0
            matrix.b4 = previous ? 0 : 1
            context.addFilter(.colorMatrix(matrix))
        }
        return context
    }

    static func prepare(frame: AnimationFrame, liveElement: DrawnElement? = nil) throws -> PreparedBrushes {
        let elements = (frame.elements + (liveElement.map { [$0] } ?? [])).filter { $0.brush != nil }
        var strokes: [String: (geometry: StudioBrushRenderer.Geometry, color: StudioBrushColor)] = [:]
        var marks = 0
        for element in elements {
            guard strokes[element.id] == nil else { throw StudioDocumentError.invalid("A brush identity is duplicated.") }
            let geometry = try StudioBrushGeometryCache.geometry(for: element)
            marks += geometry.marks.count
            guard marks <= StudioBrushGeometryCache.maximumFrameMarks else {
                throw StudioBrushError.workLimit("This frame exceeds the brush rendering budget. The stroke has not been committed.")
            }
            strokes[element.id] = (geometry, try StudioBrushGeometryCache.color(element.color))
        }
        return PreparedBrushes(elements: elements, strokes: strokes)
    }
    static func resolvedRasterSources(frame: AnimationFrame, legacyData: Data?,
                                      sources: [String: Data]) throws -> [String: Data] {
        guard sources.count <= 1000 else { throw StudioRasterImage.Failure.limit }
        var bytes = 0
        for data in sources.values {
            guard data.count <= StudioRasterImage.maximumManagedHistoryBytes - bytes else { throw StudioRasterImage.Failure.limit }
            bytes += data.count
        }
        var resolved = sources.filter { frame.referencedRasterAssetIDs.contains($0.key) }
        if let id = frame.rasterAssetID, let legacyData {
            if let existing = resolved[id], existing != legacyData { throw StudioRasterImage.Failure.invalid }
            resolved[id] = legacyData
        }
        bytes = 0
        for data in resolved.values {
            guard data.count <= StudioRasterImage.maximumManagedHistoryBytes - bytes else { throw StudioRasterImage.Failure.limit }
            bytes += data.count
        }
        return resolved
    }
    /// Decode each distinct visible source once; maps never infer another
    /// source's bytes. Aggregate limits apply even when individual decodes fit.
    static func prepareRasters(frame: AnimationFrame, layers: [CanvasLayer], sourceData: [String: Data],
                               maximumDimension: Int = 8192) throws -> [String: StudioRasterImage.Prepared] {
        guard (1...8192).contains(maximumDimension) else { throw StudioRasterImage.Failure.limit }
        let sourceData = try resolvedRasterSources(frame: frame, legacyData: nil, sources: sourceData)
        let instances = frame.visibleRasterInstances(in: layers)
        guard instances.count <= 128 else { throw StudioRasterImage.Failure.limit }
        var result: [String: StudioRasterImage.Prepared] = [:]
        var encodedBytes = 0, decodedBytes = 0
        for instance in instances {
            guard let asset = frame.rasterAssetID(on: instance.layerID) else { throw StudioRasterImage.Failure.missing }
            if result[asset] != nil { continue }
            let shared = instances.filter { frame.rasterAssetID(on: $0.layerID) == asset }
            let managed = shared.contains { $0.placement != nil }
            guard let data = sourceData[asset] else {
                if managed { throw StudioRasterImage.Failure.missing }
                continue // Preserved historical opaque records have no pixel payload.
            }
            guard data.count <= StudioRasterImage.maximumManagedHistoryBytes - encodedBytes else { throw StudioRasterImage.Failure.limit }
            encodedBytes += data.count
            var smallestCrop = 1.0
            for item in shared {
                try item.regionMask?.validate()
                let sampled = item.regionMask?.sampledInstance(item) ?? item
                let crop = sampled.crop ?? .full; try crop.validate()
                smallestCrop = min(smallestCrop, min(crop.width, crop.height))
            }
            let detail = min(8192, Int(ceil(Double(maximumDimension) / smallestCrop)))
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = metadata[kCGImagePropertyPixelWidth] as? Int,
                  let height = metadata[kCGImagePropertyPixelHeight] as? Int,
                  (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216 else {
                throw StudioRasterImage.Failure.invalid
            }
            let factor = min(1, Double(detail) / Double(max(width, height)))
            // Retained RGBA is four bytes/pixel. The decoder's eight-byte
            // estimate controls its transient cache eviction, not admission:
            // using it here would reject historical valid 16MP images.
            let minimumRetainedBytes = Int(ceil(Double(width) * factor)) * Int(ceil(Double(height) * factor)) * 4 + data.count
            guard minimumRetainedBytes <= StudioRasterImage.maximumCacheBytes - decodedBytes else { throw StudioRasterImage.Failure.limit }
            let image = try StudioRasterImage.prepare(assetID: asset, data: data, managed: managed, maximumDimension: detail)
            let bytes = image.image.bytesPerRow * image.image.height + image.encoded.count
            guard bytes <= StudioRasterImage.maximumCacheBytes - decodedBytes else { throw StudioRasterImage.Failure.limit }
            decodedBytes += bytes; result[asset] = image
        }
        return result
    }
    static func prepareRaster(frame: AnimationFrame, layers: [CanvasLayer], data: Data?,
                              maximumDimension: Int = 8192) throws -> StudioRasterImage.Prepared? {
        let visibleInstances = frame.visibleRasterInstances(in: layers)
        guard let asset = frame.rasterAssetID, !visibleInstances.isEmpty else { return nil }
        guard visibleInstances.allSatisfy({ frame.rasterAssetID(on: $0.layerID) == asset }) else {
            throw StudioRasterImage.Failure.missing // Multi-source callers must supply a source map.
        }
        guard let data else {
            // Historical opaque LayerData records have no pixel image, and stay
            // preserved. Version-3 managed stills must always have actual pixels.
            if frame.rasterPlacement != nil { throw StudioRasterImage.Failure.missing }
            return nil
        }
        guard (1...8192).contains(maximumDimension) else { throw StudioRasterImage.Failure.limit }
        // Decode the shared source once, retaining enough detail for every visible
        // copy's independent crop. Cropping happens in the raw-layer compositor.
        var smallestCrop = 1.0
        for instance in visibleInstances {
            try instance.regionMask?.validate()
            let sampled = instance.regionMask?.sampledInstance(instance) ?? instance
            let crop = sampled.crop ?? .full
            try crop.validate()
            smallestCrop = min(smallestCrop, min(crop.width, crop.height))
        }
        let detail = min(8192, Int(ceil(Double(maximumDimension) / smallestCrop)))
        return try StudioRasterImage.prepare(assetID: asset, data: data, managed: frame.rasterPlacement != nil,
            maximumDimension: detail)
    }
    /// Reconstruct only adjacent complementary pieces with exactly the same
    /// immutable source sampling origin. Independent layer state is never edited.
    static func imageRegionReconstructionPairs(frame: AnimationFrame, layers: [CanvasLayer],
                                               liveElement: DrawnElement? = nil) -> [String: (top: String, instance: StudioRasterLayerInstance)] {
        guard layers.count > 1 else { return [:] }
        var result: [String: (top:String, instance:StudioRasterLayerInstance)] = [:], used = Set<String>()
        for index in stride(from: layers.count - 1, through: 1, by: -1) {
            let bottom = layers[index], top = layers[index - 1]
            guard !used.contains(bottom.id), !used.contains(top.id),
                  [bottom,top].allSatisfy({ $0.visible && $0.opacity == 1 && $0.blendMode == "normal" && !$0.glowEnabled }),
                  !frame.elements.contains(where: { $0.layerID == bottom.id || $0.layerID == top.id }),
                  liveElement?.layerID != bottom.id, liveElement?.layerID != top.id,
                  let a = frame.rasterInstance(on:bottom.id), let b = frame.rasterInstance(on:top.id),
                  frame.rasterAssetID(on:bottom.id) == frame.rasterAssetID(on:top.id),
                  let am = a.regionMask, let bm = b.regionMask,
                  am.width == bm.width, am.height == bm.height, am.spans == bm.spans, am.inverted != bm.inverted,
                  am.sourceClip == bm.sourceClip,
                  let sampling = am.samplingGeometry, sampling == bm.samplingGeometry,
                  am.placementGeometry == StudioImageRegionMask.Geometry(a),
                  bm.placementGeometry == StudioImageRegionMask.Geometry(b),
                  (try? am.validate()) != nil, (try? bm.validate()) != nil else { continue }
            var joined = sampling.applying(to:a), full = am
            full = .init(width:am.width,height:am.height,spans:[],inverted:true,
                         sourceClip:am.sourceClip,samplingGeometry:sampling,placementGeometry:sampling)
            joined.regionMask = full
            result[bottom.id] = (top.id,joined); used.insert(bottom.id); used.insert(top.id)
        }
        return result
    }
    @discardableResult
    static func draw(context: inout GraphicsContext, frame: AnimationFrame, layers: [CanvasLayer], canvasSize: CGSize,
                     size: CGSize, rasterData: Data? = nil, liveElement: DrawnElement? = nil,
                     preparedBrushes: PreparedBrushes? = nil, preparedRaster: StudioRasterImage.Prepared? = nil,
                     preparedSmudges: StudioSmudgeReplay.Prepared? = nil,
                     rasterSources: [String: Data]? = nil,
                     preparedRasters: [String: StudioRasterImage.Prepared]? = nil) -> Error? {
        let prepared: PreparedBrushes
        let images: [String: StudioRasterImage.Prepared]
        do {
            prepared = try preparedBrushes ?? prepare(frame: frame, liveElement: liveElement)
            let sources = try resolvedRasterSources(frame: frame, legacyData: rasterData, sources: rasterSources ?? [:])
            if let preparedRasters { images = preparedRasters }
            else if let preparedRaster { images = [preparedRaster.assetID: preparedRaster] }
            else { images = try prepareRasters(frame: frame, layers: layers, sourceData: sources) }
            let visible = frame.visibleRasterInstances(in: layers)
            var decodedBytes = 0, encodedBytes = 0
            for (asset, image) in images {
                let matching = visible.filter { frame.rasterAssetID(on: $0.layerID) == asset }
                guard !matching.isEmpty, image.assetID == asset, image.encoded == sources[asset],
                      image.managed == matching.contains(where: { $0.placement != nil }) else { throw StudioRasterImage.Failure.invalid }
                let bytes = image.image.bytesPerRow * image.image.height + image.encoded.count
                guard bytes <= StudioRasterImage.maximumCacheBytes - decodedBytes,
                      image.encoded.count <= StudioRasterImage.maximumManagedHistoryBytes - encodedBytes else { throw StudioRasterImage.Failure.limit }
                decodedBytes += bytes; encodedBytes += image.encoded.count
            }
            for instance in visible where instance.placement != nil {
                guard let asset = frame.rasterAssetID(on: instance.layerID), images[asset] != nil else { throw StudioRasterImage.Failure.missing }
            }
            guard prepared.elements == (frame.elements + (liveElement.map { [$0] } ?? [])).filter({ $0.brush != nil }) else {
                throw StudioDocumentError.invalid("Prepared brushes do not match this frame. No frame was rendered.")
            }
        } catch { return error }
        do {
            if frame.elements.contains(where: { $0.hasPixelEffect }) || liveElement?.hasPixelEffect == true {
                guard let preparedSmudges else { throw StudioSmudgeReplay.Failure.unprepared }
                try preparedSmudges.validate(frame: frame, layers: layers, canvasSize: canvasSize,
                    rasterData: rasterData, rasterDataByID: rasterSources ?? [:], liveElement: liveElement)
            }
        } catch { return error }
        var failure: Error?
        let reconstruction = imageRegionReconstructionPairs(frame:frame,layers:layers,liveElement:liveElement)
        let reconstructedTops = Set(reconstruction.values.map { $0.top })
        for layer in layers.reversed() where layer.visible && layer.opacity > 0 {
            if reconstructedTops.contains(layer.id) { continue }
            var drawingFrame = frame
            if let pair = reconstruction[layer.id] {
                do { try drawingFrame.updateRasterInstance(pair.instance) } catch { return error }
            }
            var composite = context
            composite.opacity *= layer.opacity
            composite.blendMode = blend(layer.blendMode)
            guard layer.hasValidGlowSettings else { return StudioDocumentError.invalid("A layer has invalid glow settings.") }
            if layer.glowEnabled && layer.effectiveGlowStrength > 0 {
                let scale = min(size.width / canvasSize.width, size.height / canvasSize.height)
                composite.addFilter(.shadow(color: Color(hex: layer.glowColor ?? "#FF0000").opacity(layer.effectiveGlowStrength),
                    radius: layer.effectiveGlowRadius * scale))
            }
            composite.drawLayer { local in
                failure = drawRawLayer(context: &local, frame: drawingFrame, layer: layer, canvasSize: canvasSize,
                    size: size, preparedBrushes: prepared, preparedRaster: frame.rasterAssetID(on: layer.id).flatMap { images[$0] },
                    smudges: preparedSmudges?.images ?? [:], liveElement: liveElement)
            }
            if let failure { return failure }
        }
        return nil
    }
    private static func drawImage(_ image: CGImage, crop: StudioImageCrop?, regionMask: StudioImageRegionMask?,
                                  in rect: CGRect, context: inout GraphicsContext) {
        let sourceRect: CGRect
        if let crop {
            if regionMask == nil { context.clip(to: Path(rect)) }
            let width = rect.width / crop.width, height = rect.height / crop.height
            sourceRect = CGRect(x: rect.minX - crop.x * width, y: rect.minY - crop.y * height, width: width, height: height)
        } else { sourceRect = rect }
        if let mask = regionMask {
            if let clip = mask.sourceClip {
                let clipRect = clip == crop ? rect : CGRect(x:sourceRect.minX + clip.x*sourceRect.width,
                    y:sourceRect.minY + clip.y*sourceRect.height,
                    width:clip.width*sourceRect.width,height:clip.height*sourceRect.height)
                context.clip(to: Path(clipRect))
            }
            var path = Path()
            let sx = sourceRect.width / Double(mask.width), sy = sourceRect.height / Double(mask.height)
            for span in mask.spans {
                path.addRect(CGRect(x: sourceRect.minX + Double(span.start) * sx,
                    y: sourceRect.minY + Double(span.row) * sy, width: Double(span.end - span.start) * sx, height: sy))
            }
            // Complementary clips choose one side of each device sample. The
            // original shared CGImage retains precisely its existing filtering.
            if !mask.spans.isEmpty || !mask.inverted {
                context.clip(to: path, style: FillStyle(eoFill: false, antialiased: false), options: mask.inverted ? .inverse : [])
            }
        }
        context.draw(Image(decorative: image, scale: 1), in: sourceRect)
    }
    /// Shared raw-layer compositor, before opacity/blend/glow. Replay uses the
    /// same raster, vector, text and eraser operations as canvas and export.
    static func drawRawLayer(context: inout GraphicsContext, frame: AnimationFrame, layer: CanvasLayer,
                             canvasSize: CGSize, size: CGSize, preparedBrushes: PreparedBrushes,
                             preparedRaster: StudioRasterImage.Prepared?, baseImage: CGImage? = nil,
                             smudges: [String: CGImage] = [:], liveElement: DrawnElement? = nil,
                             preparedRasters: [String: StudioRasterImage.Prepared] = [:],
                             rasterElementOffset: Int? = nil) -> Error? {
        let selectedRaster = frame.rasterInstance(on: layer.id)
        let ordered = frame.elements.filter { $0.layerID == layer.id }
        let imagePosition = selectedRaster?.stackPosition ?? 0
        // Replay prefixes retain the absolute image slot while their element
        // array contains only the suffix since the previous flattened effect.
        let offset = rasterElementOffset ?? 0
        guard imagePosition >= 0, imagePosition <= 20_000, offset >= 0, offset <= 20_000,
              ordered.count <= 20_000 - offset,
              rasterElementOffset != nil || selectedRaster == nil || imagePosition <= ordered.count else {
            return StudioRasterLayerInstance.Failure.invalid
        }
        let relativeImagePosition = imagePosition - offset
        let shouldDrawImage = (baseImage == nil || rasterElementOffset != nil)
            && relativeImagePosition >= 0 && relativeImagePosition <= ordered.count
        let raster = selectedRaster.map { $0.regionMask?.sampledInstance($0) ?? $0 }
        let preparedRaster = frame.rasterAssetID(on: layer.id).flatMap { preparedRasters[$0] } ?? preparedRaster
        do {
            try raster?.crop?.validate()
            if let mask = raster?.regionMask {
                try mask.validate()
                guard let source = preparedRaster, source.managed,
                      source.sourceWidth == mask.width, source.sourceHeight == mask.height else { throw StudioRasterImage.Failure.invalid }
            }
            if let raster, let preparedRaster {
                guard preparedRaster.assetID == frame.rasterAssetID(on: layer.id),
                      preparedRaster.managed == (raster.placement != nil) else { throw StudioRasterImage.Failure.invalid }
            }
            if raster?.placement != nil && preparedRaster == nil && (baseImage == nil || shouldDrawImage) { throw StudioRasterImage.Failure.missing }
        } catch { return error }
        func drawSelectedRaster(in context: inout GraphicsContext) {
            guard let raster, let image = preparedRaster else { return }
            let rect: CGRect
            if let placement = raster.placement {
                rect = CGRect(x: placement.x / canvasSize.width * size.width,
                    y: placement.y / canvasSize.height * size.height,
                    width: placement.width / canvasSize.width * size.width,
                    height: placement.height / canvasSize.height * size.height)
            } else { rect = CGRect(origin: .zero, size: size) }
            // Isolate the transform from drawing elements on this layer.
            // Reflect in viewport coordinates about the placed center;
            // canvas, thumbnails and every export share these pixels.
            var picture = context
            if let placement = raster.placement, raster.quarterTurns != nil || raster.rotationDegrees != nil {
                let turns = raster.quarterTurns ?? 0
                // Rotate in document coordinates. Conjugating viewport
                // scale keeps thumbnails/non-square views geometrically correct.
                picture.translateBy(x: rect.midX, y: rect.midY)
                picture.scaleBy(x: size.width / canvasSize.width, y: size.height / canvasSize.height)
                if let degrees = raster.rotationDegrees { picture.rotate(by: .degrees(degrees)) }
                if let reflection = raster.reflection {
                    picture.scaleBy(x: reflection.horizontal ? -1 : 1, y: reflection.vertical ? -1 : 1)
                }
                picture.rotate(by: .degrees(Double(turns) * 90))
                let width = turns % 2 == 0 ? placement.width : placement.height
                let height = turns % 2 == 0 ? placement.height : placement.width
                drawImage(image.image, crop: raster.crop, regionMask: raster.regionMask, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), context: &picture)
            } else {
            if let reflection = raster.reflection {
                picture.translateBy(x: rect.midX, y: rect.midY)
                picture.scaleBy(x: reflection.horizontal ? -1 : 1, y: reflection.vertical ? -1 : 1)
                picture.translateBy(x: -rect.midX, y: -rect.midY)
            }
            drawImage(image.image, crop: raster.crop, regionMask: raster.regionMask, in: rect, context: &picture)
            }
        }
        if let baseImage {
            context.draw(Image(decorative: baseImage, scale: 1), in: CGRect(origin: .zero, size: size))
        }
        for (index, element) in ordered.enumerated() {
            if shouldDrawImage && relativeImagePosition == index { drawSelectedRaster(in: &context) }
            var elementContext = context
            do { try drawPreparedElement(context: &elementContext, element: element, size: size, canvasSize: canvasSize,
                brush: preparedBrushes.strokes[element.id], smudges: smudges) } catch { return error }
        }
        // The persisted end slot is below any current live stroke/effect.
        if shouldDrawImage && relativeImagePosition == ordered.count { drawSelectedRaster(in: &context) }
        if let element = liveElement, element.layerID == layer.id {
            var elementContext = context
            do { try drawPreparedElement(context: &elementContext, element: element, size: size, canvasSize: canvasSize,
                brush: preparedBrushes.strokes[element.id], smudges: smudges) } catch { return error }
        }
        return nil
    }
    private static func drawPreparedElement(context: inout GraphicsContext, element: DrawnElement,
                                            size: CGSize, canvasSize: CGSize,
                                            brush: (geometry: StudioBrushRenderer.Geometry, color: StudioBrushColor)?,
                                            smudges: [String: CGImage]) throws {
        if let erasures = element.selectionErasures, !erasures.isEmpty {
            guard !element.hasPixelEffect, element.preservesLayerAlpha != true, element.tool != .eraser else {
                throw StudioDocumentError.invalid("Selected erasure requires independently rendered artwork.")
            }
            // The destination-out masks belong to this one isolated object.
            // Applying them on the parent layer would destroy unselected overlap.
            var source = element; source.selectionErasures = nil
            var failure: Error?
            context.drawLayer { isolated in
                do {
                    var drawing = isolated
                    try drawElement(context: &drawing, element: source, size: size, canvasSize: canvasSize, brush: brush)
                    for erasure in erasures {
                        // Start every mask from the isolated root: drawElement
                        // mutates its local transform and opacity while drawing.
                        var maskContext = isolated
                        let mask = try erasure.element(for: element)
                        try drawElement(context: &maskContext, element: mask, size: size, canvasSize: canvasSize, brush: nil)
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }
        } else if element.hasPixelEffect {
            guard let image = smudges[element.id] else { throw StudioSmudgeReplay.Failure.unprepared }
            // Replace the entire raw layer, including pixels made transparent.
            // Opacity was applied once by the operation; layer effects occur later.
            context.blendMode = .destinationOut
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            context.blendMode = .normal
            context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size))
        } else if element.preservesLayerAlpha == true {
            guard element.brush != nil else { throw StudioDocumentError.invalid("Alpha-preserving paint requires a brush.") }
            // Composite the complete brush once over the preceding raw layer.
            // Source-atop preserves destination alpha, including antialiased edges.
            // Layer opacity, blend and glow are applied only by the outer compositor.
            context.blendMode = .sourceAtop
            var failure: Error?
            context.drawLayer { drawing in
                drawing.blendMode = .normal
                do { try drawElement(context: &drawing, element: element, size: size, canvasSize: canvasSize, brush: brush) }
                catch { failure = error }
            }
            if let failure { throw failure }
        } else {
            try drawElement(context: &context, element: element, size: size, canvasSize: canvasSize, brush: brush)
        }
    }
    static func drawFailure(_ error: Error, context: inout GraphicsContext, size: CGSize) {
        context.draw(Text("Render unavailable: \(error.localizedDescription)").font(.system(size: 11)).foregroundColor(.red),
                     in: CGRect(origin: .zero, size: size))
    }
    private static func blend(_ name: String) -> GraphicsContext.BlendMode {
        switch name.lowercased() {
        case "multiply": return .multiply
        case "screen": return .screen
        case "overlay": return .overlay
        case "darken": return .darken
        case "lighten": return .lighten
        default: return .normal
        }
    }
    private static func drawElement(context: inout GraphicsContext, element: DrawnElement, size: CGSize, canvasSize: CGSize,
                                   brush: (geometry: StudioBrushRenderer.Geometry, color: StudioBrushColor)?) throws {
        let scaleX = size.width / canvasSize.width
        let scaleY = size.height / canvasSize.height
        let color = Color(hex: element.color)
        if element.eraser != nil || element.text != nil || element.transform != nil { context.clip(to: Path(CGRect(origin: .zero, size: size))) }
        if let t = element.transform {
            try t.validate()
            // Conjugate by the viewport scale; rotation remains correct even
            // when the destination aspect ratio differs from document pixels.
            context.concatenate(CGAffineTransform(a:t.a,b:t.b*scaleY/scaleX,c:t.c*scaleX/scaleY,
                                                  d:t.d,tx:t.tx*scaleX,ty:t.ty*scaleY))
        }
        if let translation = element.translation {
            try translation.validate()
            context.translateBy(x: translation.x * scaleX, y: translation.y * scaleY)
        }
        if let reflection = element.reflection {
            try reflection.validate()
            context.scaleBy(x: reflection.horizontal ? -1 : 1, y: reflection.vertical ? -1 : 1)
        }

        if let text = element.text, let origin = element.points.first {
            try text.validate(element: element)
            let style = text.style
            context.scaleBy(x: scaleX, y: scaleY)
            context.opacity = element.opacity
            context.translateBy(x: origin.x + style.boxWidth / 2, y: origin.y + style.boxHeight / 2)
            context.rotate(by: .degrees(style.rotation))
            let box = CGRect(x: -style.boxWidth/2, y: -style.boxHeight/2, width: style.boxWidth, height: style.boxHeight)
            context.clip(to: Path(box))
            let design: Font.Design = style.font == .monospaced ? .monospaced : style.font == .serif ? .serif : .default
            var font = Font.system(size: style.size, weight: style.bold ? .bold : .regular, design: design)
            if style.italic { font = font.italic() }
            // Resolve each actual shaped line using the same font engine used
            // to draw it. Alignment applies per wrapped line, not just to the
            // bounding box. No UI-only View modifiers or estimated glyph widths.
            func resolve(_ value: String) -> GraphicsContext.ResolvedText {
                context.resolve(Text(value).font(font).foregroundColor(color))
            }
            let unlimited = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            let lineHeight = max(1, ceil(resolve("Ag").measure(in: unlimited).height))
            var y = box.minY
            for paragraph in text.paragraphs {
                guard y < box.maxY else { break }
                let characters = Array(paragraph)
                if characters.isEmpty { y += lineHeight; continue }
                var start = 0
                while start < characters.count && y < box.maxY {
                    var low = start + 1, high = characters.count, end = start + 1
                    while low <= high {
                        let candidate = (low + high) / 2
                        let measured = resolve(String(characters[start..<candidate])).measure(in: unlimited).width
                        if measured <= style.boxWidth { end = candidate; low = candidate + 1 }
                        else { high = candidate - 1 }
                    }
                    if end < characters.count, let space = (start..<end).last(where: { characters[$0].isWhitespace }), space > start {
                        end = space + 1
                    }
                    let value = String(characters[start..<end])
                    let line = resolve(value), width = line.measure(in: unlimited).width
                    let x = box.minX + (style.alignment == .right ? style.boxWidth-width : style.alignment == .center ? (style.boxWidth-width)/2 : 0)
                    context.draw(line, at: CGPoint(x: x, y: y), anchor: .topLeading)
                    y += lineHeight; start = end
                }
            }
            return
        }

        if let eraser = element.eraser {
            try eraser.validate(element: element)
            guard element.opacity > 0 else { return }
            // One opaque mask, then one destination-out composite. Crossing a
            // stroke over itself cannot multiply its captured strength.
            context.scaleBy(x: scaleX, y: scaleY)
            context.opacity = element.opacity
            context.blendMode = .destinationOut
            context.drawLayer { mask in
                mask.opacity = 1; mask.blendMode = .normal
                if eraser.mode == .soft { mask.addFilter(.blur(radius: element.width * 0.2)) }
                let first = element.points[0]
                if element.points.count == 1 {
                    mask.fill(Path(ellipseIn: CGRect(x: first.x - element.width / 2,
                        y: first.y - element.width / 2, width: element.width, height: element.width)), with: .color(.black))
                } else {
                    var path = Path(); path.move(to: CGPoint(x: first.x, y: first.y))
                    for point in element.points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                    let outline = path.strokedPath(StrokeStyle(lineWidth: element.width, lineCap: .round, lineJoin: .round))
                    mask.fill(outline,
                        with: .color(.black), style: FillStyle(eoFill: false))
                }
            }
            return
        }

        if let mask = element.fillMask {
            try mask.validate()
            guard element.tool == .fill, element.brush == nil, element.shape == nil,
                  CGFloat(mask.width) == canvasSize.width, CGFloat(mask.height) == canvasSize.height else {
                throw StudioFillMask.Failure.invalid
            }
            // Coverage is already antialiased by the bounded region operation.
            // Group equal coverage so adjacent scanlines do not create seams.
            var paths: [UInt8: Path] = [:]
            for span in mask.spans {
                paths[span.alpha, default: Path()].addRect(CGRect(x: span.start, y: span.row,
                    width: span.end - span.start, height: 1))
            }
            context.scaleBy(x: scaleX, y: scaleY)
            for alpha in paths.keys.sorted() {
                var coverage = context
                coverage.opacity = element.opacity * Double(alpha) / 255
                coverage.fill(paths[alpha]!, with: .color(color), style: FillStyle(antialiased: false))
            }
            return
        }

        if let shape = element.shape {
            try shape.validate(tool: element.tool)
            guard element.brush == nil else { throw StudioShapeDescriptor.Failure.invalid }
            guard element.points.count >= 2 else { return }
            let first = element.points[0], last = element.points[1]
            if element.tool == .line {
                context.scaleBy(x: scaleX, y: scaleY); context.opacity = element.opacity
                let start = CGPoint(x: first.x, y: first.y), end = CGPoint(x: last.x, y: last.y)
                context.drawLayer { drawing in
                    drawing.opacity = 1
                    var shaft = Path(); shaft.move(to: start); shaft.addLine(to: end)
                    drawing.stroke(shaft, with: .color(color), lineWidth: element.width)
                    for triangle in shape.arrowTriangles(from: start, to: end) {
                        var head = Path(); head.move(to: triangle[0]); head.addLine(to: triangle[1]); head.addLine(to: triangle[2]); head.closeSubpath()
                        drawing.fill(head, with: .color(color))
                    }
                }
                return
            }
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                width: abs(last.x - first.x), height: abs(last.y - first.y))
            let path: Path
            if element.tool == .circle { path = Path(ellipseIn: rect) }
            else {
                let radius = min(CGFloat(shape.cornerRadius), min(rect.width, rect.height) / 2)
                path = Path(roundedRect: rect, cornerRadius: radius)
            }
            context.scaleBy(x: scaleX, y: scaleY)
            context.opacity = element.opacity
            // Apply element opacity once to the whole shape, including the
            // overlap between its fill and stroke. Layer opacity stays outside.
            context.drawLayer { drawing in
                drawing.opacity = 1
                if let fill = shape.fillColor { drawing.fill(path, with: .color(Color(hex: fill))) }
                drawing.stroke(path, with: .color(color), lineWidth: element.width)
            }
            return
        }

        if element.brush != nil {
            guard let brush else { throw StudioDocumentError.invalid("A prepared brush is missing.") }
            context.scaleBy(x: scaleX, y: scaleY)
            // Geometry already contains canonical element opacity. Applying it
            // again to this context would square it and break layer/onion alpha.
            try StudioBrushRenderer.draw(brush.geometry, color: brush.color, context: &context)
            return
        }

        context.opacity = element.opacity

        switch element.tool {
        case .pencil, .pen, .brush, .marker, .crayon, .eraser, .smudge:
            guard !element.points.isEmpty else { return }
            if element.points.count == 1 {
                let point = element.points[0]
                let radius = max(0.5, element.width * scaleX * brushWidthMultiplier(for: element.tool) / 2)
                if element.tool == .eraser { context.blendMode = .clear }
                context.fill(Path(ellipseIn: CGRect(x: point.x * scaleX - radius, y: point.y * scaleY - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                context.blendMode = .normal
                return
            }
            var path = Path()
            let first = element.points[0]
            path.move(to: CGPoint(x: first.x * scaleX, y: first.y * scaleY))

            if element.points.count == 2 {
                let p = element.points[1]
                path.addLine(to: CGPoint(x: p.x * scaleX, y: p.y * scaleY))
            } else {
                for i in 1..<element.points.count {
                    let prev = element.points[i - 1]
                    let curr = element.points[i]
                    let midX = (prev.x + curr.x) / 2 * scaleX
                    let midY = (prev.y + curr.y) / 2 * scaleY
                    path.addQuadCurve(
                        to: CGPoint(x: midX, y: midY),
                        control: CGPoint(x: prev.x * scaleX, y: prev.y * scaleY)
                    )
                }
                let last = element.points.last!
                path.addLine(to: CGPoint(x: last.x * scaleX, y: last.y * scaleY))
            }

            let lineWidth = element.width * scaleX * brushWidthMultiplier(for: element.tool)

            if element.tool == .eraser {
                context.blendMode = .clear
            }

            context.stroke(path, with: .color(color), style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: element.tool == .pencil ? .butt : .round,
                lineJoin: .round
            ))

            if element.tool == .eraser {
                context.blendMode = .normal
            }

        case .line:
            guard element.points.count >= 2 else { return }
            var path = Path()
            path.move(to: CGPoint(x: element.points[0].x * scaleX, y: element.points[0].y * scaleY))
            path.addLine(to: CGPoint(x: element.points[1].x * scaleX, y: element.points[1].y * scaleY))
            context.stroke(path, with: .color(color), lineWidth: element.width * scaleX)

        case .rectangle:
            guard element.points.count >= 2 else { return }
            let rect = CGRect(
                x: min(element.points[0].x, element.points[1].x) * scaleX,
                y: min(element.points[0].y, element.points[1].y) * scaleY,
                width: abs(element.points[1].x - element.points[0].x) * scaleX,
                height: abs(element.points[1].y - element.points[0].y) * scaleY
            )
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: element.width * scaleX)

        case .circle:
            guard element.points.count >= 2 else { return }
            let center = CGPoint(
                x: (element.points[0].x + element.points[1].x) / 2 * scaleX,
                y: (element.points[0].y + element.points[1].y) / 2 * scaleY
            )
            let radiusX = abs(element.points[1].x - element.points[0].x) / 2 * scaleX
            let radiusY = abs(element.points[1].y - element.points[0].y) / 2 * scaleY
            let path = Path(ellipseIn: CGRect(
                x: center.x - radiusX, y: center.y - radiusY,
                width: radiusX * 2, height: radiusY * 2
            ))
            context.stroke(path, with: .color(color), lineWidth: element.width * scaleX)

        case .text:
            if let text = element.fillColor, let first = element.points.first {
                context.draw(
                    Text(text).font(.system(size: element.width * 3 * min(scaleX, scaleY), design: .monospaced)).foregroundColor(color),
                    at: CGPoint(x: first.x * scaleX, y: first.y * scaleY),
                    anchor: .topLeading
                )
            }

        default:
            break
        }

        context.opacity = 1.0
    }

    private static func brushWidthMultiplier(for tool: DrawingTool) -> CGFloat {
        switch tool {
        case .pencil: return 0.8
        case .pen: return 1.0
        case .brush: return 1.5
        case .marker: return 2.5
        case .crayon: return 2.0
        case .eraser: return 3.0
        case .smudge: return 2.0
        default: return 1.0
        }
    }

}
