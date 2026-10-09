import SwiftUI
import ImageIO

// ═══════════════════════════════════════════════════════════════════
// Floating Tool Settings Panel — positioned over canvas
// Tool icon + name, X close, per-tool settings,
// Colors: Red for Pencil/Pen/Brush, Green for Fill, Purple for Smudge,
//         Amber for Crayon, Cyan for Picker, Orange for Eraser,
//         Pink for Marker/Text, Gray for shapes/move/lasso
// ═══════════════════════════════════════════════════════════════════

struct FloatingToolSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel
    var alignToBottom = false
    @State private var showBrushLibrary = false
    @State private var imagePlacement: StudioViewModel.ImagePlacementCapture?
    @State private var imageCrop: StudioViewModel.ImagePlacementCapture?
    @State private var imageDeletion: StudioViewModel.ImagePlacementCapture?
    @State private var showingImageDeletion = false
    @State private var selectionLayerLock: StudioViewModel.SelectionLayerLockCapture?
    @State private var showingSelectionLayerLock = false
    // The popup owns both draft values and distinct field focus. Keyboard
    // and viewport changes must not recreate an interactive input.
    @State private var imageX = ""
    @State private var imageY = ""
    @State private var imageWidth = ""
    @State private var imageHeight = ""
    @FocusState private var textInputFocused: Bool
    @FocusState private var imageFocusedField: StudioImagePlacementField?

    static func hasSettings(_ tool: DrawingTool) -> Bool { tool != .eyedropper }
    
    var toolDef: ToolDef? {
        StudioToolStrip.tools.first { $0.tool == vm.selectedTool }
    }
    
    var accentColor: Color {
        guard let def = toolDef else { return .red }
        return Color(hex: def.topColor)
    }
    
    var body: some View {
        GeometryReader { available in
        let compact = available.size.height < 180
        VStack(alignment: .leading, spacing: 0) {
            if let def = toolDef {
                VStack(alignment: .leading, spacing: compact ? 4 : 10) {
                    // Header: icon + name + X close
                    HStack {
                        Image(systemName: def.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                        Text(def.label)
                            .font(.specialElite(14))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Button(action: { textInputFocused = false; imageFocusedField = nil; vm.activePanel = .none }) {
                            Text("✕")
                                .font(.system(size: 14))
                                .foregroundColor(.sdStudioSecondaryText)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Close tool settings")
                        .accessibilityIdentifier("studio.tool-settings.close")
                    }
                    
                    if !compact { Divider().background(Color.white.opacity(0.08)) }
                    
                    // Tool-specific content
                    // Short controls use their natural height. Longer libraries
                    // scroll inside the same bounded popup instead of covering
                    // empty canvas with an oversized scroll viewport.
                    ToolSettingsContentLayout(maximumHeight: max(0, min(360, available.size.height - (compact ? 60 : 132)))) {
                        toolSettingsContent(def, compactHeight: compact)
                    }
                    
                }
                .padding(compact ? 6 : 12)
            }
        }
        .frame(width: min(260, available.size.width))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "1A1A24").opacity(0.98))
                .shadow(color: .black.opacity(0.5), radius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.tool-settings")
        .tint(.sdStudioActionText)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignToBottom ? .bottom : .top)
        }
        .onChange(of: vm.selectedTool) { _, _ in
            imageCrop = nil; imagePlacement = nil; showingImageDeletion = false; imageDeletion = nil; imageFocusedField = nil
            selectionLayerLock = nil; showingSelectionLayerLock = false
        }
        .onChange(of: vm.hasMixedArtworkSelection) { _, mixed in
            if mixed {
                imageCrop = nil; imagePlacement = nil; imageDeletion = nil; showingImageDeletion = false
                imageFocusedField = nil; selectionLayerLock = nil; showingSelectionLayerLock = false
            }
        }
        .onDisappear {
            imageCrop = nil; imagePlacement = nil; showingImageDeletion = false; imageDeletion = nil; imageFocusedField = nil
            selectionLayerLock = nil; showingSelectionLayerLock = false
        }
        .confirmationDialog("Lock entire selected layers?", isPresented: $showingSelectionLayerLock,
            titleVisibility: .visible, presenting: selectionLayerLock) { capture in
            Button("Lock selected layers") { _ = vm.lockSelectedLayers(capture) }
            Button("Cancel", role: .cancel) { }
        } message: { capture in
            Text("All artwork on these \(capture.layerIDs.count) layers will be locked across every frame, including unselected artwork. Undo restores all locks in one step, or unlock them in Layers.")
        }
        .confirmationDialog("Delete this frame's image?", isPresented: $showingImageDeletion,
            titleVisibility: .visible, presenting: imageDeletion) { capture in
            // SwiftUI dismisses the dialog. Keep its immutable presenting data
            // alive through action dispatch; the next request replaces it.
            Button("Delete image", role: .destructive) { _ = vm.deleteImage(capture) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Only this frame's picture will be removed. Its layer and drawings stay. Undo restores the picture.")
        }
        .toolbar {
            if textInputFocused || imageFocusedField != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done typing") { textInputFocused = false; imageFocusedField = nil }
                        .accessibilityIdentifier("studio.text.keyboard-dismiss")
                }
            }
        }
    }
    
    private func imageRotateButton(_ title: String, direction: StudioImageQuarterTurn) -> some View {
        Button {
            guard let capture = vm.prepareImagePlacement() else { return }
            _ = vm.rotateImage(capture, direction: direction)
        } label: {
            Text(title).font(.specialElite(11)).frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(.white)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("studio.image-rotate." + direction.rawValue)
        .accessibilityValue("\((vm.currentFrame.preferredRasterInstance(activeLayerID: vm.activeLayerID)?.quarterTurns ?? 0) * 90) degrees clockwise")
        .disabled(vm.prepareImagePlacement() == nil)
    }

    private func imageFlipButton(_ title: String, axis: StudioReflectionAxis, id: String) -> some View {
        Button {
            guard let capture = vm.prepareImagePlacement() else { return }
            _ = vm.reflectImage(capture, axis: axis)
        } label: {
            Text(title).font(.specialElite(11)).frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(.white)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("studio.image-flip." + id)
        .accessibilityValue((axis == .horizontal ? vm.currentFrame.preferredRasterInstance(activeLayerID: vm.activeLayerID)?.reflection?.horizontal
                             : vm.currentFrame.preferredRasterInstance(activeLayerID: vm.activeLayerID)?.reflection?.vertical) == true ? "Flipped" : "Original")
        .disabled(vm.prepareImagePlacement() == nil)
    }

    @ViewBuilder
    func toolSettingsContent(_ def: ToolDef, compactHeight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            toolSpecificSettings(def, compactHeight: compactHeight)
            if [.pencil, .pen, .brush, .marker, .crayon, .eraser, .smudge, .blur, .sharpen, .dodge, .burn, .line, .rectangle, .circle, .text, .fill, .move, .lasso, .wand].contains(def.tool) {
                Button("Reset this tool") { vm.resetCurrentDrawingToolPreferences() }
                    .font(.specialElite(10))
                    .foregroundColor(.sdStudioSecondaryText)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("studio.tool-settings.reset")
            }
            if let warning = vm.toolPreferencesWarning {
                Text(warning).font(.specialElite(9)).foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private func toolSpecificSettings(_ def: ToolDef, compactHeight: Bool) -> some View {
        switch def.tool {
        // ── BRUSH / PENCIL / PEN ──
        case .pencil, .pen, .brush, .marker, .crayon:
            VStack(alignment: .leading, spacing: 8) {
                mirrorSettings
                Button { showBrushLibrary.toggle() } label: {
                    HStack {
                        Text("Brush Library: " + vm.brushFamily.title)
                            .font(.specialElite(12))
                        Spacer()
                        Image(systemName: showBrushLibrary ? "chevron.up" : "chevron.down")
                    }.foregroundColor(.white)
                }
                .accessibilityIdentifier("studio.brush-library")
                if showBrushLibrary {
                    StudioBrushLibraryView(vm: vm) { showBrushLibrary = false }
                }
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...50, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Smoothing", value: $vm.smoothing, range: 0...10, unit: "", accent: .green)
                if vm.brushFamily == .calligraphy {
                    SettingsSlider(label: "Tip Angle", value: $vm.brushTipAngle, range: 0...179, unit: "°", accent: accentColor)
                    SettingsToggle(label: "Pencil Tilt", isOn: $vm.pencilTiltEnabled, accent: accentColor)
                        .accessibilityIdentifier("studio.brush.tilt")
                    Text("Tilting Pencil widens the nib and follows its direction plus Tip Angle. Finger input uses the fixed nib. Saved per tool.")
                        .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                }
                if [.stipple, .grain, .roughPen, .airbrush, .watercolor, .neon].contains(vm.brushFamily) {
                    SettingsSlider(label: vm.brushFamily == .airbrush ? "Flow" : vm.brushFamily == .watercolor ? "Pigment" : vm.brushFamily == .neon ? "Glow" : "Texture", value: Binding(get: { vm.brushTexture * 100 }, set: { vm.brushTexture = $0 / 100 }), range: 0...100, unit: "%", accent: accentColor)
                }
                if [.stipple, .grain, .watercolor].contains(vm.brushFamily) {
                    SettingsSlider(label: "Grain", value: Binding(get: { vm.brushGrain * 100 }, set: { vm.brushGrain = $0 / 100 }), range: 0...100, unit: "%", accent: accentColor)
                }
                if vm.brushFamily == .gradient {
                    Button { vm.activePanel = .gradientEndColor } label: {
                        HStack {
                            Text("End Color")
                            Spacer()
                            Circle().fill(vm.brushGradientEndColor).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center), lineWidth: 3))
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.specialElite(11)).foregroundColor(.white)
                    .accessibilityIdentifier("studio.brush.gradient-end")
                    .accessibilityLabel("Gradient end color")
                    .accessibilityValue(vm.brushGradientEndColorHex.uppercased())
                    Text("Gradient colors use the stroke opacity.").font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                }
                SettingsToggle(label: "Pressure Sensitivity", isOn: $vm.pressureSensitivity, accent: .red)
                    .accessibilityIdentifier("studio.brush.pressure")
                Text("Uses measured Apple Pencil force when available. Finger drawing keeps a steady width. This setting is saved separately for each drawing tool.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            }
            
        // ── FILL TOOL (GREEN THEME) ──
        case .fill:
            VStack(alignment: .leading, spacing: 8) {
                if vm.hasFillImageTarget {
                    Text("Fill adds paint on the active image layer within the selected image’s alpha, crop and region mask, together with any selected drawings. Original artwork stays unchanged. Layer effects are excluded from coverage. Choose Move to deselect.")
                        .font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.sdStudioSecondaryText)
                }
                if !vm.hasFillImageTarget && !vm.selectedElementIDs.isEmpty {
                    Text("Fill paints on the active layer within the selected drawings’ shapes, excluding layer glow and blending. Original objects stay editable. Deselect in Move or Lasso to fill the whole canvas region.")
                        .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                        .accessibilityIdentifier("studio.fill.selection-coverage")
                }
                SettingsSlider(label: "Tolerance", value: $vm.fillTolerance, range: 0...128, unit: "", accent: .green)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Expand", value: $vm.fillExpand, range: -5...5, unit: "px", accent: .orange)
                SettingsSlider(label: "Gap Close", value: $vm.fillGapClose, range: 0...5, unit: "", accent: .yellow)
                    .disabled(!vm.fillContiguous)
                    .opacity(vm.fillContiguous ? 1 : 0.4)
                
                // Toggle buttons (green themed)
                VStack(spacing: 4) {
                    FillToggleButton(label: vm.fillContiguous ? "🔗 Contiguous" : "🌐 All Similar",
                                     isOn: $vm.fillContiguous, accent: .green)
                        .accessibilityIdentifier("studio.fill.contiguous")
                    FillToggleButton(label: vm.fillAntiAlias ? "✓ Anti-Alias" : "✕ No Anti-Alias",
                                     isOn: $vm.fillAntiAlias, accent: .green)
                        .accessibilityIdentifier("studio.fill.antialias")
                    FillToggleButton(label: vm.fillSampleAll ? "👁 Sample All Layers" : "📄 Current Layer Only",
                                     isOn: $vm.fillSampleAll, accent: .green)
                        .accessibilityIdentifier("studio.fill.sample-all")
                }
            }
            
        // ── ERASER (ORANGE THEME) ──
        case .eraser:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...150, unit: "px", accent: accentColor)
                
                Text("ERASER TYPE")
                    .font(.specialElite(8))
                    .foregroundColor(.sdStudioSecondaryText)
                    .tracking(2)
                
                HStack(spacing: 4) {
                    ForEach(StudioEraserMode.allCases, id: \.self) { mode in
                        Button { vm.eraserMode = mode } label: {
                            Text(mode == .hard ? "◼ Hard" : "◐ Soft")
                                .font(.specialElite(10))
                                .foregroundColor(vm.eraserMode == mode ? accentColor : .sdStudioSecondaryText)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(vm.eraserMode == mode ? accentColor.opacity(0.2) : Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(vm.eraserMode == mode ? accentColor.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                        .accessibilityIdentifier("studio.eraser.mode." + mode.rawValue)
                        .accessibilityValue(vm.eraserMode == mode ? "Selected" : "Not selected")
                    }
                }
                
                SettingsSlider(label: "Strength", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                Text(vm.selectedElementIDs.isEmpty ? "Erases this layer. Soft adds a feathered edge." : "Erases selected drawings only. Soft adds a feathered edge. Drawings with layer-wide effects require deselection.")
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                if !vm.selectedElementIDs.isEmpty {
                    Button("Deselect drawings") { vm.clearElementSelection() }
                        .font(.specialElite(11)).buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("studio.eraser.deselect")
                }
            }
            
        // ── SMUDGE (PURPLE THEME) ──
        case .smudge:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...256, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                Text("Drag existing color on the active layer. The effect is applied when you release. Deselect artwork first.")
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.smudge.instructions")
            }

        case .blur:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...256, unit: "px", accent: accentColor)
                SettingsSlider(label: "Strength", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Hardness", value: Binding(get: { vm.blurHardness * 100 }, set: { vm.blurHardness = $0 / 100 }), range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Radius", value: $vm.blurRadius, range: 0.5...32, unit: "px", accent: accentColor, fractionDigits: 1)
                Text("Soften existing artwork on the active layer. Radius controls the blur; Hardness controls its edge. Applied on release. Deselect artwork first.")
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.blur.instructions")
            }

        case .sharpen:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...256, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Hardness", value: Binding(get: { vm.sharpenHardness * 100 }, set: { vm.sharpenHardness = $0 / 100 }), range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Radius", value: $vm.sharpenRadius, range: 0.5...32, unit: "px", accent: accentColor, fractionDigits: 1)
                SettingsSlider(label: "Amount", value: Binding(get: { vm.sharpenAmount * 100 }, set: { vm.sharpenAmount = $0 / 100 }), range: 0...200, unit: "%", accent: accentColor)
                SettingsSlider(label: "Threshold", value: Binding(get: { vm.sharpenThreshold * 100 }, set: { vm.sharpenThreshold = $0 / 100 }), range: 0...100, unit: "%", accent: accentColor)
                Text("Increase contrast at existing edges on this layer. Radius sets detail size; Amount sets contrast. Threshold protects subtle texture. Applied on release. Deselect artwork first.")
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.sharpen.instructions")
            }

        case .dodge, .burn:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...256, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Hardness", value: Binding(get: { vm.dodgeBurnHardness * 100 }, set: { vm.dodgeBurnHardness = $0 / 100 }), range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Exposure", value: Binding(get: { vm.dodgeBurnExposure * 100 }, set: { vm.dodgeBurnExposure = $0 / 100 }), range: 0...100, unit: "%", accent: accentColor)
                Picker("Tonal range", selection: $vm.dodgeBurnRange) {
                    ForEach(StudioDodgeBurn.TonalRange.allCases, id: \.self) { range in
                        Text(range.rawValue.capitalized).tag(range)
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("studio.dodge-burn.range")
                    .accessibilityLabel("Tonal range")
                    .accessibilityValue(vm.dodgeBurnRange.rawValue.capitalized)
                Toggle("Protect tones", isOn: $vm.dodgeBurnProtectTones)
                    .accessibilityIdentifier("studio.dodge-burn.protect-tones")
                Text(vm.selectedTool == .dodge
                    ? "Lighten existing color on the active layer. Exposure sets up to two stops; tonal range targets brightness. Applied on release. Deselect artwork first."
                    : "Darken existing color on the active layer. Exposure sets up to two stops; tonal range targets brightness. Applied on release. Deselect artwork first.")
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.dodge-burn.instructions")
            }

        // Editable text lives in the same dismissible tool popup.
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                if vm.textDraft == nil {
                    HStack {
                        Button("New text") { if vm.beginTextEditing() { textInputFocused = true } }
                            .accessibilityIdentifier("studio.text.new")
                        Button("Edit selected") { if vm.beginTextEditing(selected: true) { textInputFocused = true } }
                            .accessibilityIdentifier("studio.text.edit")
                    }.frame(minHeight: 44)
                    Text("New text starts at canvas center. Use Move to select and position a text box, then Edit selected.")
                        .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                } else {
                    TextField("Enter text", text: $vm.textInput, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                        .focused($textInputFocused).accessibilityIdentifier("studio.text.content")
                    HStack {
                        Button("Apply") { if vm.applyTextEditing() { textInputFocused = false } }
                            .accessibilityIdentifier("studio.text.apply")
                        Button("Cancel") { textInputFocused = false; vm.cancelTextEditing() }
                            .accessibilityIdentifier("studio.text.cancel")
                        Button("Done typing") { textInputFocused = false }
                            .accessibilityIdentifier("studio.text.keyboard-done")
                    }.frame(minHeight: 44)
                }
                Picker("Font", selection: $vm.textStyle.font) {
                    ForEach(StudioTextFont.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.accessibilityIdentifier("studio.text.font")
                SettingsSlider(label: "Font Size", value: $vm.textStyle.size, range: 8...240, unit: "px", accent: accentColor)
                Picker("Alignment", selection: $vm.textStyle.alignment) {
                    ForEach(StudioTextAlignment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("studio.text.alignment")
                HStack {
                    Toggle("Bold", isOn: $vm.textStyle.bold).accessibilityIdentifier("studio.text.bold")
                    Toggle("Italic", isOn: $vm.textStyle.italic).accessibilityIdentifier("studio.text.italic")
                }.font(.specialElite(10))
                ColorPicker("Text color", selection: $vm.textPickerColor, supportsOpacity: true)
                    .font(.specialElite(12))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("studio.text.color")
                SettingsSlider(label: "Box Width", value: $vm.textStyle.boxWidth, range: 16...4096, unit: "px", accent: accentColor)
                SettingsSlider(label: "Box Height", value: $vm.textStyle.boxHeight, range: 16...4096, unit: "px", accent: accentColor)
                SettingsSlider(label: "Rotation", value: $vm.textStyle.rotation, range: -180...180, unit: "°", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                Text("Text stays editable. Content outside its box is clipped; enlarge the box to reveal it. Apply commits one undo step; Cancel leaves the artwork unchanged.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            }

        // ── LINE ──
        case .line:
            VStack(alignment: .leading, spacing: 8) {
                mirrorSettings
                SettingsSlider(label: "Stroke Width", value: $vm.strokeWidth, range: 1...20, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                Picker("Arrowheads", selection: $vm.lineArrowEnds) {
                    Text("None").tag(StudioArrowEnds.none); Text("Start").tag(StudioArrowEnds.start)
                    Text("End").tag(StudioArrowEnds.end); Text("Both").tag(StudioArrowEnds.both)
                }.pickerStyle(.segmented).accessibilityIdentifier("studio.line.arrowheads")
                if vm.lineArrowEnds != .none {
                    SettingsSlider(label: "Head Length", value: $vm.lineArrowLength, range: 1...100, unit: "px", accent: accentColor)
                        .accessibilityIdentifier("studio.line.arrow-length")
                }
                Picker("Angle snap", selection: $vm.lineAngleSnap) {
                    Text("Free").tag(0.0)
                    Text("15°").tag(15.0)
                    Text("45°").tag(45.0)
                    Text("90°").tag(90.0)
                }.pickerStyle(.segmented).accessibilityIdentifier("studio.line.angle-snap")
                    .disabled(vm.lineRulerEnabled)
                lineRulerSettings
                Text("Drag from the line's start. Angle snapping is measured in canvas coordinates.")
                    .font(.specialElite(9))
                    .foregroundColor(.sdStudioSecondaryText)
            }
            
        // ── RECTANGLE / CIRCLE ──
        case .rectangle, .circle:
            VStack(alignment: .leading, spacing: 8) {
                mirrorSettings
                Toggle(vm.selectedTool == .rectangle ? "Square" : "Perfect circle", isOn: $vm.equalShapeSides)
                    .font(.specialElite(11))
                    .accessibilityIdentifier("studio.shape.equal-sides")
                SettingsSlider(label: "Stroke Width", value: $vm.strokeWidth, range: 1...20, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                
                Text("FILL")
                    .font(.specialElite(8))
                    .foregroundColor(.sdStudioSecondaryText)
                    .tracking(2)
                
                Button { vm.shapeFilled.toggle() } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(vm.shapeFilled ? vm.strokeColor : Color.clear)
                        .frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    Text(vm.shapeFilled ? "Solid fill" : "No fill")
                        .font(.specialElite(9))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shape fill")
                .accessibilityValue(vm.shapeFilled ? "Solid" : "None")
                .accessibilityIdentifier("studio.shape.fill")
                
                if def.tool == .rectangle {
                    SettingsSlider(label: "Corner Radius", value: $vm.shapeCornerRadius, range: 0...50, unit: "px", accent: .orange)
                }
            }
            
        // ── MOVE ──
        case .move:
            if let capture = imageCrop, !vm.hasMixedArtworkSelection {
                StudioImageCropControls(vm: vm, capture: capture, focused: $imageFocusedField,
                    x: $imageX, y: $imageY, width: $imageWidth, height: $imageHeight) {
                    imageFocusedField = nil; imageCrop = nil
                }
            } else if let capture = imagePlacement, !vm.hasMixedArtworkSelection {
                StudioImagePlacementControls(vm: vm, capture: capture, focused: $imageFocusedField,
                    x: $imageX, y: $imageY, width: $imageWidth, height: $imageHeight) {
                    imageFocusedField = nil; imagePlacement = nil
                }
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(vm.hasMixedArtworkSelection ? "Selected drawings and image move together. Drag the group or use its corner and rotation handles. Select the image alone for image-specific edits." : vm.isMovingImageOnCanvas ? "Drag inside the image to move it. It stays inside the canvas. Use Position image to make it smaller first if it fills the canvas." : vm.copiedDrawingCount > 0 ? "Copied \(vm.copiedDrawingCount) drawings. Paste adds them to the current layer; drag the new selection to move it."
                     : vm.currentFrame.rasterAssetID == nil
                     ? "Tap or drag drawn artwork to move it. Tap empty canvas to clear a New selection."
                     : "Drag drawn artwork, or choose Move image on canvas for the imported picture. Select the image layer you want to edit.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.selection.guidance")
                if !vm.hasMixedArtworkSelection {
                HStack(spacing: 8) {
                    Button("Copy image") { _ = vm.copyImage() }
                        .disabled(vm.prepareImagePlacement() == nil)
                        .accessibilityIdentifier("studio.image.copy")
                    Button("Cut image") {
                        if let capture = vm.selectedImageCutCapture { _ = vm.cutSelectedImage(capture) }
                    }
                    .disabled(vm.selectedImageCutCapture == nil)
                    .accessibilityIdentifier("studio.image.cut")
                    .accessibilityLabel("Cut selected image")
                    .accessibilityHint("Cuts only the selected active-layer image. Undo restores it; Paste adds the image to a blank frame.")
                    Button("Paste image") { _ = vm.pasteImage() }
                        .disabled(!vm.canPasteImage)
                        .accessibilityIdentifier("studio.image.paste")
                }.font(.specialElite(11)).buttonStyle(.bordered).frame(minHeight: 44)
                Text("Cut requires an explicit image selection on its active, unlocked layer. It keeps drawings and linked images; Undo restores the cut image.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                if vm.hasCopiedImage {
                    Text("Image copied within this project. Paste adds a separate image layer and preserves its crop, flips and position.")
                        .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                }
                if vm.currentFrame.rasterPlacement != nil {
                    Button(vm.isMovingImageOnCanvas ? "Move drawings" : "Move image on canvas") {
                        _ = vm.setImageCanvasMove(!vm.isMovingImageOnCanvas)
                    }
                    .font(.specialElite(12)).frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(vm.isMovingImageOnCanvas ? .sdStudioActionText : .white)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("studio.image-move.target")
                    .accessibilityValue(vm.isMovingImageOnCanvas ? "Image" : "Drawings")
                    .disabled(!vm.isMovingImageOnCanvas && vm.prepareImagePlacement() == nil)
                    Button {
                        guard let capture = vm.prepareImagePlacement() else { return }
                        imageX = String(capture.original.x); imageY = String(capture.original.y)
                        imageWidth = String(capture.original.width); imageHeight = String(capture.original.height)
                        imagePlacement = capture
                    } label: {
                        Label("Position image", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .font(.specialElite(12)).foregroundColor(.white)
                    .background(Color.red.opacity(0.75)).cornerRadius(8)
                    .accessibilityIdentifier("studio.image-placement.open")
                    .disabled(vm.prepareImagePlacement() == nil)
                    Button("Crop image") {
                        guard let capture = vm.prepareImagePlacement() else { return }
                        let crop = vm.currentFrame.rasterInstance(on: capture.layerID)?.crop ?? .full
                        imageX = String(crop.x * 100); imageY = String(crop.y * 100)
                        imageWidth = String(crop.width * 100); imageHeight = String(crop.height * 100)
                        imageCrop = capture
                    }.font(.specialElite(12)).frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("studio.image-crop.open")
                        .disabled(vm.prepareImagePlacement() == nil)
                    HStack(spacing: 8) {
                        imageFlipButton("Flip image H", axis: .horizontal, id: "horizontal")
                        imageFlipButton("Flip image V", axis: .vertical, id: "vertical")
                    }
                    HStack(spacing: 8) {
                        imageRotateButton("Rotate left 90°", direction: .counterclockwise)
                        imageRotateButton("Rotate right 90°", direction: .clockwise)
                    }
                    HStack(spacing: 8) {
                        Button("Image forward") { _ = vm.orderSelected(forward: true) }
                            .accessibilityIdentifier("studio.image-order.forward")
                        Button("Image backward") { _ = vm.orderSelected(forward: false) }
                            .accessibilityIdentifier("studio.image-order.backward")
                    }
                    .font(.specialElite(11)).buttonStyle(.bordered).frame(minHeight: 44)
                    .disabled(vm.selectedImageCutCapture == nil)
                    Text("Select the image with Move to order it among drawings on the same layer. Layers keep their own order.")
                        .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                    Button("Delete image…", role: .destructive) {
                        guard let capture = vm.prepareImagePlacement() else { return }
                        imageDeletion = capture; showingImageDeletion = true
                    }
                        .font(.specialElite(12)).frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("studio.image-delete.open")
                        .disabled(vm.prepareImagePlacement() == nil)
                    if vm.prepareImagePlacement() == nil {
                        Text("Show the image layer and choose Free to edit it. Finish any pending edit or save first.")
                            .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                    }
                }
                }
                if !vm.isMovingImageOnCanvas {
                Text("SELECTION MODE")
                    .font(.specialElite(8))
                    .foregroundColor(.sdStudioSecondaryText)
                    .tracking(2)
                
                HStack(spacing: 4) {
                    ForEach(StudioViewModel.SelectionMode.allCases, id: \.self) { mode in
                        Button(action: { vm.selectionMode = mode }) {
                            Text(mode.label)
                                .font(.specialElite(9))
                                .foregroundColor(vm.selectionMode == mode ? .sdStudioActionText : .sdStudioSecondaryText)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(vm.selectionMode == mode ? Color.red.opacity(0.2) : Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(vm.selectionMode == mode ? Color.red.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                        .accessibilityIdentifier("studio.selection.mode." + mode.rawValue)
                        .accessibilityAddTraits(vm.selectionMode == mode ? .isSelected : [])
                    }
                }
                
                Text("ACTIONS")
                    .font(.specialElite(8))
                    .foregroundColor(.sdStudioSecondaryText)
                    .tracking(2)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(["📋 Copy", "✂️ Cut", "📑 Duplicate", "🗑 Delete", "↔️ Flip H", "↕️ Flip V", "⬆ Fwd", "⬇ Back", "🔒 Lock layers", "✂️ Deselect"], id: \.self) { action in
                        Button(action: {
                            if action.contains("Copy") { _ = vm.copySelected() }
                            else if action.contains("Cut") { _ = vm.cutSelected() }
                            else if action.contains("Duplicate") { _ = vm.duplicateSelected() }
                            else if action.contains("Delete") { vm.deleteSelected() }
                            else if action.contains("Deselect") { vm.clearElementSelection() }
                            else if action.contains("Flip H") { _ = vm.reflectSelected(axis: .horizontal) }
                            else if action.contains("Flip V") { _ = vm.reflectSelected(axis: .vertical) }
                            else if action.contains("Fwd") { _ = vm.orderSelected(forward: true) }
                            else if action.contains("Back") { _ = vm.orderSelected(forward: false) }
                            else if action.contains("Lock") {
                                selectionLayerLock = vm.prepareSelectionLayerLock()
                                showingSelectionLayerLock = selectionLayerLock != nil
                            }
                            else { vm.message = "This selection action is unfinished. The artwork has not changed." }
                        }) {
                            VStack(spacing: 2) {
                                Text(String(action.prefix(2)))
                                    .font(.system(size: 12))
                                Text(String(action.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                                    .font(.specialElite(7))
                                    .foregroundColor(.sdStudioSecondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .accessibilityIdentifier("studio.selection." + String(action.dropFirst(2)).trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-"))
                        .disabled(vm.selectedElementIDs.isEmpty || (action.contains("Cut") && !vm.canCutSelected) || (action.contains("Duplicate") && !vm.canDuplicateSelected) || (action.contains("Lock") && vm.prepareSelectionLayerLock() == nil))
                        .accessibilityHint(action.contains("Lock") ? "Lock layers affects all artwork on those layers in every frame. Unlock in Layers or Undo." : "")
                    }
                }
                if vm.hasMixedArtworkSelection {
                    Text("Copy, Cut and ordering include the selected drawings and image together. Forward and Back move within each layer; the layer order stays unchanged. Lock layers includes both kinds of artwork.")
                        .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                        .accessibilityIdentifier("studio.selection.mixed-limitations")
                }
                Text("Lock layers affects all artwork on those layers in every frame. Unlock in Layers or Undo.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.selection.lock-scope")
                Divider().background(Color.white.opacity(0.08))
                Text("POSITION").font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                Picker("Nudge distance", selection: $vm.selectionNudgeDistance) {
                    Text("1 px").tag(1.0); Text("10 px").tag(10.0); Text("100 px").tag(100.0)
                }.pickerStyle(.segmented).accessibilityIdentifier("studio.selection.nudge-distance")
                HStack {
                    Button("←") { _ = vm.positionSelected(dx: -vm.selectionNudgeDistance) }.accessibilityLabel("Move selection left")
                    Button("→") { _ = vm.positionSelected(dx: vm.selectionNudgeDistance) }.accessibilityLabel("Move selection right")
                    Button("↑") { _ = vm.positionSelected(dy: -vm.selectionNudgeDistance) }.accessibilityLabel("Move selection up")
                    Button("↓") { _ = vm.positionSelected(dy: vm.selectionNudgeDistance) }.accessibilityLabel("Move selection down")
                    Menu("Align") {
                        ForEach(StudioViewModel.SelectionAlignment.allCases, id: \.rawValue) { alignment in
                            Button(alignment.rawValue) { _ = vm.positionSelected(alignment: alignment) }
                        }
                    }.accessibilityIdentifier("studio.selection.align")
                }.font(.specialElite(14)).frame(minHeight: 44).disabled(vm.beginSelectionHandle() == nil)
                Text("Nudge uses canvas pixels. Align places the selected group against the canvas edges or center. Each action is one Undo step.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                Text("SCALE & ROTATE").font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                if let explanation = vm.selectionTransformExplanation {
                    Text(explanation).font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                        .accessibilityIdentifier("studio.selection.transform-reason")
                }
                if !vm.isSelectingMixedArtwork {
                    Toggle("Keep proportions", isOn: $vm.selectionPreservesAspect)
                        .font(.specialElite(12)).tint(.red)
                        .accessibilityIdentifier("studio.selection.keep-proportions")
                        .onChange(of: vm.selectionPreservesAspect) { _, _ in
                            vm.selectionHeightPercent = vm.selectionScalePercent
                        }
                }
                if !vm.selectionPreservesAspect && !vm.isSelectingMixedArtwork {
                    Text("Drag a side handle to change only width or height. Small selections use the Width and Height controls below.")
                        .font(.specialElite(10)).foregroundColor(.white.opacity(0.65))
                }
                SettingsSlider(label: vm.selectionPreservesAspect || vm.isSelectingMixedArtwork ? "Scale" : "Width",
                               value: $vm.selectionScalePercent, range: 25...400, unit: "%", accent: .red)
                if !vm.selectionPreservesAspect && !vm.isSelectingMixedArtwork {
                    SettingsSlider(label: "Height", value: $vm.selectionHeightPercent, range: 25...400, unit: "%", accent: .red)
                    Text("Corner handles now change width and height independently around the selection center.")
                        .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                }
                SettingsSlider(label: "Angle", value: $vm.selectionRotationDegrees, range: -180...180, unit: "°", accent: .red)
                HStack {
                    Button(action: { _ = vm.transformSelected() }) {
                        Text("Apply transform").frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundColor(.white).background(Color.red.opacity(0.8)).cornerRadius(8)
                    }
                    .accessibilityIdentifier("studio.selection.transform-apply")
                    .disabled(vm.beginSelectionHandle() == nil)
                    Button(action: { vm.resetSelectionTransform() }) {
                        Text("Reset values").frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundColor(.white.opacity(0.8)).background(Color.white.opacity(0.08)).cornerRadius(8)
                    }
                    .accessibilityIdentifier("studio.selection.transform-reset")
                }.font(.specialElite(10))
                Text("Drag the canvas corner handles to resize or the red handle to rotate. These sliders offer the same group transform. Apply makes one undo step; Reset only clears these controls.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                }
            }
            
            }
        // ── LASSO ──
        case .wand:
            VStack(alignment: .leading, spacing: 10) {
                Text("Image pixels").font(.specialElite(16))
                Text("Select an image layer, close this popup and tap its visible pixels. Sample the image colors or the visible canvas. Only the active image’s pixels are edited; other layers remain untouched. The active image layer must be normal and fully opaque, without drawings or effects.").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption))
                Picker("Region", selection: $vm.wandMode) {
                    ForEach(StudioImageRegionService.Mode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented).accessibilityIdentifier("studio.wand.mode")
                HStack { Text("Tolerance"); Slider(value: $vm.wandTolerance, in: 0...128, step: 1); Text("\(Int(vm.wandTolerance))") }
                    .accessibilityIdentifier("studio.wand.tolerance")
                Picker("Sample colors", selection: $vm.wandSampleVisibleCanvas) {
                    Text("Active image").tag(false)
                    Text("Visible canvas").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("studio.wand.sampling")
                Toggle("Connected pixels only", isOn: $vm.wandContiguous).accessibilityIdentifier("studio.wand.contiguous")
                HStack {
                    Button("Select all pixels") { Task { await vm.changeImageRegionMembership(.all) } }
                        .accessibilityIdentifier("studio.wand.select-all")
                    Button("Invert selection") { Task { await vm.changeImageRegionMembership(.invert) } }
                        .accessibilityIdentifier("studio.wand.invert")
                }.frame(minHeight: 44)
                    .disabled(vm.wandWorking || (try? vm.captureImageRegion()) == nil)
                HStack {
                    Button("Grow 1 px") { Task { await vm.changeImageRegionMembership(.grow) } }
                        .accessibilityIdentifier("studio.wand.grow")
                    Button("Shrink 1 px") { Task { await vm.changeImageRegionMembership(.shrink) } }
                        .accessibilityIdentifier("studio.wand.shrink")
                }.frame(minHeight: 44).disabled(!vm.canEditImageRegion)
                Text("Grow and Shrink adjust the boundary by one source-image pixel, including diagonal neighbors. Shrink can clear a thin selection. All and Invert stay within visible image pixels and the crop.")
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                Text("\(vm.wandSelectedPixels) source pixels selected").accessibilityIdentifier("studio.wand.count")
                if let data = vm.wandPreviewPNG, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(height: 100)
                        .accessibilityLabel("Selected source pixels before crop and canvas transforms")
                }
                if vm.wandWorking { ProgressView("Selecting image pixels") }
                HStack {
                    Button("Copy pixels") { _ = vm.applyImageRegion(.copy) }.disabled(!vm.canEditImageRegion)
                        .accessibilityIdentifier("studio.wand.copy")
                    Button("Cut pixels") { _ = vm.applyImageRegion(.cut) }.disabled(!vm.canEditImageRegion)
                        .accessibilityIdentifier("studio.wand.cut")
                    Button("Delete pixels") { _ = vm.applyImageRegion(.delete) }.disabled(!vm.canEditImageRegion)
                        .accessibilityIdentifier("studio.wand.delete")
                }.frame(minHeight: 44)
                Button("Move on canvas") { _ = vm.applyImageRegion(.lift) }
                    .frame(minHeight: 44).disabled(!vm.canEditImageRegion)
                    .accessibilityIdentifier("studio.wand.lift")
                Text("Lift selected pixels onto their own layer, then drag, resize or rotate with Move. Undo restores the original image.")
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                Text("Move selected pixels in canvas units. Original bytes and unselected images stay preserved.").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption))
                HStack {
                    TextField("X offset", value: $vm.wandMoveX, format: .number).keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("studio.wand.dx")
                    TextField("Y offset", value: $vm.wandMoveY, format: .number).keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("studio.wand.dy")
                }.textFieldStyle(.roundedBorder)
                Button("Move pixels") { _ = vm.applyImageRegion(.move) }
                    .frame(minHeight: 44).disabled(!vm.canEditImageRegion || (vm.wandMoveX == 0 && vm.wandMoveY == 0))
                    .accessibilityIdentifier("studio.wand.move")
                Button("Cancel selection") { vm.clearImageRegion() }.frame(minHeight: 44)
                    .accessibilityIdentifier("studio.wand.cancel")
            }
        case .lasso:
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    Picker("Selection target", selection: $vm.areaSelectionTarget) {
                        ForEach(StudioViewModel.AreaSelectionTarget.allCases, id: \.self) { target in
                            Text(target.label).tag(target)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(vm.areaSelectionTarget.label).font(.specialElite(12))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                    }
                    .foregroundColor(.sdStudioActionText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Selection target")
                .accessibilityValue(vm.areaSelectionTarget.label)
                .accessibilityIdentifier("studio.selection.target")
                Text(areaSelectionGuidance)
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                Text(areaSelectionCount)
                    .font(.specialElite(11)).foregroundColor(.sdStudioActionText)
                    .accessibilityIdentifier("studio.selection.count")
                HStack(spacing: 4) {
                    ForEach(StudioAreaSelectionKind.allCases, id: \.self) { kind in
                        Button(kind.label) { vm.areaSelectionKind = kind }
                            .font(.specialElite(10)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundColor(vm.areaSelectionKind == kind ? .sdStudioActionText : .sdStudioSecondaryText)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("studio.selection.kind." + kind.rawValue)
                            .accessibilityAddTraits(vm.areaSelectionKind == kind ? .isSelected : [])
                    }
                }
                if vm.areaSelectionTarget != .imagePixels {
                HStack(spacing: 4) {
                    ForEach(StudioViewModel.SelectionMode.allCases, id: \.self) { mode in
                        Button(mode.label) { vm.selectionMode = mode }
                            .font(.specialElite(10)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundColor(vm.selectionMode == mode ? .sdStudioActionText : .sdStudioSecondaryText)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("studio.selection.mode." + mode.rawValue)
                            .accessibilityAddTraits(vm.selectionMode == mode ? .isSelected : [])
                    }
                }
                }
                if vm.areaSelectionTarget != .image && vm.areaSelectionTarget != .imagePixels {
                HStack(spacing: 8) {
                    Button("Select all") { _ = vm.selectVisibleArtwork() }
                        .accessibilityIdentifier("studio.selection.all")
                    Button("Invert") { _ = vm.selectVisibleArtwork(inverting: true) }
                        .accessibilityIdentifier("studio.selection.invert")
                }.font(.specialElite(11)).buttonStyle(.bordered).frame(minHeight: 44)
                }
                if vm.areaSelectionKind == .freehand {
                    SettingsSlider(label: "Smoothness", value: $vm.areaSelectionSmoothing, range: 0...10, unit: "px", accent: .red)
                }
                if vm.areaSelectionTarget == .drawings || (vm.areaSelectionTarget == .artwork && !vm.selectedElementIDs.isEmpty) {
                HStack(spacing: 4) {
                    Button("Copy") { _ = vm.copySelected() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("studio.lasso.copy")
                        .disabled(vm.hasMixedArtworkSelection && !vm.canCopyBottomSelection)
                    Button("Cut") { _ = vm.cutSelected() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(!vm.canCutSelected)
                        .accessibilityIdentifier("studio.lasso.cut")
                    Button("Delete") { vm.deleteSelected() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("studio.lasso.delete")
                    Button("Deselect") { vm.clearElementSelection() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("studio.lasso.deselect")
                }.font(.specialElite(11)).frame(minHeight: 44)
                    .disabled(vm.selectedElementIDs.isEmpty)
                if vm.hasMixedArtworkSelection {
                    Text("Move transforms the selected drawings and image together. Copy and Cut preserve the group; Cut requires unlocked layers.")
                        .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                }
                } else if vm.areaSelectionTarget == .imagePixels {
                    if vm.wandWorking {
                        ProgressView("Selecting image pixels…").font(.specialElite(11))
                        Button("Cancel selection") { vm.clearImageRegion() }
                    }
                    Text("Creates a separate masked image layer and switches to Move. Undo restores the unsplit image. Requires a normal, fully opaque, unlocked image layer without glow or drawings; up to 4 megapixels.")
                        .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                } else {
                    Button("Deselect image") { vm.deselectAreaImage() }
                        .disabled(vm.selectedAreaImageCorners == nil)
                        .accessibilityIdentifier("studio.lasso.image-deselect")
                    Text("Use Move for image copy, Cut, paste, delete and transforms. Cut requires this image’s active, unlocked layer.")
                        .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                }
                if vm.areaSelectionKind == .polygon {
                    Text("Tap canvas corners, then Finish to close the outline. \(vm.currentPolygonSelectionVertices.count) points.")
                        .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                    HStack(spacing: 4) {
                        Button("Back") { vm.removeLastPolygonSelectionVertex() }
                            .disabled(vm.currentPolygonSelectionVertices.isEmpty)
                            .accessibilityIdentifier("studio.selection.polygon.back")
                        Button("Finish") { _ = vm.finishPolygonSelection() }
                            .disabled(vm.currentPolygonSelectionVertices.count < 3)
                            .accessibilityIdentifier("studio.selection.polygon.finish")
                        Button("Cancel") { vm.cancelPolygonSelection() }
                            .disabled(vm.currentPolygonSelectionVertices.isEmpty)
                            .accessibilityIdentifier("studio.selection.polygon.cancel")
                    }.font(.specialElite(11)).buttonStyle(.bordered).frame(minHeight: 44)
                }
                Text("Magnetic, Smart and feathered pixel selection are unavailable.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            }

        case .hand, .zoom:
            VStack(alignment: .leading, spacing: 8) {
                if !compactHeight {
                Text("Zoom: \(Int((vm.canvasScale * 100).rounded()))%")
                    .font(.specialElite(12)).foregroundColor(.white)
                    .accessibilityIdentifier("studio.tool-settings.zoom-value")
                }
                HStack(spacing: 8) {
                    zoomControl("minus", "Zoom out", "zoom-out") { vm.zoomOut() }
                    zoomControl("plus", "Zoom in", "zoom-in") { vm.zoomIn() }
                    zoomControl("arrow.up.left.and.arrow.down.right", "FIT", "fit") { vm.zoomFit() }
                }
                Text("Use two fingers to pan and pinch to zoom. Hand also pans with one finger. FIT recenters the canvas.")
                    .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
            }
        default:
            EmptyView()
        }
    }
    
    private var areaSelectionGuidance: String {
        switch vm.areaSelectionTarget {
        case .imagePixels: return "Outline part of the active image. Selected source pixels become a movable fragment with resize and rotation handles; unselected pixels stay in place."
        case .drawings: return "Enclose whole drawings. Move activates automatically: drag inside the selection box or use its resize and rotation handles. Lasso includes editable and historical text."
        case .image: return "Enclose the whole image on the active visible, unlocked layer. Move activates automatically with image transform handles. Choose Drawings + image to include drawings."
        case .artwork: return "Enclose whole drawings and the image on its active visible, unlocked layer. Move activates automatically to transform the group. Hidden or locked artwork is excluded."
        }
    }
    private var areaSelectionCount: String {
        switch vm.areaSelectionTarget {
        case .imagePixels: return vm.wandWorking ? "Preparing movable pixels" : "New pixel selection"
        case .drawings: return "\(vm.selectedElementIDs.count) drawings selected"
        case .image: return "\(vm.selectedAreaImageCorners == nil ? 0 : 1) image selected"
        case .artwork: return "\(vm.selectedArtworkCount) artwork items selected · \(vm.selectedElementIDs.count) drawings, \(vm.selectedAreaImageCorners == nil ? 0 : 1) image"
        }
    }

    private var mirrorSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Mirror", selection: $vm.mirrorMode) {
                ForEach(StudioMirrorMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }.accessibilityIdentifier("studio.drawing.mirror")
            if vm.mirrorMode != .off {
                Text(vm.mirrorMode == .both ? "Four editable copies around the canvas center; one Undo step." : "Two editable copies across the canvas center; one Undo step.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            }
        }.font(.specialElite(11))
    }

    private var lineRulerSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Ruler", isOn: $vm.lineRulerEnabled)
                .accessibilityIdentifier("studio.line.ruler")
            if vm.lineRulerEnabled {
                SettingsSlider(label: "Angle", value: $vm.lineRulerAngle, range: -180...180, unit: "°", accent: .red)
                Toggle("Fixed length", isOn: $vm.lineRulerFixedLength)
                    .accessibilityIdentifier("studio.line.ruler-fixed-length")
                if vm.lineRulerFixedLength {
                    SettingsSlider(label: "Length", value: $vm.lineRulerLength, range: 1...4096, unit: "px", accent: .red)
                }
                Text("Drag either way along the ruler. With Fixed length, tapping also places a line. Lines stop at the canvas edge. The blue guide is never exported.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            }
        }.font(.specialElite(11))
    }

    private func zoomControl(_ icon: String, _ label: String, _ identifier: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14))
                Text(label).font(.specialElite(9))
            }.frame(maxWidth: .infinity, minHeight: 44)
                .foregroundColor(.white)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel(label).accessibilityIdentifier("studio.tool-settings." + identifier)
    }

    var opacityBinding: Binding<Double> {
        Binding(
            get: { vm.toolOpacity * 100 },
            set: { vm.toolOpacity = $0 / 100 }
        )
    }
}

// MARK: - Settings Slider (matches video: label + value, slider underneath)
struct SettingsSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let accent: Color
    var fractionDigits: Int = 0
    private var displayedValue: String {
        fractionDigits == 0 ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text(label + ": ").font(.specialElite(10)) +
             Text(displayedValue + unit).font(.specialElite(10)))
                .foregroundColor(.sdStudioSecondaryText)
            
            Slider(value: $value, in: range)
                .tint(accent)
                // Keep the native thumb and its whole touch region inside the
                // scroll content rather than constraining the control to the
                // six-point visual track height.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(label)
                .accessibilityValue("\(displayedValue)\(unit)")
                .accessibilityIdentifier("studio.setting." + label.lowercased().replacingOccurrences(of: " ", with: "-"))
        }
    }
}

// MARK: - Settings Toggle (matches video: label + red toggle)
struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool
    let accent: Color
    
    var body: some View {
        HStack {
            Text(label)
                .font(.specialElite(10))
                .foregroundColor(.sdStudioSecondaryText)
            Spacer()
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .tint(accent)
                .frame(minHeight: 44)
        }
    }
}

// MARK: - Fill Toggle Button (green themed)
struct FillToggleButton: View {
    let label: String
    @Binding var isOn: Bool
    let accent: Color
    
    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(label)
                .font(.specialElite(10))
                .foregroundColor(isOn ? accent : .sdStudioSecondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isOn ? accent.opacity(0.15) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isOn ? accent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                )
        }
    }
}

// ToolSettingsPanel wrapper kept for backward compat
struct ToolSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View { FloatingToolSettingsPanel(vm: vm) }
}

/// One persistent scroll container keeps focused fields alive as the keyboard
/// changes available height. Content measurement still fits short tool popups.
private struct ToolSettingsContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ToolSettingsContentLayout<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content().fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ToolSettingsContentHeight.self, value: geometry.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(maximumHeight, contentHeight ?? maximumHeight))
        .onPreferenceChange(ToolSettingsContentHeight.self) { height in
            // A transient/default zero preference is not the content's size.
            // Accepting it collapses the viewport and prevents measurement from
            // recovering. Keep the last positive size (or initial bound) instead.
            if height.isFinite && height > 0 { contentHeight = height }
        }
    }
}

private enum StudioImagePlacementField: String { case x, y, width, height }

/// Draft fields live only in the existing tool popup. Apply commits the same
/// typed command available to Studio automation; dismissal never edits content.
private struct StudioImagePlacementControls: View {
    @ObservedObject var vm: StudioViewModel
    let capture: StudioViewModel.ImagePlacementCapture
    let dismiss: () -> Void
    @FocusState.Binding private var fieldFocused: StudioImagePlacementField?
    @Binding private var x: String
    @Binding private var y: String
    @Binding private var width: String
    @Binding private var height: String
    @State private var rotationDegrees: Double

    init(vm: StudioViewModel, capture: StudioViewModel.ImagePlacementCapture, focused: FocusState<StudioImagePlacementField?>.Binding,
         x: Binding<String>, y: Binding<String>, width: Binding<String>, height: Binding<String>, dismiss: @escaping () -> Void) {
        self.vm = vm; self.capture = capture; self.dismiss = dismiss; self._fieldFocused = focused
        _x = x; _y = y; _width = width; _height = height
        _rotationDegrees = State(initialValue: capture.rotationDegrees)
    }
    private var proposed: StudioRasterPlacement? {
        guard let x = Double(x), let y = Double(y), let width = Double(width), let height = Double(height),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0 else { return nil }
        let value = StudioRasterPlacement(x: x, y: y, width: width, height: height)
        guard (try? StudioImageRotationGeometry(placement: value, degrees: rotationDegrees)
            .validate(canvasWidth: capture.canvasWidth, canvasHeight: capture.canvasHeight)) != nil else { return nil }
        return value
    }
    private func set(_ value: StudioRasterPlacement) {
        x = String(value.x); y = String(value.y); width = String(value.width); height = String(value.height)
    }
    private func field(_ name: String, _ value: Binding<String>, focus: StudioImagePlacementField) -> some View {
        HStack {
            Text(name).font(.specialElite(12)).frame(width: 52, alignment: .leading)
            TextField(name, text: value).keyboardType(.decimalPad).focused($fieldFocused, equals: focus)
                .textFieldStyle(.roundedBorder).foregroundColor(.primary)
                .accessibilityIdentifier("studio.image-placement." + name.lowercased())
            Text("px").foregroundColor(.sdStudioSecondaryText)
        }.font(.specialElite(12))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IMAGE POSITION").font(.specialElite(12)).foregroundColor(.white)
            field("X", $x, focus: .x); field("Y", $y, focus: .y)
            field("Width", $width, focus: .width); field("Height", $height, focus: .height)
            SettingsSlider(label: "Additional angle", value: $rotationDegrees, range: -180...180, unit: "°", accent: .red)
                .accessibilityIdentifier("studio.image-placement.angle")
            HStack {
                Button("Half size") {
                    guard let p = proposed else { return }
                    set(.init(x: p.x + p.width / 4, y: p.y + p.height / 4, width: p.width / 2, height: p.height / 2))
                }.accessibilityIdentifier("studio.image-placement.half").disabled(proposed == nil)
                Spacer()
                Button("Fit canvas") {
                    let p = capture.fitted
                    if let fit = try? StudioImageRotationGeometry(placement: p, degrees: rotationDegrees)
                        .fitted(canvasWidth: capture.canvasWidth, canvasHeight: capture.canvasHeight, allowingShrink: true, fillCanvas: true) { set(fit) }
                }.accessibilityIdentifier("studio.image-placement.fit")
            }.frame(minHeight: 44)
            if proposed == nil {
                Text("Use positive dimensions and keep the image inside the canvas.")
                    .foregroundColor(.orange).font(.specialElite(10))
            }
            Text("Apply changes position, size and angle in one Undo step. Width and Height describe the image before this additional angle; existing 90° turns stay intact. All rotated corners must fit. Move image handles resize the displayed bounds with fixed proportions. Originals stay editable.")
                .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            HStack {
                Button("Apply image") {
                    guard let value = proposed else { return }
                    if vm.placeImage(capture, at: value, rotationDegrees: rotationDegrees) { dismiss() }
                }.accessibilityIdentifier("studio.image-placement.apply")
                    .disabled(proposed == nil || vm.prepareImagePlacement() != capture)
                Spacer()
                Button("Cancel", action: dismiss).accessibilityIdentifier("studio.image-placement.cancel")
            }.frame(minHeight: 44)
            if vm.prepareImagePlacement() != capture {
                Text("Studio changed. Cancel and open Position image again.")
                    .font(.specialElite(10)).foregroundColor(.orange)
            }
        }.font(.specialElite(11)).foregroundColor(.white.opacity(0.85))
    }
}

private struct StudioImageCropControls: View {
    @ObservedObject var vm: StudioViewModel
    let capture: StudioViewModel.ImagePlacementCapture
    @FocusState.Binding var focused: StudioImagePlacementField?
    @Binding var x: String
    @Binding var y: String
    @Binding var width: String
    @Binding var height: String
    let dismiss: () -> Void
    @State private var presetError: String?
    @State private var preview: CGImage?
    @State private var dragOrigin: StudioImageCrop?
    @State private var dragSize: CGSize?
    @State private var dragCorner: Int?
    @GestureState private var dragging = false

    private var proposed: StudioImageCrop? {
        guard let x = Double(x), let y = Double(y), let width = Double(width), let height = Double(height) else { return nil }
        let crop = StudioImageCrop(x: x / 100, y: y / 100, width: width / 100, height: height / 100)
        return (try? crop.validate()) != nil ? crop : nil
    }
    private func loadPreview() {
        preview = nil
        guard let data = vm.rasterData(capture.assetID), data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width <= 640, image.height <= 640 else { return }
        preview = image
    }
    private func previewBounds(_ image: CGImage, size: CGSize) -> CGRect {
        let ratio = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let fitted = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
    }
    private func moveDraft(_ crop: StudioImageCrop, dx: Double, dy: Double) {
        guard vm.prepareImagePlacement() == capture, let moved = try? crop.translated(dx: dx, dy: dy) else { return }
        focused = nil; presetError = nil
        x = String(moved.x * 100); y = String(moved.y * 100)
    }
    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }
    private func resizeDraft(_ crop: StudioImageCrop, corner: Int, dx: Double, dy: Double) {
        guard vm.prepareImagePlacement() == capture,
              let resized = try? crop.resized(left: corner % 2 == 0, top: corner < 2, dx: dx, dy: dy) else { return }
        focused = nil; presetError = nil
        x = String(resized.x * 100); y = String(resized.y * 100)
        width = String(resized.width * 100); height = String(resized.height * 100)
    }
    private func nudge(_ dx: Double, _ dy: Double) {
        if let crop = proposed { moveDraft(crop, dx: dx, dy: dy) }
    }
    @ViewBuilder private var cropPreview: some View {
        if let preview {
            GeometryReader { geometry in
            Canvas { context, size in
                let bounds = previewBounds(preview, size: size)
                context.draw(Image(decorative: preview, scale: 1), in: bounds)
                if let crop = proposed {
                    let rect = CGRect(x: bounds.minX + bounds.width * crop.x, y: bounds.minY + bounds.height * crop.y,
                        width: bounds.width * crop.width, height: bounds.height * crop.height)
                    var outside = Path(bounds); outside.addRect(rect)
                    context.fill(outside, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
                    context.stroke(Path(rect), with: .color(.red), lineWidth: 2)
                    for point in corners(rect) {
                        let handle = Path(CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                        context.fill(handle, with: .color(.white))
                        context.stroke(handle, with: .color(.red), lineWidth: 1)
                    }
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .updating($dragging) { _, value, _ in value = true }
                    .onChanged { value in
                        guard vm.prepareImagePlacement() == capture, let crop = proposed else { return }
                        let bounds = previewBounds(preview, size: geometry.size)
                        guard bounds.width > 0, bounds.height > 0 else { return }
                        if dragOrigin == nil {
                            let rect = CGRect(x: bounds.minX + bounds.width * crop.x, y: bounds.minY + bounds.height * crop.y,
                                width: bounds.width * crop.width, height: bounds.height * crop.height)
                            let nearest = corners(rect).enumerated().filter {
                                hypot($0.element.x - value.startLocation.x, $0.element.y - value.startLocation.y) <= 22
                            }.min {
                                hypot($0.element.x - value.startLocation.x, $0.element.y - value.startLocation.y) <
                                hypot($1.element.x - value.startLocation.x, $1.element.y - value.startLocation.y)
                            }?.offset
                            guard nearest != nil || rect.contains(value.startLocation) else { return }
                            dragOrigin = crop; dragSize = geometry.size; dragCorner = nearest
                        }
                        guard let origin = dragOrigin, dragSize == geometry.size else { return }
                        let dx = Double(value.translation.width / bounds.width), dy = Double(value.translation.height / bounds.height)
                        if let corner = dragCorner { resizeDraft(origin, corner: corner, dx: dx, dy: dy) }
                        else { moveDraft(origin, dx: dx, dy: dy) }
                    }
                    .onEnded { _ in dragOrigin = nil; dragSize = nil; dragCorner = nil })
            }.frame(height: 180).background(Color.gray.opacity(0.18))
                .onChange(of: dragging) { active in if !active { dragOrigin = nil; dragSize = nil; dragCorner = nil } }
                .accessibilityAction(named: "Move crop left") { nudge(-0.01, 0) }
                .accessibilityAction(named: "Move crop right") { nudge(0.01, 0) }
                .accessibilityAction(named: "Move crop up") { nudge(0, -0.01) }
                .accessibilityAction(named: "Move crop down") { nudge(0, 0.01) }
                .accessibilityLabel("Original image crop preview. Drag inside the red outline to move, or drag a corner to resize the draft crop before rotation or flips.")
                .accessibilityIdentifier("studio.image-crop.preview")
        } else {
            Text("Image preview unavailable. Crop values remain editable.")
                .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
        }
    }
    private func preset(_ aspect: Double) {
        guard vm.prepareImagePlacement() == capture,
              let source = vm.originalImageSource(capture.assetID), let current = proposed else {
            presetError = "Enter a valid crop or restore Full image before choosing a ratio."
            return
        }
        do {
            let crop = try current.fitting(aspect: aspect, sourceWidth: source.normalizedWidth, sourceHeight: source.normalizedHeight)
            focused = nil
            x = String(crop.x * 100); y = String(crop.y * 100)
            width = String(crop.width * 100); height = String(crop.height * 100)
            presetError = nil
        } catch { presetError = "This ratio would make the crop smaller than 1%. Restore Full image or use a wider ratio." }
    }
    private func field(_ name: String, _ value: Binding<String>, _ key: StudioImagePlacementField) -> some View {
        HStack {
            Text(name).font(.specialElite(12)).frame(width: 52, alignment: .leading)
            TextField(name, text: value).keyboardType(.decimalPad).focused($focused, equals: key)
                .textFieldStyle(.roundedBorder).foregroundColor(.primary)
                .accessibilityIdentifier("studio.image-crop." + name.lowercased())
            Text("%").foregroundColor(.sdStudioSecondaryText)
        }.font(.specialElite(12))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CROP ORIGINAL IMAGE").font(.specialElite(12)).foregroundColor(.white)
            cropPreview
            Menu("Aspect ratio") {
                Button("Square · 1:1") { preset(1) }
                Button("Landscape · 4:3") { preset(4.0 / 3) }
                Button("Portrait · 3:4") { preset(3.0 / 4) }
                Button("Widescreen · 16:9") { preset(16.0 / 9) }
                Button("Vertical · 9:16") { preset(9.0 / 16) }
            }.font(.specialElite(12)).frame(minHeight: 44)
                .disabled(vm.prepareImagePlacement() != capture)
                .accessibilityIdentifier("studio.image-crop.aspect")
            Text("Ratios center inside the entered crop. Drag inside the preview outline to reposition it. Drag a corner to resize freely; this can change the preset ratio. Apply commits these draft values.")
                .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            if let presetError { Text(presetError).font(.specialElite(11)).foregroundColor(.orange) }
            field("Left", $x, .x); field("Top", $y, .y)
            field("Width", $width, .width); field("Height", $height, .height)
            Text("Percentages refer to the upright original before flips and rotation. Apply keeps the image centered and preserves proportions. Originals remain available for Undo or restoring the full image.")
                .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            Button("Full image") { presetError = nil; x = "0"; y = "0"; width = "100"; height = "100" }
                .frame(minHeight: 44).accessibilityIdentifier("studio.image-crop.full")
            if proposed == nil { Text("Keep the crop inside 100%, at least 1% wide and high.").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.orange) }
            HStack {
                Button("Apply crop") {
                    guard let crop = proposed else { return }
                    if vm.cropImage(capture, crop: crop) { dismiss() }
                }.disabled(proposed == nil || vm.prepareImagePlacement() != capture)
                    .accessibilityIdentifier("studio.image-crop.apply")
                Spacer()
                Button("Cancel", action: dismiss).accessibilityIdentifier("studio.image-crop.cancel")
            }.frame(minHeight: 44)
            if vm.prepareImagePlacement() != capture {
                Text("Studio changed. Cancel and open Crop image again.").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.orange)
            }
        }
        .task(id: capture.assetID) { loadPreview() }
        .onDisappear { preview = nil }
    }
}
