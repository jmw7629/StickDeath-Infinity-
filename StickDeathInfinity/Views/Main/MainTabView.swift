import SwiftUI

/// Native SDI desktop. Each subject has one retained view; opening a subject
/// raises its existing window, including the shared, unsaved Studio editor.
struct MainTabView: View {
    @State private var activeTab: AppTab
    @State private var mounted: Set<AppTab>
    @State private var opened: Set<AppTab>
    @State private var minimized: Set<AppTab> = []
    @State private var stacking: [AppTab]
    @State private var placements = SDIDesktopStorage.loadWindows()
    @State private var iconPlacements = SDIDesktopStorage.loadIcons()
    @State private var showingGuide = false
    @AppStorage("sdi.desktop.bottomNavigation") private var showsBottomNavigation = false
    /// Keep the existing tutorial key and launch suppression, including Skip.
    @AppStorage("tutorial_completed") private var tutorialCompleted = false
    @State private var tutorialDismissedThisLaunch = MainTabView.tutorialDismissedInProcess
    private static var tutorialDismissedInProcess = false
    @EnvironmentObject var spatterVM: SpatterAIViewModel
    @ObservedObject private var studioVM = StudioViewModel.shared

    init(initialTab: AppTab = .home) {
        _activeTab = State(initialValue: initialTab)
        _mounted = State(initialValue: [initialTab])
        _opened = State(initialValue: [initialTab])
        _stacking = State(initialValue: [initialTab])
    }

    private var tutorialVisible: Bool {
        !tutorialCompleted && !tutorialDismissedThisLaunch && !MainTabView.tutorialDismissedInProcess
    }
    private var showTutorial: Binding<Bool> {
        Binding(get: { tutorialVisible || showingGuide }, set: { shown in
            if !shown {
                tutorialCompleted = true
                MainTabView.tutorialDismissedInProcess = true
                tutorialDismissedThisLaunch = true
                showingGuide = false
            }
        })
    }
    private var frontWindow: AppTab? {
        stacking.last { opened.contains($0) && !minimized.contains($0) }
    }

    var body: some View {
        ZStack {
            SDIDesktopPalette.teal.ignoresSafeArea()
            VStack(spacing: 0) {
                menuBar
                GeometryReader { geometry in
                    desktop(in: geometry.size)
                }
                if !minimized.isEmpty { minimizedShelf }
                if showsBottomNavigation && (frontWindow == nil || activeTab != .studio || !studioVM.isEditing) {
                    bottomNavBar
                }
            }
            if frontWindow != nil && frontWindow != .studio {
                PricingTickerView()
            }
            if tutorialVisible || showingGuide {
                AppTutorialView(isPresented: showTutorial)
                    .zIndex(1000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sdiCommunityOpenStudio)) { _ in open(.studio) }
        .onReceive(NotificationCenter.default.publisher(for: .sdiCommunityReturnToRoom)) { _ in open(.rooms) }
    }

    private var menuBar: some View {
        HStack(spacing: 0) {
            Menu {
                Button("Quick guide", systemImage: "questionmark.square") { showingGuide = true }
                Toggle("Show bottom navigation", isOn: $showsBottomNavigation)
                    .accessibilityIdentifier("desktop.bottom-navigation")
                Divider()
                Button("Arrange windows", systemImage: "square.stack.3d.up") { arrangeWindows() }
                Button("Reset desktop icons", systemImage: "arrow.counterclockwise") {
                    iconPlacements = [:]; SDIDesktopStorage.saveIcons(iconPlacements)
                }
            } label: {
                Text("SD∞").font(.system(size: 17, weight: .black, design: .monospaced))
                    .frame(minWidth: 56, minHeight: 44)
            }
            .accessibilityLabel("SDI desktop menu")
            .accessibilityIdentifier("desktop.menu.sdi")
            menuDivider
            Menu {
                ForEach(AppTab.allCases, id: \.self) { subject in
                    Button { open(subject) } label: {
                        Label(subject.label, systemImage: subject.symbol)
                    }
                    .accessibilityIdentifier("desktop.open." + subject.rawValue)
                }
            } label: {
                menuLabel("Subjects")
            }
            .accessibilityIdentifier("desktop.menu.subjects")
            Menu {
                ForEach(AppTab.allCases.filter { opened.contains($0) }, id: \.self) { subject in
                    Button { open(subject) } label: {
                        Label(subject.label + (minimized.contains(subject) ? " — minimized" : ""),
                              systemImage: subject == frontWindow ? "checkmark" : subject.symbol)
                    }
                    .accessibilityIdentifier("desktop.restore." + subject.rawValue)
                }
                Divider()
                Button("Show desktop", systemImage: "rectangle.on.rectangle") {
                    minimized.formUnion(opened)
                    if opened.contains(.studio) { pauseStudioIfNeeded(.studio) }
                }
                .disabled(opened.isEmpty)
                .accessibilityIdentifier("desktop.show-desktop")
                Button("Minimize front window", systemImage: "minus.square") {
                    if let subject = frontWindow { minimize(subject) }
                }.disabled(frontWindow == nil)
                Button("Maximize / restore size", systemImage: "arrow.up.left.and.arrow.down.right") {
                    if let subject = frontWindow { toggleMaximized(subject) }
                }.disabled(frontWindow == nil)
                Button("Close front window", systemImage: "xmark.square") {
                    if let subject = frontWindow { close(subject) }
                }.disabled(frontWindow == nil)
                Button("Arrange windows", systemImage: "square.stack.3d.up") { arrangeWindows() }
            } label: {
                menuLabel("Windows")
            }
            .accessibilityIdentifier("desktop.menu.windows")
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                Text("STICKDEATH INFINITY").font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .fixedSize().padding(.horizontal, 12)
                EmptyView()
            }
            .accessibilityHidden(true)
        }
        .foregroundStyle(SDIDesktopPalette.ink)
        .background(SDIDesktopPalette.paper)
        .overlay(alignment: .bottom) { SDIDesktopPalette.ink.frame(height: 2) }
        .buttonStyle(.plain)
    }

    private var menuDivider: some View {
        Rectangle().fill(SDIDesktopPalette.ink.opacity(0.35)).frame(width: 1, height: 24)
    }
    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .bold, design: .monospaced))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
        }.padding(.horizontal, 10).frame(minHeight: 44)
    }

    private func desktop(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            SDIDesktopWallpaper()
            ForEach(SDIDesktopIcon.allCases, id: \.self) { icon in
                SDIMovableDesktopIcon(icon: icon, bounds: size,
                    placement: iconPlacements[icon.rawValue] ?? icon.defaultPlacement,
                    onMove: { point in iconPlacements[icon.rawValue] = point },
                    onMoveEnded: { SDIDesktopStorage.saveIcons(iconPlacements) }, action: {
                        switch icon {
                        case .guide: showingGuide = true
                        case .arrange: arrangeWindows()
                        }
                    })
            }
            // Keep identity and local navigation state when a window is hidden.
            // Only subjects actually opened in this launch mount their services.
            ForEach(AppTab.allCases, id: \.self) { subject in
                if mounted.contains(subject) {
                    SDISubjectWindow(subject: subject, bounds: size,
                        placement: placement(for: subject), focused: subject == frontWindow,
                        onFocus: { focus(subject) }, onClose: { close(subject) },
                        onMinimize: { minimize(subject) }, onMaximize: { toggleMaximized(subject) },
                        onMove: { value in placements[subject.rawValue] = value },
                        onMoveEnded: { SDIDesktopStorage.saveWindows(placements) }) {
                            subjectContent(subject)
                                .environment(\.sdiSubjectWindowVisible, isVisible(subject))
                        }
                        .opacity(isVisible(subject) ? 1 : 0)
                        .allowsHitTesting(isVisible(subject))
                        .accessibilityHidden(!isVisible(subject))
                        .zIndex(Double(stacking.firstIndex(of: subject) ?? 0) + 1)
                }
            }
        }
        .frame(width: max(1, size.width), height: max(1, size.height))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.workspace")
    }

    @ViewBuilder private func subjectContent(_ subject: AppTab) -> some View {
        switch subject {
        case .home: HomeFeedView()
        case .challenges: ChallengesView()
        case .studio: StudioView()
        case .rooms: CollabRoomView()
        case .profile: ProfileView(onOpenProjects: { open(.studio) })
        }
    }

    private var minimizedShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AppTab.allCases.filter { minimized.contains($0) }, id: \.self) { subject in
                    Button { open(subject) } label: {
                        Label("Restore " + subject.label, systemImage: subject.symbol)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10).frame(minHeight: 44)
                            .background(SDIDesktopPalette.paper)
                            .overlay(Rectangle().strokeBorder(SDIDesktopPalette.ink, lineWidth: 2))
                    }
                    .accessibilityIdentifier("desktop.minimized." + subject.rawValue)
                }
            }.padding(.horizontal, 8).padding(.vertical, 4)
        }
        .frame(height: 52)
        .foregroundStyle(SDIDesktopPalette.ink)
        .background(SDIDesktopPalette.grey)
        .buttonStyle(.plain)
    }

    private var bottomNavBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { subject in
                Button { open(subject) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: subject.symbol).font(.system(size: 17, weight: .bold))
                        Text(subject.label).font(.system(size: 9, weight: .bold, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(subject == frontWindow ? subject.desktopAccent : SDIDesktopPalette.paper)
                }
                .accessibilityLabel(subject.label)
                .accessibilityAddTraits(subject == frontWindow ? .isSelected : [])
                .accessibilityIdentifier("desktop.nav." + subject.rawValue)
            }
        }
        .foregroundStyle(SDIDesktopPalette.ink)
        .background(SDIDesktopPalette.paper)
        .overlay(alignment: .top) { SDIDesktopPalette.ink.frame(height: 2) }
        .buttonStyle(.plain)
    }

    private func isVisible(_ subject: AppTab) -> Bool {
        opened.contains(subject) && !minimized.contains(subject)
    }
    private func placement(for subject: AppTab) -> SDIWindowPlacement {
        placements[subject.rawValue] ?? .initial(index: AppTab.allCases.firstIndex(of: subject) ?? 0)
    }
    private func focus(_ subject: AppTab) {
        guard isVisible(subject) else { return }
        activeTab = subject
        stacking.removeAll { $0 == subject }; stacking.append(subject)
    }
    private func open(_ subject: AppTab) {
        mounted.insert(subject); opened.insert(subject); minimized.remove(subject)
        focus(subject)
    }
    private func minimize(_ subject: AppTab) {
        minimized.insert(subject); pauseStudioIfNeeded(subject)
        if let frontWindow { activeTab = frontWindow }
    }
    private func close(_ subject: AppTab) {
        opened.remove(subject); minimized.remove(subject); pauseStudioIfNeeded(subject)
        if let frontWindow { activeTab = frontWindow }
    }
    private func pauseStudioIfNeeded(_ subject: AppTab) {
        guard subject == .studio else { return }
        studioVM.stopPlayback()
        Task { await studioVM.flush() }
    }
    private func toggleMaximized(_ subject: AppTab) {
        var value = placement(for: subject); value.maximized.toggle()
        placements[subject.rawValue] = value
        SDIDesktopStorage.saveWindows(placements); focus(subject)
    }
    private func arrangeWindows() {
        for (index, subject) in stacking.enumerated() {
            placements[subject.rawValue] = .initial(index: index)
        }
        SDIDesktopStorage.saveWindows(placements)
    }
}

/// Retained subject views receive visibility separately from app scene phase.
/// Other native presentations keep their existing lifecycle by default.
private struct SDISubjectWindowVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var sdiSubjectWindowVisible: Bool {
        get { self[SDISubjectWindowVisibilityKey.self] }
        set { self[SDISubjectWindowVisibilityKey.self] = newValue }
    }
}

enum AppTab: String, CaseIterable {
    case home, challenges, studio, rooms, profile
    var icon: String {
        switch self {
        case .home: return "🏠"
        case .challenges: return "⚔️"
        case .studio: return "🎨"
        case .rooms: return "🤝"
        case .profile: return "👤"
        }
    }
    var label: String {
        switch self {
        case .home: return "Home"
        case .challenges: return "Challenges"
        case .studio: return "Studio"
        case .rooms: return "Rooms"
        case .profile: return "Profile"
        }
    }
    fileprivate var symbol: String {
        switch self {
        case .home: return "play.rectangle"
        case .challenges: return "flag.checkered"
        case .studio: return "pencil.and.scribble"
        case .rooms: return "square.stack.3d.up"
        case .profile: return "person.crop.square"
        }
    }
    fileprivate var desktopAccent: Color {
        switch self {
        case .home: return SDIDesktopPalette.coral
        case .challenges: return SDIDesktopPalette.yellow
        case .studio: return SDIDesktopPalette.lime
        case .rooms: return SDIDesktopPalette.lilac
        case .profile: return SDIDesktopPalette.blue
        }
    }
}

private enum SDIDesktopPalette {
    static let paper = Color(hex: "EFEAE0")
    static let ink = Color(hex: "101011")
    static let grey = Color(hex: "BDB9B3")
    static let teal = Color(hex: "245E61")
    static let coral = Color(hex: "FF6971")
    static let yellow = Color(hex: "F3D54A")
    static let lime = Color(hex: "B4D957")
    static let lilac = Color(hex: "C2ABEC")
    static let blue = Color(hex: "88C5EC")
}

private struct SDIDesktopWallpaper: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SDIDesktopPalette.teal
            Canvas { context, size in
                // Deterministic dither: no image assets or ongoing animation.
                var dots = Path()
                for x in stride(from: CGFloat(0), to: size.width, by: 8) {
                    for y in stride(from: CGFloat(0), to: size.height, by: 8) {
                        dots.addRect(CGRect(x: x + (Int(y / 8).isMultiple(of: 2) ? 0 : 4), y: y, width: 1, height: 1))
                    }
                }
                context.fill(dots, with: .color(.black.opacity(0.24)))
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("STICKDEATH").font(.system(size: 29, weight: .black, design: .monospaced))
                Text("INFINITY / MAKE A LITTLE MAYHEM")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(SDIDesktopPalette.paper.opacity(0.32)).padding(22)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Fractions are re-clamped on every layout, so rotations and old stored
/// positions cannot strand a title bar, control or resize handle off screen.
private struct SDIWindowPlacement: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var maximized = false

    static func initial(index: Int) -> Self {
        .init(x: 0.025 + Double(index) * 0.025, y: 0.02 + Double(index) * 0.025,
              width: 0.88, height: 0.86)
    }
    var isValid: Bool { [x, y, width, height].allSatisfy { $0.isFinite && abs($0) <= 4 } && width > 0 && height > 0 }
    func rect(in bounds: CGSize) -> CGRect {
        let available = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        if maximized { return CGRect(origin: .zero, size: available) }
        // Small displays use nearly all the workspace; larger displays retain
        // space for overlapping windows and desktop commands.
        let minWidth = min(available.width, available.width < 600 ? 280 : 340)
        let minHeight = min(available.height, 280)
        let w = min(available.width, max(max(1, minWidth), available.width * width))
        let h = min(available.height, max(minHeight, available.height * height))
        return CGRect(x: min(max(0, available.width * x), available.width - w),
                      y: min(max(0, available.height * y), available.height - h), width: w, height: h)
    }
    static func from(_ rect: CGRect, in bounds: CGSize) -> Self {
        .init(x: rect.minX / max(1, bounds.width), y: rect.minY / max(1, bounds.height),
              width: rect.width / max(1, bounds.width), height: rect.height / max(1, bounds.height))
    }
}

private struct SDISubjectWindow<Content: View>: View {
    let subject: AppTab
    let bounds: CGSize
    let placement: SDIWindowPlacement
    let focused: Bool
    let onFocus: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    let onMove: (SDIWindowPlacement) -> Void
    let onMoveEnded: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var dragOrigin: CGRect?
    @State private var resizeOrigin: CGRect?

    var body: some View {
        let rect = placement.rect(in: bounds)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                windowButton("xmark", title: "Close", action: onClose)
                titleHandle
                windowButton("minus", title: "Minimize", action: onMinimize)
                windowButton(placement.maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             title: placement.maximized ? "Restore size" : "Maximize", action: onMaximize)
                if bounds.height < 420 { resizeHandle }
            }
            .foregroundStyle(SDIDesktopPalette.ink)
            .background(focused ? subject.desktopAccent : SDIDesktopPalette.grey)
            .overlay(alignment: .bottom) { SDIDesktopPalette.ink.frame(height: 2) }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.sdBackground)
                .clipped()
            if bounds.height >= 420 {
                HStack(spacing: 8) {
                    Text(subject == .studio ? "PROJECTS ON THIS DEVICE" : "SD∞ / " + subject.label.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 0)
                    resizeHandle
                }
                .foregroundStyle(SDIDesktopPalette.ink)
                .padding(.leading, 10).frame(height: 28)
                .background(SDIDesktopPalette.paper)
                .overlay(alignment: .top) { SDIDesktopPalette.ink.frame(height: 1) }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .background(SDIDesktopPalette.paper)
        .overlay(Rectangle().strokeBorder(SDIDesktopPalette.ink, lineWidth: 2))
        .overlay(alignment: .top) { Color.white.opacity(0.7).frame(height: 1).padding(.horizontal, 2) }
        .shadow(color: .black.opacity(0.65), radius: 0, x: focused ? 5 : 3, y: focused ? 5 : 3)
        .offset(x: rect.minX, y: rect.minY)
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.window." + subject.rawValue)
    }

    private func windowButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .heavy))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + " " + subject.label)
        .accessibilityIdentifier("desktop.window." + subject.rawValue + "." + (title == "Restore size" ? "restore-size" : title.lowercased()))
    }
    private var titleHandle: some View {
        HStack(spacing: 6) {
            Image(systemName: subject.symbol).font(.system(size: 13, weight: .bold))
            Text(subject.label).font(.system(size: 13, weight: .heavy, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
            VStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { _ in
                    Rectangle().fill(SDIDesktopPalette.ink.opacity(focused ? 0.45 : 0.2)).frame(height: 1)
                }
            }.frame(maxWidth: .infinity).padding(.horizontal, 4).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .gesture(DragGesture(minimumDistance: 5).onChanged { value in
            guard !placement.maximized else { return }
            if dragOrigin == nil { dragOrigin = placement.rect(in: bounds); onFocus() }
            guard let origin = dragOrigin else { return }
            move(origin.offsetBy(dx: value.translation.width, dy: value.translation.height))
        }.onEnded { _ in dragOrigin = nil; onMoveEnded() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subject.label + " window title")
        .accessibilityHint(placement.maximized ? "Restore size to move this window." : "Drag to move, or use the move actions.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onFocus() }
        .accessibilityAction(named: "Move left") { nudge(dx: -32, dy: 0) }
        .accessibilityAction(named: "Move right") { nudge(dx: 32, dy: 0) }
        .accessibilityAction(named: "Move up") { nudge(dx: 0, dy: -32) }
        .accessibilityAction(named: "Move down") { nudge(dx: 0, dy: 32) }
        .accessibilityIdentifier("desktop.window." + subject.rawValue + ".title")
    }
    private var resizeHandle: some View {
        Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 13, weight: .heavy)).rotationEffect(.degrees(-45))
            .frame(width: 44, height: bounds.height < 420 ? 44 : 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                guard !placement.maximized else { return }
                if resizeOrigin == nil { resizeOrigin = placement.rect(in: bounds); onFocus() }
                guard var rect = resizeOrigin else { return }
                rect.size.width += value.translation.width; rect.size.height += value.translation.height
                resize(rect)
            }.onEnded { _ in resizeOrigin = nil; onMoveEnded() })
            .accessibilityElement()
            .accessibilityLabel("Resize " + subject.label)
            .accessibilityHint(placement.maximized ? "Restore size before resizing." : "Drag to resize, or use the size actions.")
            .accessibilityAction(named: "Make larger") { grow(by: 48) }
            .accessibilityAction(named: "Make smaller") { grow(by: -48) }
            .accessibilityIdentifier("desktop.window." + subject.rawValue + ".resize")
    }
    private func move(_ rect: CGRect) {
        let safe = SDIWindowPlacement.from(rect, in: bounds)
        onMove(.from(safe.rect(in: bounds), in: bounds))
    }
    private func resize(_ rect: CGRect) {
        var value = SDIWindowPlacement.from(rect, in: bounds)
        var safe = value.rect(in: bounds)
        safe.origin = placement.rect(in: bounds).origin
        safe.size.width = min(safe.width, max(1, bounds.width - safe.minX))
        safe.size.height = min(safe.height, max(1, bounds.height - safe.minY))
        value = .from(safe, in: bounds); onMove(value)
    }
    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard !placement.maximized else { return }
        onFocus(); move(placement.rect(in: bounds).offsetBy(dx: dx, dy: dy)); onMoveEnded()
    }
    private func grow(by amount: CGFloat) {
        guard !placement.maximized else { return }
        onFocus()
        var rect = placement.rect(in: bounds)
        rect.size.width += amount; rect.size.height += amount
        resize(rect); onMoveEnded()
    }
}

private struct SDIDesktopPoint: Codable {
    var x: Double
    var y: Double
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}
private enum SDIDesktopIcon: String, CaseIterable {
    // Commands only: subjects belong in the menu, never duplicate shortcuts.
    case guide, arrange
    var label: String { self == .guide ? "Quick guide" : "Tidy desk" }
    var symbol: String { self == .guide ? "book.closed.fill" : "rectangle.3.group.fill" }
    var color: Color { self == .guide ? SDIDesktopPalette.yellow : SDIDesktopPalette.lilac }
    var defaultPlacement: SDIDesktopPoint { .init(x: 0.025, y: self == .guide ? 0.025 : 0.20) }
}
private struct SDIMovableDesktopIcon: View {
    let icon: SDIDesktopIcon
    let bounds: CGSize
    let placement: SDIDesktopPoint
    let onMove: (SDIDesktopPoint) -> Void
    let onMoveEnded: () -> Void
    let action: () -> Void
    @State private var dragOrigin: CGPoint?
    private var position: CGPoint {
        CGPoint(x: max(0, bounds.width - 92) * placement.x, y: max(0, bounds.height - 92) * placement.y)
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon.symbol).font(.system(size: 28, weight: .bold))
                    .frame(width: 50, height: 46).background(icon.color)
                    .overlay(Rectangle().strokeBorder(SDIDesktopPalette.ink, lineWidth: 2))
                    .shadow(color: .black, radius: 0, x: 3, y: 3)
                Text(icon.label).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .background(SDIDesktopPalette.paper)
            }.frame(width: 92, height: 92)
        }
        .buttonStyle(.plain).foregroundStyle(SDIDesktopPalette.ink)
        .offset(x: position.x, y: position.y)
        .highPriorityGesture(DragGesture(minimumDistance: 8).onChanged { value in
            if dragOrigin == nil { dragOrigin = position }
            guard let origin = dragOrigin else { return }
            update(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
        }.onEnded { _ in dragOrigin = nil; onMoveEnded() })
        .accessibilityHint("Tap to " + (icon == .guide ? "open the guide." : "arrange your windows.") + " Drag to move this icon.")
        .accessibilityAction(named: "Move left") { update(x: position.x - 32, y: position.y); onMoveEnded() }
        .accessibilityAction(named: "Move right") { update(x: position.x + 32, y: position.y); onMoveEnded() }
        .accessibilityAction(named: "Move up") { update(x: position.x, y: position.y - 32); onMoveEnded() }
        .accessibilityAction(named: "Move down") { update(x: position.x, y: position.y + 32); onMoveEnded() }
        .accessibilityIdentifier("desktop.icon." + icon.rawValue)
    }
    private func update(x: CGFloat, y: CGFloat) {
        onMove(.init(x: min(1, max(0, x / max(1, bounds.width - 92))),
                     y: min(1, max(0, y / max(1, bounds.height - 92)))))
    }
}

private enum SDIDesktopStorage {
    private static let windowKey = "sdi.desktop.windowPlacement.v1"
    private static let iconKey = "sdi.desktop.iconPlacement.v1"
    static func loadWindows() -> [String: SDIWindowPlacement] {
        guard let data = UserDefaults.standard.data(forKey: windowKey), data.count < 8192,
              let values = try? JSONDecoder().decode([String: SDIWindowPlacement].self, from: data) else { return [:] }
        return values.filter { AppTab(rawValue: $0.key) != nil && $0.value.isValid }
    }
    static func loadIcons() -> [String: SDIDesktopPoint] {
        guard let data = UserDefaults.standard.data(forKey: iconKey), data.count < 2048,
              let values = try? JSONDecoder().decode([String: SDIDesktopPoint].self, from: data) else { return [:] }
        return values.filter { SDIDesktopIcon(rawValue: $0.key) != nil && $0.value.isValid }
    }
    static func saveWindows(_ values: [String: SDIWindowPlacement]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: windowKey)
    }
    static func saveIcons(_ values: [String: SDIDesktopPoint]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: iconKey)
    }
}
