// AdaptiveLayout.swift
// Universal layout helpers — iPhone (SE→Pro Max), iPad, Mac, portrait + landscape
// Uses size classes + GeometryReader for fully responsive UI

import SwiftUI

// MARK: - Device Context
enum DeviceType {
    case phoneCompact    // iPhone SE, mini, standard portrait
    case phoneRegular    // iPhone Plus/Pro Max portrait, or any phone landscape
    case pad             // iPad any orientation
    case desktop         // Mac Catalyst
}

struct DeviceContext {
    let type: DeviceType
    let isLandscape: Bool
    let screenWidth: CGFloat
    let screenHeight: CGFloat

    var isWide: Bool { type == .pad || type == .desktop || isLandscape }
    var useSidebar: Bool { type == .pad || type == .desktop }
    var maxContentWidth: CGFloat {
        switch type {
        case .phoneCompact: return .infinity
        case .phoneRegular: return .infinity
        case .pad: return 700
        case .desktop: return 800
        }
    }
    var studioSidePanelWidth: CGFloat {
        switch type {
        case .phoneCompact: return 260
        case .phoneRegular: return 280
        case .pad: return 320
        case .desktop: return 340
        }
    }
    var gridColumns: Int {
        switch type {
        case .phoneCompact: return isLandscape ? 3 : 2
        case .phoneRegular: return isLandscape ? 4 : 2
        case .pad: return isLandscape ? 5 : 3
        case .desktop: return 5
        }
    }
    var feedColumns: Int {
        switch type {
        case .phoneCompact, .phoneRegular: return 1
        case .pad: return isLandscape ? 2 : 1
        case .desktop: return 2
        }
    }
    var toolbarIconSize: CGFloat {
        switch type {
        case .phoneCompact: return 14
        case .phoneRegular: return 16
        case .pad, .desktop: return 18
        }
    }
}

// MARK: - Environment Key
private struct DeviceContextKey: EnvironmentKey {
    static let defaultValue = DeviceContext(type: .phoneCompact, isLandscape: false, screenWidth: 390, screenHeight: 844)
}

extension EnvironmentValues {
    var deviceContext: DeviceContext {
        get { self[DeviceContextKey.self] }
        set { self[DeviceContextKey.self] = newValue }
    }
}

// MARK: - Responsive Wrapper
/// Wrap your root view in this to inject DeviceContext everywhere
struct ResponsiveContainer<Content: View>: View {
    @Environment(\.horizontalSizeClass) var hSize
    @Environment(\.verticalSizeClass) var vSize
    let content: (DeviceContext) -> Content

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let type = resolveType(h: hSize, v: vSize, width: geo.size.width)
            let ctx = DeviceContext(
                type: type,
                isLandscape: isLandscape,
                screenWidth: geo.size.width,
                screenHeight: geo.size.height
            )
            content(ctx)
                .environment(\.deviceContext, ctx)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resolveType(h: UserInterfaceSizeClass?, v: UserInterfaceSizeClass?, width: CGFloat) -> DeviceType {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return .desktop
        #else
        if h == .regular && v == .regular { return .pad }
        if h == .regular && v == .compact { return .phoneRegular }
        if width > 700 { return .pad }
        if width > 430 { return .phoneRegular }
        return .phoneCompact
        #endif
    }
}

// MARK: - Adaptive Modifiers
extension View {
    /// Constrain content width on wide screens, center it
    func adaptiveContentWidth(_ ctx: DeviceContext) -> some View {
        self
            .frame(maxWidth: ctx.maxContentWidth)
            .frame(maxWidth: .infinity)
    }

    /// Safe area padding that adapts to device
    func adaptivePadding(_ ctx: DeviceContext) -> some View {
        self.padding(.horizontal, ctx.type == .desktop ? 32 : ctx.type == .pad ? 24 : 16)
    }
}

// MARK: - Adaptive Grid
struct AdaptiveGrid<Item: Identifiable, ItemView: View>: View {
    let items: [Item]
    let context: DeviceContext
    let minSize: CGFloat
    let spacing: CGFloat
    let content: (Item) -> ItemView

    init(items: [Item], context: DeviceContext, minSize: CGFloat = 160, spacing: CGFloat = 12, @ViewBuilder content: @escaping (Item) -> ItemView) {
        self.items = items
        self.context = context
        self.minSize = minSize
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.adaptive(minimum: minSize), spacing: spacing), count: 1),
            spacing: spacing
        ) {
            ForEach(items) { item in
                content(item)
            }
        }
    }
}
