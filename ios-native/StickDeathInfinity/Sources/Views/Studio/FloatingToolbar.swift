// FloatingToolbar.swift
// White pill floating toolbar — draggable, collapsible
// Per-tool accent colors: Pen=red, Eraser=orange, Lasso=blue, Fill=green, Text=purple

import SwiftUI

struct FloatingToolbar: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioPanel

    @State private var position: CGPoint = CGPoint(x: 200, y: 80)
    @State private var dragOffset: CGSize = .zero
    @State private var collapsed = false
    @State private var showMoreMenu = false

    private let toolAccent: [DrawingTool: Color] = [
        .pencil: Color(hex: "F23333"),
        .eraser: Color(hex: "F2A033"),
        .lasso: Color(hex: "4A90D9"),
        .fill: Color(hex: "34C77B"),
        .text: Color(hex: "8B5CF6"),
    ]

    private let mainTools: [DrawingTool] = [.pencil, .eraser, .lasso, .fill, .text]

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Main pill
            HStack(spacing: 2) {
                // Drag handle
                dragHandle

                // Color swatch
                Button {
                    activePanel = activePanel == .colorPicker ? .none : .colorPicker
                } label: {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(vm.drawState.strokeColor)
                        .frame(width: 42, height: 42)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "e0e0e0"), lineWidth: 2))
                        .padding(.horizontal, 4)
                }

                if collapsed {
                    // Collapsed: active tool + expand chevron
                    toolButton(mainTools.first(where: { $0 == vm.drawState.tool }) ?? .pencil, isActive: true)
                    Button { collapsed = false } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(hex: "999999"))
                            .frame(width: 28, height: 28)
                    }
                } else {
                    // Expanded: all tools
                    ForEach(mainTools, id: \.self) { tool in
                        toolButton(tool, isActive: vm.drawState.tool == tool)
                    }

                    // More menu
                    Button { showMoreMenu.toggle() } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(hex: "888888"))
                            .frame(width: 32, height: 32)
                    }

                    // Collapse chevron
                    Button { collapsed = true } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: "aaaaaa"))
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(hex: "f5f5f5"))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            )

            // More dropdown
            if showMoreMenu {
                VStack(spacing: 0) {
                    moreMenuItem("Settings") { activePanel = .settings; showMoreMenu = false }
                    moreMenuItem("Asset Vault") { activePanel = .assetVault; showMoreMenu = false }
                    moreMenuItem("Import Video") { activePanel = .importVideo; showMoreMenu = false }
                }
                .frame(width: 140)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "222222")))
                .shadow(color: .black.opacity(0.4), radius: 10)
            }
        }
        .position(
            x: position.x + dragOffset.width,
            y: position.y + dragOffset.height
        )
    }

    // MARK: - Drag Handle
    var dragHandle: some View {
        let dotGrid = VStack(spacing: 3) {
            ForEach(0..<3) { _ in
                HStack(spacing: 3) {
                    Circle().fill(Color.gray.opacity(0.4)).frame(width: 3, height: 3)
                    Circle().fill(Color.gray.opacity(0.4)).frame(width: 3, height: 3)
                }
            }
        }

        return dotGrid
            .frame(width: 18, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        position.x += value.translation.width
                        position.y += value.translation.height
                        dragOffset = .zero
                    }
            )
    }

    // MARK: - Tool Button
    func toolButton(_ tool: DrawingTool, isActive: Bool) -> some View {
        let accent = toolAccent[tool] ?? .red
        return Button {
            vm.drawState.tool = tool
            vm.mode = .draw
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? .white : Color(hex: "555555"))
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isActive ? accent : .clear)
                )
        }
    }

    // MARK: - More Menu Item
    func moreMenuItem(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
        .background(Color.clear)
    }
}
