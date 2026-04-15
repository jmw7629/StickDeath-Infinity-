// RigToolPanel.swift
// Sub-tools panel for Rig/Bone mode — appears in left strip
// Stick Nodes-inspired bone editing

import SwiftUI

// MARK: - Rig Sub-Tool
enum RigSubTool: String, CaseIterable {
    case select     // Select & move bones/joints
    case addBone    // Tap joint → drag to create new bone
    case addJoint   // Tap bone to split it (add joint in middle)
    case deleteBone // Tap bone to delete
    case ikDrag     // IK-aware dragging (move endpoint, chain follows)
    case pinJoint   // Pin a joint in place (IK anchor)
    case style      // Edit bone visual style

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .addBone: return "line.diagonal"
        case .addJoint: return "plus.circle"
        case .deleteBone: return "minus.circle"
        case .ikDrag: return "arrow.triangle.branch"
        case .pinJoint: return "pin.fill"
        case .style: return "paintbrush.pointed"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select"
        case .addBone: return "Add"
        case .addJoint: return "Joint"
        case .deleteBone: return "Delete"
        case .ikDrag: return "IK"
        case .pinJoint: return "Pin"
        case .style: return "Style"
        }
    }
}

// MARK: - Rig Tool Panel (Left Strip Sub-Tools)
struct RigToolPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var showBoneProperties = false
    @State private var showRigTemplates = false
    @State private var showIKChains = false

    var body: some View {
        VStack(spacing: 4) {
            // Sub-tools
            ForEach(RigSubTool.allCases, id: \.self) { tool in
                rigToolButton(tool)
            }

            Divider()
                .frame(width: 28)
                .background(Color.white.opacity(0.2))

            // Bone style quick-pick (visible when bone selected)
            if vm.selectedBone != nil {
                ForEach(BoneStyle.allCases, id: \.self) { style in
                    boneStyleButton(style)
                }

                Divider()
                    .frame(width: 28)
                    .background(Color.white.opacity(0.2))
            }

            // Bone color (when bone selected)
            if vm.selectedBone != nil {
                ColorPicker("", selection: boneColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30, height: 30)

                // Thickness slider
                Button { showBoneProperties = true } label: {
                    VStack(spacing: 1) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.white)
                            .frame(width: 18, height: max(2, vm.selectedBone?.thickness ?? 3))
                    }
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()
                .frame(width: 28)
                .background(Color.white.opacity(0.2))

            // IK Chains
            Button { showIKChains = true } label: {
                VStack(spacing: 2) {
                    Image(systemName: "link")
                        .font(.system(size: 13))
                        .foregroundStyle(.cyan)
                    Text("IK")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 30, height: 36)
            }

            // Rig templates
            Button { showRigTemplates = true } label: {
                VStack(spacing: 2) {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                    Text("Rigs")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 30, height: 36)
            }

            // Toggle bone visibility
            Button {
                vm.toggleBoneVisibility()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: vm.showBoneOverlay ? "eye.fill" : "eye.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(vm.showBoneOverlay ? .green : .gray)
                    Text("Bones")
                        .font(.system(size: 8))
                        .foregroundStyle(.gray)
                }
                .frame(width: 30, height: 36)
            }
        }
        .sheet(isPresented: $showBoneProperties) {
            if let bone = vm.selectedBone {
                BonePropertiesSheet(vm: vm, bone: bone)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showRigTemplates) {
            RigTemplatesSheet(vm: vm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showIKChains) {
            IKChainsSheet(vm: vm)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    var boneColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: vm.selectedBone?.color ?? "#FFFFFF") },
            set: { newColor in vm.updateSelectedBoneColor(newColor.toHex()) }
        )
    }

    func rigToolButton(_ tool: RigSubTool) -> some View {
        Button {
            vm.rigSubTool = tool
            HapticManager.shared.buttonTap()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: tool.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(vm.rigSubTool == tool ? .red : .white.opacity(0.6))
                Text(tool.label)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(vm.rigSubTool == tool ? .red : .white.opacity(0.4))
            }
            .frame(width: 30, height: 32)
            .background(vm.rigSubTool == tool ? Color.red.opacity(0.2) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    func boneStyleButton(_ style: BoneStyle) -> some View {
        Button {
            vm.updateSelectedBoneStyle(style)
            HapticManager.shared.buttonTap()
        } label: {
            Image(systemName: style.icon)
                .font(.system(size: 11))
                .foregroundStyle(vm.selectedBone?.style == style ? .red : .white.opacity(0.5))
                .frame(width: 26, height: 26)
                .background(vm.selectedBone?.style == style ? Color.red.opacity(0.2) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

// MARK: - Bone Properties Sheet
struct BonePropertiesSheet: View {
    @ObservedObject var vm: EditorViewModel
    let bone: Bone

    @State private var thickness: CGFloat
    @State private var locked: Bool
    @State private var hasConstraint: Bool
    @State private var minAngle: CGFloat
    @State private var maxAngle: CGFloat
    @State private var stiffness: CGFloat

    init(vm: EditorViewModel, bone: Bone) {
        self.vm = vm
        self.bone = bone
        _thickness = State(initialValue: bone.thickness)
        _locked = State(initialValue: bone.locked)
        _hasConstraint = State(initialValue: bone.angleConstraint != nil)
        _minAngle = State(initialValue: bone.angleConstraint?.minAngle ?? -180)
        _maxAngle = State(initialValue: bone.angleConstraint?.maxAngle ?? 180)
        _stiffness = State(initialValue: bone.angleConstraint?.stiffness ?? 0.5)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    HStack {
                        Text("Thickness")
                        Slider(value: $thickness, in: 1...12, step: 0.5) {
                            Text("Thickness")
                        }
                        .onChange(of: thickness) { _, val in vm.updateSelectedBoneThickness(val) }
                        Text("\(thickness, specifier: "%.1f")pt")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40)
                    }

                    Picker("Style", selection: Binding(
                        get: { bone.style },
                        set: { vm.updateSelectedBoneStyle($0) }
                    )) {
                        ForEach(BoneStyle.allCases, id: \.self) { style in
                            Label(style.label, systemImage: style.icon).tag(style)
                        }
                    }
                }

                Section("Constraints") {
                    Toggle("Lock Position", isOn: $locked)
                        .onChange(of: locked) { _, val in vm.updateSelectedBoneLocked(val) }

                    Toggle("Angle Constraint", isOn: $hasConstraint)

                    if hasConstraint {
                        HStack {
                            Text("Min °")
                            Slider(value: $minAngle, in: -180...0) { Text("Min") }
                            Text("\(Int(minAngle))°")
                                .font(.caption.monospacedDigit()).frame(width: 40)
                        }
                        HStack {
                            Text("Max °")
                            Slider(value: $maxAngle, in: 0...180) { Text("Max") }
                            Text("\(Int(maxAngle))°")
                                .font(.caption.monospacedDigit()).frame(width: 40)
                        }
                        HStack {
                            Text("Stiffness")
                            Slider(value: $stiffness, in: 0...1) { Text("Stiffness") }
                            Text("\(stiffness, specifier: "%.1f")")
                                .font(.caption.monospacedDigit()).frame(width: 30)
                        }
                    }
                }

                Section("Info") {
                    LabeledContent("Name", value: bone.name)
                    LabeledContent("Length", value: "\(Int(bone.length))pt")
                    LabeledContent("Joint A", value: bone.jointA)
                    LabeledContent("Joint B", value: bone.jointB)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.background)
            .navigationTitle("Bone Properties")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Rig Templates Sheet
struct RigTemplatesSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                    ForEach(RigTemplate.templates) { template in
                        Button {
                            vm.applyRigTemplate(template)
                            HapticManager.shared.buttonTap()
                            dismiss()
                        } label: {
                            VStack(spacing: 10) {
                                Image(systemName: template.icon)
                                    .font(.system(size: 36))
                                    .foregroundStyle(.red)
                                Text(template.name)
                                    .font(.subheadline.bold())
                                Text(template.description)
                                    .font(.caption2)
                                    .foregroundStyle(.gray)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(ThemeManager.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(ThemeManager.background)
            .navigationTitle("Rig Templates")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - IK Chains Sheet
struct IKChainsSheet: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.rig.ikChains) { chain in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chain.name).font(.subheadline.bold())
                            Text(chain.jointNames.joined(separator: " → "))
                                .font(.caption2).foregroundStyle(.gray)
                        }
                        Spacer()
                        if chain.pinned {
                            Image(systemName: "pin.fill").foregroundStyle(.red)
                        }
                        Toggle("", isOn: Binding(
                            get: { chain.pinned },
                            set: { vm.toggleIKChainPin(chainId: chain.id, pinned: $0) }
                        ))
                        .labelsHidden()
                        .tint(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.background)
            .navigationTitle("IK Chains")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
