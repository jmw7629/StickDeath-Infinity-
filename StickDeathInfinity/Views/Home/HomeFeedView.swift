import SwiftUI
import AVKit
import Combine
import UIKit
import WebKit

/// Social video wall over `sdi_feed_page` (keyset pages) and `sdi_feed_action`
/// (reactions): approved renditions only, server ranking for Trending/Recent/
/// Following/Featured, bounded pages, idempotent likes/follows with rollback,
/// Typed HTTPS rendition/YouTube playback with error states and sharing, and file export only
/// where the creator permits it and the viewer's plan includes downloads.
/// No text posts, comments or chat.
struct HomeFeedView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.sdiSubjectWindowVisible) private var subjectWindowVisible
    @StateObject private var activity = FeedWindowActivity()
    @State private var listingIdentity: String?
    @State private var scrollViewport = CGRect.zero
    @State private var loadTask: Task<Void, Never>?
    @State private var loadRun: UUID?
    @State private var actionTask: Task<Void, Never>?
    @State private var actionRun: UUID?
    @State private var pendingReaction: FeedPendingReaction?
    @State private var linkShare: FeedLinkShareOffer?
    @State private var timeline = FeedTimeline()
    @State private var category = FeedCategory.recent
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var offlineUpdatedAt: Date?
    @State private var epoch = UUID()
    @State private var playback: FeedPlaybackItem?
    @State private var exporting: UUID?
    @State private var exportRun: UUID?
    @State private var exportEpoch = UUID()
    @State private var viewerGeneration = UUID()
    @State private var exportListing: FeedExportListing?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: FeedExportDownload.Progress?
    @State private var exportFile: FeedExportFile?
    @State private var blocking: FeedPost?
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(auth.communityIdentityRevision):\(category.rawValue):\(viewerGeneration)" }
    private var exportContext: FeedExportListing.Context? {
        guard activity.canInteract, phase == .active, subjectWindowVisible, listingIdentity == identity,
              auth.isAuthenticated, let account = auth.userId else { return nil }
        return .init(account: account, generation: exportEpoch)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Rectangle().fill(FeedWallPalette.red).frame(width: 6, height: 28).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("StickDeath ∞").font(.specialElite(22, relativeTo: .title2))
                        Text("VIDEO WALL").font(.specialElite(11, relativeTo: .caption)).tracking(2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button { requestLoad(reset: true) } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .buttonStyle(FeedWallButtonStyle())
                    .accessibilityLabel("Refresh feed").disabled(loading || actionRun != nil || !activity.canInteract)
                    .accessibilityIdentifier("feed.home.refresh")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(FeedWallPalette.paper, ignoresSafeAreaEdges: [.horizontal])
                .overlay(alignment: .bottom) { FeedWallPalette.ink.frame(height: 2) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(FeedCategory.allCases, id: \.self) { filter in
                            Button(filter.title) { category = filter }
                                .buttonStyle(FeedWallButtonStyle(selected: category == filter))
                                .accessibilityAddTraits(category == filter ? .isSelected : [])
                                .accessibilityHint(filter.explanation)
                                .accessibilityIdentifier("feed.home.filter." + filter.rawValue)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 10).padding(.bottom, 2)
                }
                .background(FeedWallPalette.grey)
                .overlay(alignment: .bottom) { FeedWallPalette.ink.frame(height: 2) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if !CommunityServices.isConfigured { FeedWallMessage(text: CommunityServices.notConfiguredText, kind: .info) }
                        if !auth.isAuthenticated {
                            CommunitySignInPrompt(text: "Sign in to view the community feed.", identifier: "feed.home.sign-in")
                                .foregroundStyle(FeedWallPalette.paper)
                                .padding(16).background(FeedWallPalette.ink)
                        }
                        Text(category.explanation).feedWallCaption()
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(FeedWallPalette.paper)
                            .overlay(Rectangle().strokeBorder(FeedWallPalette.ink, lineWidth: 2))
                        if let error { FeedWallMessage(text: error, kind: .error).accessibilityIdentifier("feed.home.error") }
                        if let notice { FeedWallMessage(text: notice, kind: .success).accessibilityIdentifier("feed.home.notice") }
                        if let offlineUpdatedAt {
                            FeedWallMessage(text: "Offline · last updated \(offlineUpdatedAt.formatted(date: .abbreviated, time: .shortened)). Reactions need a connection.", kind: .offline)
                                .accessibilityIdentifier("feed.home.offline")
                        }
                        FeedWallGrid(width: geometry.size.width) {
                            if listingIdentity == identity { ForEach(timeline.posts) { post in card(post) } }
                        }
                        if loading {
                            ProgressView("Loading approved videos…").tint(FeedWallPalette.ink)
                                .font(.specialElite(14, relativeTo: .callout))
                                .padding(16).frame(maxWidth: .infinity)
                                .background(FeedWallPalette.paper)
                        }
                        if auth.isAuthenticated && loaded && !loading && timeline.posts.isEmpty && error == nil {
                            FeedWallWindow {
                                FeedWallTitleBar(title: "Video wall") { EmptyView() }
                                Label("No approved videos in this feed yet.", systemImage: "play.rectangle")
                                    .font(.specialElite(16, relativeTo: .body))
                                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("feed.home.empty")
                            }
                        }
                        if auth.isAuthenticated && timeline.canLoadMore && !loading && offlineUpdatedAt == nil {
                            Button(error == nil ? "Load more" : "Retry") { requestLoad(reset: false) }
                                .buttonStyle(FeedWallButtonStyle())
                                .frame(maxWidth: .infinity)
                                .disabled(actionRun != nil || !activity.canInteract)
                                .accessibilityIdentifier("feed.home.load-more")
                        }
                        if auth.isAuthenticated && !timeline.canLoadMore && timeline.nextPage >= FeedTimeline.maximumPages {
                            Text("Showing the first \(FeedTimeline.maximumPages * FeedTimeline.pageSize) videos of this ranking. Refresh to restart.").feedWallCaption()
                                .padding(12).background(FeedWallPalette.paper)
                        }
                    }
                    .padding(16).padding(.bottom, 60)
                    .frame(maxWidth: 1180).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "feed.home.viewport")
                .background {
                    GeometryReader { viewport in
                        Color.clear.preference(key: FeedViewportBoundsKey.self,
                                               value: CGRect(origin: .zero, size: viewport.size))
                    }
                }
                .onPreferenceChange(FeedViewportBoundsKey.self) { scrollViewport = $0 }
                .refreshable { if let task = requestLoad(reset: true) { await task.value } }
            }
        }
        .foregroundStyle(FeedWallPalette.ink)
        .background(FeedWallDesktop().ignoresSafeArea(edges: [.horizontal, .bottom]))
        // Only account/category lifetimes reset the listing. Visibility and scene
        // pauses revoke work independently, keeping rows, cursor, filter and scroll.
        .task(id: identity) {
            pauseWork()
            timeline.reset(); loaded = false
            error = nil; notice = nil; offlineUpdatedAt = nil
            listingIdentity = identity
            updateAvailability()
        }
        .onAppear { updateAvailability() }
        .sheet(item: $playback) { item in
            if item.scope.isCurrent {
                CommunityVideoPlayer(source: item.source, title: item.title, isAllowed: { item.scope.isCurrent })
            }
        }
        .sheet(item: $linkShare) { offer in
            FeedLinkSharePresenter(offer: offer, onTerminal: {
                if linkShare?.id == offer.id { linkShare = nil }
            })
        }
        .sheet(item: $exportFile) { file in
            FeedExportSharePresenter(file: file, isAllowed: {
                file.generation == exportEpoch && file.account == auth.userId && auth.isAuthenticated && phase == .active && activity.canInteract && subjectWindowVisible
            }, onTerminal: {
                if exportFile?.id == file.id { exportFile = nil }
            })
        }
        .confirmationDialog("Block this creator?", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }), titleVisibility: .visible, presenting: blocking) { post in
            Button("Block \(post.creator_name)", role: .destructive) { beginAction(.block, post: post) }
            Button("Cancel", role: .cancel) { blocking = nil }
        } message: { post in
            Text("You will no longer see \(post.creator_name)'s videos and they will not see yours. This does not report them.")
        }
        .onChange(of: category) { _, _ in pauseWork() }
        // Published identity/state events invalidate even a rapid A → B → A
        // account change that SwiftUI might coalesce into the same rendered ID.
        .onReceive(auth.$currentUser) { _ in revokeViewerListing() }
        .onReceive(auth.$state) { _ in revokeViewerListing() }
        .onChange(of: phase) { _, _ in updateAvailability() }
        .onChange(of: subjectWindowVisible) { _, _ in updateAvailability() }
        .onDisappear { pauseWork() }
    }

    private func card(_ post: FeedPost) -> some View {
        let exportTap = exportListing?.capture(for: post)
        let playbackScope = identity
        return FeedWallWindow {
            FeedWallTitleBar(title: post.title) {
                Menu {
                    if post.creator.uuidString.lowercased() != auth.userId?.lowercased() {
                        Button(post.following ? "Unfollow creator" : "Follow creator") { beginAction(.follow, post: post) }
                        Button("Block creator", role: .destructive) { if captureScope(post: post) != nil { blocking = post } }
                    }
                    Menu("Report video") {
                        ForEach(FeedReportReason.allCases, id: \.self) { reason in
                            Button(reason.title) { beginAction(.report(reason), post: post) }
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .tint(FeedWallPalette.ink)
                    .disabled(offlineUpdatedAt != nil || loading || actionRun != nil || !activity.canInteract)
                    .accessibilityLabel("More actions for \(post.title)")
                    .accessibilityIdentifier("feed.card.menu")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.crop.square").font(.title2)
                        .foregroundStyle(FeedWallPalette.ink).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(post.creator_name).font(.specialElite(16, relativeTo: .body))
                        Text(post.published_at, style: .relative).feedWallCaption()
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    guard identity == playbackScope, let scope = captureScope(post: post), scope.isCurrent,
                          auth.isAuthenticated, phase == .active,
                          let current = timeline.posts.first(where: { $0.id == post.id }),
                          current.creator == post.creator, current.url == post.url else { return }
                    guard let source = current.playbackSource else {
                        error = "This video address is unsupported or unavailable."; return
                    }
                    playback = FeedPlaybackItem(postID: current.id, creator: current.creator, source: source, title: current.title, scope: scope)
                } label: {
                    FeedPosterView(post: post, generation: activity.revision, viewport: scrollViewport, isAllowed: {
                        activity.canInteract && listingIdentity == identity && offlineUpdatedAt == nil &&
                            timeline.posts.contains(where: { $0.id == post.id && $0.poster.url == post.poster.url && $0.creator == post.creator })
                    })
                        .overlay(Rectangle().strokeBorder(FeedWallPalette.ink, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(post.title)").accessibilityIdentifier("feed.card.play")
                if !post.caption.isEmpty { Text(post.caption).font(.specialElite(14, relativeTo: .callout)) }
                FeedWallActionGrid {
                    Button { beginAction(.like, post: post) } label: {
                        Label(String(post.likes), systemImage: post.liked ? "heart.fill" : "heart")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(FeedWallButtonStyle(selected: post.liked))
                    .disabled(actionRun != nil || loading || offlineUpdatedAt != nil || !activity.canInteract)
                    .accessibilityLabel("\(post.liked ? "Unlike" : "Like") video, \(post.likes) likes")
                    .accessibilityIdentifier("feed.card.like")
                    if let url = post.safeURL {
                        Button {
                            guard let scope = captureScope(post: post), scope.isCurrent else { return }
                            linkShare = FeedLinkShareOffer(url: url, scope: scope)
                        } label: { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(FeedWallButtonStyle())
                            .disabled(!activity.canInteract)
                            .accessibilityIdentifier("feed.card.share")
                    }
                    if FeedExportPolicy.canExport(post) {
                        Button { beginExport(post, tap: exportTap) } label: {
                            Label(exporting == post.id ? "Exporting…" : "Export", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(FeedWallButtonStyle())
                        .disabled(exporting != nil || exportFile != nil || exportTap == nil)
                        .accessibilityHint("The creator permits saving this video file.")
                        .accessibilityIdentifier("feed.card.export")
                    }
                }
                if exporting == post.id {
                    VStack(alignment: .leading, spacing: 8) {
                        if let progress = exportProgress, let total = progress.expectedBytes, total > 0 {
                            ProgressView(value: Double(progress.receivedBytes), total: Double(total))
                                .accessibilityLabel("Video export download")
                        } else { ProgressView().accessibilityLabel("Video export download") }
                        HStack(spacing: 12) {
                            if let progress = exportProgress {
                                Text(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file) + " downloaded")
                                    .feedWallCaption()
                            }
                            Spacer(minLength: 0)
                            Button("Cancel") { cancelExport() }.frame(minHeight: 44)
                                .buttonStyle(FeedWallButtonStyle())
                                .accessibilityIdentifier("feed.card.export-cancel")
                        }
                    }
                    .tint(FeedWallPalette.ink)
                    .accessibilityIdentifier("feed.card.export-progress")
                }
                switch FeedExportPolicy.state(post) {
                case .allowed: EmptyView()
                case .needsPaidPlan: Text("The creator permits saving this video; saving files needs a paid plan. Sharing the link is allowed.").feedWallCaption()
                        .accessibilityIdentifier("feed.card.export-plan")
                case .notPermitted: Text("Export not permitted by the creator; sharing available links is allowed.").feedWallCaption()
                case .providerDownloadUnavailable: Text("YouTube videos play through YouTube. File downloads are unavailable; you can share the link.").feedWallCaption()
                        .accessibilityIdentifier("feed.card.export-provider-unavailable")
                }
            }.padding(14)
        }
        .accessibilityIdentifier("feed.card")
    }

    /// Capture before Task creation; no delayed button can acquire a replacement
    /// account/window/category lease. Only immutable row identity is compared so an
    /// owned optimistic count change does not invalidate its own request.
    @MainActor private func captureScope(post: FeedPost? = nil) -> CommunityOperationScope? {
        guard activity.canInteract, phase == .active, subjectWindowVisible,
              listingIdentity == identity, let account = auth.currentUser?.id else { return nil }
        if let post, !timeline.posts.contains(post) { return nil }
        let revision = epoch, window = activity.revision
        let viewer = identity, category = category
        let authRevision = auth.communityIdentityRevision
        return CommunityOperationScope(account: account) {
            activity.canInteract && activity.revision == window && epoch == revision &&
                listingIdentity == viewer && identity == viewer && self.category == category &&
                auth.currentUser?.id == account && auth.communityIdentityRevision == authRevision &&
                (post.map { expected in timeline.posts.contains(where: {
                    $0.id == expected.id && $0.creator == expected.creator && $0.url == expected.url &&
                        $0.published_at == expected.published_at && $0.title == expected.title
                }) } ?? true)
        }
    }

    @discardableResult
    @MainActor private func requestLoad(reset: Bool) -> Task<Void, Never>? {
        guard actionRun == nil, !loading, activity.canInteract, listingIdentity == identity else { return nil }
        if reset {
            epoch = UUID(); invalidateExportScope()
            playback = nil; linkShare = nil
            timeline.reset(); loaded = false; offlineUpdatedAt = nil
        }
        guard timeline.canLoadMore, let scope = captureScope(), let context = exportContext,
              let account = auth.userId else { return nil }
        let run = UUID(), page = timeline.nextPage, category = category
        let asOf = timeline.asOf, cursor = timeline.nextCursor
        loadRun = run; loading = true
        let task = Task { @MainActor in
            defer { if loadRun == run { loading = false; loadRun = nil; loadTask = nil } }
            do {
                let result = try await CommunityOperationContext.run(scope) {
                    try await CommunityServices.feed.page(category, page: page, account: account, asOf: asOf, cursor: cursor)
                }
                guard scope.isCurrent, loadRun == run, actionRun == nil, exportContext == context else { return }
                var committed = timeline
                try committed.merge(page: page, posts: result.posts, hasMore: result.hasMore, asOf: result.asOf, cursor: result.cursor)
                // Pausing revokes export decisions without discarding paging. A
                // later page can extend the cursor; only fresh rows regain export permission.
                guard let binding = FeedExportListing.commit(rows: result.posts,
                    previous: exportListing?.matches(context) == true ? exportListing : nil,
                    captured: context, current: exportContext) else { return }
                timeline = committed
                if let active = playback, !committed.posts.contains(where: {
                    $0.id == active.postID && $0.creator == active.creator && $0.playbackSource == active.source
                }) { playback = nil }
                cancelExport()
                if exportFile?.revokePendingShare() == true { exportFile = nil }
                if case .cache(let updatedAt) = result.source {
                    offlineUpdatedAt = updatedAt; exportListing = nil
                } else { offlineUpdatedAt = nil; exportListing = binding }
                loaded = true; error = nil
            } catch {
                if scope.isCurrent, loadRun == run {
                    loaded = true; self.error = CommunityGateway.normalize(error).errorDescription
                }
            }
        }
        loadTask = task
        return task
    }

    @MainActor private func beginAction(_ action: FeedOwnedAction, post: FeedPost) {
        guard actionRun == nil, !loading, offlineUpdatedAt == nil,
              let scope = captureScope(post: post) else { return }
        let run = UUID()
        let snapshot: FeedTimeline.Snapshot?
        let key: UUID
        switch action {
        case .like:
            key = post.id; snapshot = timeline.beginLike(key, enabled: !post.liked)
            guard snapshot != nil else { return }
        case .follow:
            key = post.creator; snapshot = timeline.beginFollow(key, enabled: !post.following)
            guard snapshot != nil else { return }
        case .block, .report: key = post.id; snapshot = nil
        }
        if let snapshot { pendingReaction = FeedPendingReaction(run: run, key: key, snapshot: snapshot) }
        actionRun = run; blocking = nil; error = nil; notice = nil
        actionTask = Task { @MainActor in
            defer {
                if actionRun == run {
                    settleReaction(run: run, confirmed: false)
                    actionRun = nil; actionTask = nil
                }
            }
            do {
                let confirmed = try await CommunityOperationContext.run(scope) {
                    switch action {
                    case .like: return try await CommunityServices.feed.like(post.id, enabled: !post.liked)
                    case .follow: return try await CommunityServices.feed.follow(post.creator, enabled: !post.following)
                    case .block: return try await CommunityServices.feed.block(post.creator)
                    case .report(let reason): return try await CommunityServices.feed.report(post.id, reason: reason)
                    }
                }
                guard scope.isCurrent, actionRun == run else { return }
                settleReaction(run: run, confirmed: confirmed)
                if confirmed {
                    switch action {
                    case .like: break
                    case .follow: notice = post.following ? "Unfollowed \(post.creator_name)." : "Following \(post.creator_name)."
                    case .block:
                        if playback?.creator == post.creator { playback = nil }
                        timeline.removeCreator(post.creator); invalidateExportScope()
                        notice = "Blocked \(post.creator_name)."
                    case .report: notice = "Report recorded for moderation. Reporters are not identified to creators."
                    }
                } else { error = "The action was not confirmed. Refresh to check the server's current value." }
            } catch {
                if scope.isCurrent, actionRun == run { self.error = CommunityGateway.normalize(error).errorDescription }
            }
        }
    }
    @MainActor private func settleReaction(run: UUID? = nil, confirmed: Bool) {
        guard let pending = pendingReaction, run == nil || run == pending.run else { return }
        timeline.finish(pending.key, confirmed: confirmed, snapshot: pending.snapshot)
        pendingReaction = nil
    }
    @MainActor private func pauseWork() {
        // Snapshot covers the whole row array: settle it before epoch advance,
        // and never permit another action/page merge while it is outstanding.
        settleReaction(confirmed: false)
        activity.update(available: false); activity.invalidate()
        epoch = UUID()
        actionTask?.cancel(); actionTask = nil; actionRun = nil
        loadTask?.cancel(); loadTask = nil; loadRun = nil; loading = false
        playback = nil; linkShare = nil; blocking = nil
        invalidateExportScope()
    }
    @MainActor private func updateAvailability() {
        guard subjectWindowVisible, phase == .active, listingIdentity == identity else { pauseWork(); return }
        activity.update(available: true)
        if activity.canInteract, !loaded, timeline.posts.isEmpty { requestLoad(reset: false) }
    }

    /// Capture authorization and scope at the tap, before a queued Task can
    /// run under another account. The task is owned and cancelled by this view.
    @MainActor private func beginExport(_ post: FeedPost, tap: FeedExportListing.Tap?) {
        guard exporting == nil, exportFile == nil, let context = exportContext else { return }
        guard let tap, let permission = exportListing?.authorize(tap, rendered: post, current: context, visibleRows: timeline.posts) else {
            error = "Refresh the feed before exporting this video."; return
        }
        let account = context.account
        guard !FeedExportFile.hasOutstandingConsumer else {
            error = "The previous video share is still finishing. Close it before exporting another video."; return
        }
        let run = UUID(), revision = exportEpoch, scope = identity
        exporting = permission.post.id; exportRun = run; exportProgress = nil; error = nil
        exportTask = Task { @MainActor in
            let isCurrent = {
                !Task.isCancelled && exportRun == run && exportEpoch == revision && identity == scope &&
                    exportContext == context && exportListing?.contains(permission, current: exportContext, visibleRows: timeline.posts) == true
            }
            defer {
                if exportRun == run { exporting = nil; exportRun = nil; exportTask = nil; exportProgress = nil }
            }
            do {
                let file = try await CommunityServices.feed.downloadExportFile(for: permission, isCurrent: isCurrent, progress: { progress in
                    Task { @MainActor in
                        if exportRun == run && exportEpoch == revision && auth.userId == account && identity == scope &&
                            exportListing?.contains(permission, current: exportContext, visibleRows: timeline.posts) == true {
                            exportProgress = progress
                        }
                    }
                })
                guard isCurrent() else { try? FileManager.default.removeItem(at: file); return }
                exportFile = FeedExportFile(url: file, title: permission.post.title, account: account, generation: revision)
            } catch is CancellationError {
                // Explicit cancellation and stale scopes never display failure
                // in a newer account or overwrite another export's state.
            } catch { if isCurrent() { self.error = CommunityGateway.normalize(error).errorDescription } }
        }
    }
    @MainActor private func cancelExport() {
        exportTask?.cancel(); exportTask = nil
        exportRun = nil; exporting = nil; exportProgress = nil
    }
    @MainActor private func revokeViewerListing() {
        if listingIdentity != identity { pauseWork() }
    }
    @MainActor private func invalidateExportScope() {
        exportListing = nil
        exportEpoch = UUID()
        cancelExport()
        exportFile?.ownerClosed(); exportFile = nil
    }

}

/// The ScrollView's own bounds, excluding title/filter chrome. Child poster
/// frames are measured in this same named space on iOS17.
private struct FeedViewportBoundsKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@MainActor
private final class FeedWindowActivity: ObservableObject {
    @Published private(set) var revision = UUID()
    private var available = false
    func update(available: Bool) {
        if self.available != available { self.available = available; revision = UUID() }
    }
    func invalidate() { revision = UUID() }
    var canInteract: Bool {
        let auth = AuthService.shared
        return available && UIApplication.shared.applicationState == .active &&
            auth.isAuthenticated && !auth.passwordRecoveryPending && auth.currentUser?.id != nil &&
            auth.currentUser?.id == CommunityServices.feed.gateway.transport.sessionAccountID
    }
}
private enum FeedOwnedAction { case like, follow, block, report(FeedReportReason) }
private struct FeedPendingReaction {
    let run: UUID
    let key: UUID
    let snapshot: FeedTimeline.Snapshot
}
private struct FeedLinkShareOffer: Identifiable {
    let id = UUID()
    let url: URL
    let scope: CommunityOperationScope
}
@MainActor
private struct FeedLinkSharePresenter: UIViewControllerRepresentable {
    let offer: FeedLinkShareOffer
    let onTerminal: @MainActor () -> Void
    func makeUIViewController(context: Context) -> Host { Host(offer: offer, onTerminal: onTerminal) }
    func updateUIViewController(_ host: Host, context: Context) { if !offer.scope.isCurrent { host.close() } }
    static func dismantleUIViewController(_ host: Host, coordinator: ()) { host.close() }
    final class Host: UIViewController {
        private let offer: FeedLinkShareOffer
        private let onTerminal: @MainActor () -> Void
        private var presented = false
        init(offer: FeedLinkShareOffer, onTerminal: @escaping @MainActor () -> Void) {
            self.offer = offer; self.onTerminal = onTerminal; super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { return nil }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }
            guard offer.scope.isCurrent else { close(); onTerminal(); return }
            presented = true
            let activity = UIActivityViewController(activityItems: [offer.url], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in Task { @MainActor in self.onTerminal() } }
            activity.popoverPresentationController?.sourceView = view
            activity.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(activity, animated: true)
        }
        func close() { presentedViewController?.dismiss(animated: false) }
    }
}

private struct FeedPlaybackItem: Identifiable {
    let id = UUID()
    let postID: UUID
    let creator: UUID
    let source: FeedPlaybackSource
    let title: String
    let scope: CommunityOperationScope
}

/// Provider-aware entry point shared by Home and Profile. A watch-page URL is
/// never passed to AVPlayer. Unsupported YouTube addresses fail visibly.
struct CommunityVideoPlayer: View {
    let source: FeedPlaybackSource?
    let title: String
    let isAllowed: @MainActor () -> Bool
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    init(source: FeedPlaybackSource, title: String, isAllowed: @escaping @MainActor () -> Bool = { true }) { self.source = source; self.title = title; self.isAllowed = isAllowed }
    init(url: URL, title: String, isAllowed: @escaping @MainActor () -> Bool = { true }) { self.source = FeedPlaybackSource.resolve(url.absoluteString); self.title = title; self.isAllowed = isAllowed }
    var body: some View {
        Group {
            if isAllowed(), phase == .active, let source {
                switch source {
                case .rendition(let url): CommunityRenditionPlayer(url: url, title: title, isAllowed: isAllowed)
                case .youtube(let video): CommunityYouTubePlayer(video: video, title: title, isAllowed: isAllowed)
                }
            } else {
                Text("This video address is unsupported or unavailable.")
                    .padding().accessibilityIdentifier("feed.player.unsupported")
            }
        }
        .onChange(of: phase) { _, value in if value != .active { dismiss() } }
    }
}


/// Plays one approved HTTPS rendition after an explicit tap. Shows loading,
/// slow-start, buffering and failure states from the player itself, caps
/// bit rate and resolution on expensive (cellular/hotspot) networks and keeps
/// a short forward buffer. Retry builds a fresh item; closing stops playback.
/// No account token is attached to the media request.
private struct CommunityRenditionPlayer: View {
    let url: URL
    let title: String
    let isAllowed: @MainActor () -> Bool
    @StateObject private var model = CommunityVideoPlayerModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: model.player).accessibilityLabel("Video: \(title)")
            if let message = model.state.message {
                VStack(spacing: 12) {
                    if case .failed = model.state {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).accessibilityHidden(true)
                    } else { ProgressView().tint(.white) }
                    Text(message).font(.specialElite(14, relativeTo: .callout)).multilineTextAlignment(.center)
                    if case .failed = model.state {
                        HStack(spacing: 12) {
                            Button("Retry") { if isAllowed() { model.load(url) } }.buttonStyle(CommunitySecondaryButtonStyle())
                                .accessibilityIdentifier("feed.player.retry")
                            Button("Close") { dismiss() }.buttonStyle(CommunitySecondaryButtonStyle())
                        }
                    }
                }
                .foregroundStyle(.white).padding(20)
                .background(.black.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("feed.player.status")
            }
        }
        .onAppear { if isAllowed() { model.load(url) } }
        .onDisappear { model.stop() }
    }
}

/// An OS WebView loads YouTube's own embedded player only after the feed tap.
/// No SDI session/cookies are attached and WebKit data is nonpersistent. Player
/// errors (removed/private/embedding disabled/age restrictions) remain YouTube's
/// own UI; navigation finishing is never reported as successful video playback.
@MainActor
private struct CommunityYouTubePlayer: View {
    let video: YouTubeVideo
    let title: String
    let isAllowed: @MainActor () -> Bool
    @State private var loading = true
    @State private var failure: String?
    @State private var retryID = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    if let configuration = video.embedConfiguration(bundleIdentifier: Bundle.main.bundleIdentifier) {
                        YouTubeEmbeddedWebView(configuration: configuration, loading: $loading, failure: $failure, isAllowed: isAllowed)
                            .id(retryID)
                            .frame(width: max(200, geometry.size.width - 32), height: max(200, (geometry.size.width - 32) * 9 / 16))
                            .accessibilityLabel("YouTube video: \(title)")
                            .accessibilityIdentifier("feed.player.youtube")
                        if loading { ProgressView("Loading YouTube player…") }
                        if let failure {
                            Text(failure).accessibilityIdentifier("feed.player.youtube-error")
                            Button("Retry player") { if isAllowed() { loading = true; self.failure = nil; retryID = UUID() } }
                                .accessibilityIdentifier("feed.player.youtube-retry")
                        }
                    } else {
                        Text("The YouTube player is unavailable in this build. Open the video on YouTube.")
                            .accessibilityIdentifier("feed.player.youtube-unconfigured")
                    }
                    Text("Use YouTube’s controls to play. If playback is unavailable here, open YouTube. YouTube may show ads and collect playback data. File downloads are unavailable.")
                        .font(.callout)
                    HStack(spacing: 20) {
                        Button("Open on YouTube") { if isAllowed() { openURL(video.watchURL) } }
                            .accessibilityIdentifier("feed.player.youtube-open")
                        Button("Close") { dismiss() }
                    }
                }.padding(16)
            }
        }
    }
}

@MainActor
private struct YouTubeEmbeddedWebView: UIViewRepresentable {
    let configuration: YouTubeEmbedConfiguration
    @Binding var loading: Bool
    @Binding var failure: String?
    let isAllowed: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(configuration: configuration, loading: $loading, failure: $failure, isAllowed: isAllowed) }
    func makeUIView(context: Context) -> WKWebView {
        let settings = WKWebViewConfiguration()
        settings.websiteDataStore = .nonPersistent()
        settings.allowsInlineMediaPlayback = true
        settings.mediaTypesRequiringUserActionForPlayback = .all
        settings.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: settings)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        var request = URLRequest(url: configuration.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(configuration.referer.absoluteString, forHTTPHeaderField: "Referer")
        if isAllowed() { view.load(request) }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if !isAllowed() { view.stopLoading(); view.loadHTMLString("", baseURL: nil) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        // Removing the document destroys its media session. No background player,
        // download task, account session, or persistent website store is retained.
        view.stopLoading()
        view.navigationDelegate = nil; view.uiDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let configuration: YouTubeEmbedConfiguration
        let loading: Binding<Bool>
        let failure: Binding<String?>
        let isAllowed: @MainActor () -> Bool
        init(configuration: YouTubeEmbedConfiguration, loading: Binding<Bool>, failure: Binding<String?>, isAllowed: @escaping @MainActor () -> Bool) {
            self.configuration = configuration; self.loading = loading; self.failure = failure; self.isAllowed = isAllowed
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if isAllowed() { loading.wrappedValue = false } }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard isAllowed() else { return }
            loading.wrappedValue = false; failure.wrappedValue = "The YouTube player stopped. Retry or open YouTube."
        }
        private func failed(_ error: Error) {
            guard isAllowed() else { return }
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            loading.wrappedValue = false
            failure.wrappedValue = "The YouTube player could not load. Check your connection, retry or open YouTube."
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard isAllowed(), !navigationAction.shouldPerformDownload else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame?.isMainFrame == true {
                let url = navigationAction.request.url
                if url != configuration.url {
                    // YouTube controls and branding may open links on a user tap;
                    // they cannot navigate this app's player to arbitrary documents.
                    if navigationAction.navigationType == .linkActivated { openExternal(url) }
                    else {
                        loading.wrappedValue = false
                        failure.wrappedValue = "YouTube needs to open outside this player. Use Open on YouTube."
                    }
                    decisionHandler(.cancel); return
                }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(isAllowed() && navigationResponse.canShowMIMEType ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Automatic windows are disabled above; HTTPS links from the player's
            // user-initiated popups leave through the operating system.
            if navigationAction.targetFrame == nil { openExternal(navigationAction.request.url) }
            return nil
        }
        private func openExternal(_ url: URL?) {
            guard isAllowed(), let url, let checked = CommunityMediaURL.checked(url.absoluteString) else { return }
            UIApplication.shared.open(checked)
        }
    }
}

@MainActor
final class CommunityVideoPlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var state: FeedPlaybackState = .loading
    private var observers: Set<AnyCancellable> = []
    private var started = Date()
    private var ended = false
    private var slowTimer: Task<Void, Never>?

    func load(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = FeedPlaybackPolicy.forwardBufferSeconds
        item.preferredPeakBitRateForExpensiveNetworks = FeedPlaybackPolicy.expensiveNetworkPeakBitRate
        item.preferredMaximumResolutionForExpensiveNetworks = CGSize(width: FeedPlaybackPolicy.expensiveNetworkMaximumHeight * 16 / 9,
                                                                     height: FeedPlaybackPolicy.expensiveNetworkMaximumHeight)
        started = Date(); ended = false; state = .loading
        item.publisher(for: \.status).receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.ended = true; self?.refresh() }.store(in: &observers)
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(forcedFailure: true) }.store(in: &observers)
        player.replaceCurrentItem(with: item)
        player.play()
        slowTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(FeedPlaybackPolicy.slowStartSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
    func stop() {
        slowTimer?.cancel(); slowTimer = nil
        observers.removeAll()
        player.pause(); player.replaceCurrentItem(with: nil)
    }
    private func refresh(forcedFailure: Bool = false) {
        guard let item = player.currentItem else { return }
        if item.status == .readyToPlay || item.status == .failed { slowTimer?.cancel() }
        state = FeedPlaybackState.resolve(itemReady: item.status == .readyToPlay,
                                          itemFailed: forcedFailure || item.status == .failed,
                                          waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                                          playing: player.timeControlStatus == .playing,
                                          ended: ended,
                                          elapsed: Date().timeIntervalSince(started),
                                          failureText: nil)
    }
}
/// A native activity owns its file independently of SwiftUI presentation.
/// Dismantling the host only closes the owner; an offered file awaits UIKit's
/// completion callback, even if account/foreground changes dismiss the sheet.
@MainActor
private struct FeedExportSharePresenter: UIViewControllerRepresentable {
    let file: FeedExportFile
    let isAllowed: @MainActor () -> Bool
    let onTerminal: @MainActor () -> Void
    func makeUIViewController(context: Context) -> Host {
        Host(file: file, isAllowed: isAllowed, onTerminal: onTerminal)
    }
    func updateUIViewController(_ controller: Host, context: Context) { controller.updateAuthorization(isAllowed) }
    static func dismantleUIViewController(_ controller: Host, coordinator: ()) { controller.detach() }

    final class Host: UIViewController {
        private let file: FeedExportFile
        private var isAllowed: @MainActor () -> Bool
        private var onTerminal: (@MainActor () -> Void)?
        private var activity: UIActivityViewController?
        private var attempted = false
        init(file: FeedExportFile, isAllowed: @escaping @MainActor () -> Bool, onTerminal: @escaping @MainActor () -> Void) {
            self.file = file; self.isAllowed = isAllowed; self.onTerminal = onTerminal
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("Programmatic video sharing only") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !attempted else { return }
            attempted = true
            guard isAllowed(), file.offerToShare() else { file.ownerClosed(); finishUI(); return }
            let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
            controller.completionWithItemsHandler = { [file, weak self] _, _, _, _ in
                Task { @MainActor in file.consumerFinished(); self?.finishUI() }
            }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = view; popover.sourceRect = view.bounds; popover.permittedArrowDirections = []
            }
            activity = controller
            present(controller, animated: true)
        }
        func updateAuthorization(_ allowed: @escaping @MainActor () -> Bool) {
            isAllowed = allowed
            if !allowed() { detach() }
        }
        func detach() {
            onTerminal = nil; isAllowed = { false }
            file.ownerClosed()
            // Keep the consumer callback installed. A dismiss animation is not
            // evidence that an activity extension has stopped reading the file.
            activity?.dismiss(animated: false)
        }
        private func finishUI() {
            activity = nil
            let callback = onTerminal; onTerminal = nil
            callback?()
        }
    }
}

// MARK: - Private feed wall presentation

private enum FeedWallPalette {
    static let paper = Color(hex: "EFEAE0")
    static let ink = Color(hex: "101011")
    static let grey = Color(hex: "BDB9B3")
    static let red = Color(hex: "FF454C")
}

/// The owned website's dither and square windows, drawn natively without assets.
private struct FeedWallDesktop: View {
    var body: some View {
        FeedWallPalette.grey.overlay {
            Canvas { context, size in
                for y in stride(from: CGFloat(0), through: size.height, by: 6) {
                    let offset: CGFloat = Int(y / 6).isMultiple(of: 2) ? 0 : 3
                    for x in stride(from: offset, through: size.width, by: 6) {
                        context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(FeedWallPalette.ink.opacity(0.18)))
                    }
                }
            }.accessibilityHidden(true).allowsHitTesting(false)
        }
    }
}

private struct FeedWallStripes: View {
    var body: some View {
        Canvas { context, size in
            for y in stride(from: CGFloat(2), through: size.height, by: 3) {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(FeedWallPalette.ink))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct FeedWallWindow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FeedWallPalette.paper)
            .overlay(Rectangle().strokeBorder(FeedWallPalette.ink, lineWidth: 2))
            .shadow(color: FeedWallPalette.ink, radius: 0, x: 2, y: 2)
    }
}

private struct FeedWallTitleBar<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.specialElite(15, relativeTo: .headline))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(FeedWallPalette.paper)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing.background(FeedWallPalette.paper)
        }
        .padding(.leading, 6).padding(.trailing, 2).padding(.vertical, 2)
        .frame(minHeight: 44)
        .background(FeedWallStripes())
        .overlay(alignment: .bottom) { FeedWallPalette.ink.frame(height: 2) }
    }
}

private struct FeedWallGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let width: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 18, alignment: .top),
                                 count: width >= 760 && !dynamicType.isAccessibilitySize ? 2 : 1),
                  alignment: .leading, spacing: 18) { content }
    }
}

private struct FeedWallActionGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: dynamicType.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 112), spacing: 10)],
                  alignment: .leading, spacing: 10) { content }
    }
}

private struct FeedWallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.specialElite(14, relativeTo: .callout))
            .foregroundStyle(FeedWallPalette.ink.opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background {
                Rectangle()
                    .fill(isEnabled && selected ? FeedWallPalette.red : isEnabled ? FeedWallPalette.paper : FeedWallPalette.grey)
                    .overlay(Rectangle().strokeBorder(FeedWallPalette.ink, lineWidth: 2))
                    .shadow(color: FeedWallPalette.ink, radius: 0, x: configuration.isPressed ? 0 : 2, y: configuration.isPressed ? 0 : 2)
            }
            .offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 2 : 0)
    }
}

private struct FeedWallMessage: View {
    let text: String
    let kind: CommunityMessage.Kind
    var body: some View {
        Label {
            Text(text).font(.specialElite(13, relativeTo: .footnote))
        } icon: {
            Image(systemName: icon).foregroundStyle(FeedWallPalette.ink)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(FeedWallPalette.paper)
        .overlay(alignment: .leading) { FeedWallPalette.red.frame(width: errorStripeWidth) }
        .overlay(Rectangle().strokeBorder(FeedWallPalette.ink, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
    private var errorStripeWidth: CGFloat {
        if case .error = kind { return 4 }
        return 0
    }
    private var icon: String {
        switch kind {
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .offline: return "wifi.slash"
        case .success: return "checkmark.circle"
        }
    }
}

private extension View {
    func feedWallCaption() -> some View {
        font(.specialElite(12, relativeTo: .caption)).foregroundStyle(FeedWallPalette.ink.opacity(0.74))
    }
}
