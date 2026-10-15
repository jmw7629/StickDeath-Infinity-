import SwiftUI
import AVKit
import Combine

/// Social video wall over `sdi_feed_page` (keyset pages) and `sdi_feed_action`
/// (reactions): approved renditions only, server ranking for Trending/Recent/
/// Following/Featured, bounded pages, idempotent likes/follows with rollback,
/// HTTPS playback with loading/error states and sharing, and file export only
/// where the creator permits it and the viewer's plan includes downloads.
/// No text posts, comments or chat.
struct HomeFeedView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
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
    @State private var exportFile: FeedExportFile?
    @State private var blocking: FeedPost?
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active):\(category.rawValue)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("StickDeath ∞").font(.specialElite(24, relativeTo: .title)).foregroundStyle(StudioCraftTheme.accentText)
                Spacer()
                Button { Task { await load(reset: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("Refresh feed").disabled(loading)
                    .accessibilityIdentifier("feed.home.refresh")
            }.padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FeedCategory.allCases, id: \.self) { filter in
                        Button(filter.title) { category = filter }
                            .font(.specialElite(13, relativeTo: .footnote)).padding(.horizontal, 14).frame(minHeight: 40)
                            .background(category == filter ? StudioCraftTheme.accent : StudioCraftTheme.card)
                            .foregroundStyle(Color.white)
                            .clipShape(Capsule())
                            .accessibilityAddTraits(category == filter ? .isSelected : [])
                            .accessibilityHint(filter.explanation)
                            .accessibilityIdentifier("feed.home.filter." + filter.rawValue)
                    }
                }.padding(.horizontal, 16)
            }
            ScrollView {
                LazyVStack(spacing: 16) {
                    if !CommunityServices.isConfigured { CommunityMessage(text: CommunityServices.notConfiguredText, kind: .info) }
                    if !auth.isAuthenticated {
                        CommunitySignInPrompt(text: "Sign in to view the community feed.", identifier: "feed.home.sign-in")
                    }
                    Text(category.explanation).communityCaption()
                    if let error { CommunityMessage(text: error, kind: .error).accessibilityIdentifier("feed.home.error") }
                    if let notice { CommunityMessage(text: notice, kind: .success).accessibilityIdentifier("feed.home.notice") }
                    if let offlineUpdatedAt {
                        CommunityMessage(text: "Offline · last updated \(offlineUpdatedAt.formatted(date: .abbreviated, time: .shortened)). Reactions need a connection.", kind: .offline)
                            .accessibilityIdentifier("feed.home.offline")
                    }
                    ForEach(timeline.posts) { post in card(post) }
                    if loading { ProgressView().tint(StudioCraftTheme.accent).padding() }
                    if auth.isAuthenticated && loaded && !loading && timeline.posts.isEmpty && error == nil {
                        Text("No approved videos in this feed yet.").communityCaption().padding()
                            .accessibilityIdentifier("feed.home.empty")
                    }
                    if auth.isAuthenticated && timeline.canLoadMore && !loading && offlineUpdatedAt == nil {
                        Button(error == nil ? "Load more" : "Retry") { Task { await load(reset: false) } }
                            .buttonStyle(CommunitySecondaryButtonStyle())
                            .accessibilityIdentifier("feed.home.load-more")
                    }
                    if auth.isAuthenticated && !timeline.canLoadMore && timeline.nextPage >= FeedTimeline.maximumPages {
                        Text("Showing the first \(FeedTimeline.maximumPages * FeedTimeline.pageSize) videos of this ranking. Refresh to restart.").communityCaption()
                    }
                }.padding(16).padding(.bottom, 60)
            }.refreshable { await load(reset: true) }
        }
        .communityScreen()
        .task(id: identity) {
            epoch = UUID(); timeline.reset(); loading = false; loaded = false
            playback = nil; error = nil; notice = nil; offlineUpdatedAt = nil; exporting = nil
            if phase == .active { await load(reset: true) }
        }
        .sheet(item: $playback) { item in CommunityVideoPlayer(url: item.url, title: item.title) }
        .sheet(item: $exportFile, onDismiss: { exportFile?.cleanUp(); exportFile = nil }) { file in
            ShareLink(item: file.url) { Label("Save or share \(file.title)", systemImage: "square.and.arrow.down").frame(minHeight: 44) }
                .padding().presentationDetents([.fraction(0.25)])
        }
        .confirmationDialog("Block this creator?", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }), titleVisibility: .visible, presenting: blocking) { post in
            Button("Block \(post.creator_name)", role: .destructive) { Task { await block(post) } }
            Button("Cancel", role: .cancel) { blocking = nil }
        } message: { post in
            Text("You will no longer see \(post.creator_name)'s videos and they will not see yours. This does not report them.")
        }
        .onDisappear { playback = nil }
    }

    private func card(_ post: FeedPost) -> some View {
        CommunityCard {
            HStack {
                Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(StudioCraftTheme.textDim).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.creator_name).font(.specialElite(16, relativeTo: .body))
                    Text(post.published_at, style: .relative).communityCaption()
                }
                Spacer()
                Menu {
                    if post.creator.uuidString.lowercased() != auth.userId?.lowercased() {
                        Button(post.following ? "Unfollow creator" : "Follow creator") { Task { await follow(post) } }
                        Button("Block creator", role: .destructive) { blocking = post }
                    }
                    Menu("Report video") {
                        ForEach(FeedReportReason.allCases, id: \.self) { reason in
                            Button(reason.title) { Task { await report(post, reason) } }
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .disabled(offlineUpdatedAt != nil)
                    .accessibilityLabel("More actions for \(post.title)")
                    .accessibilityIdentifier("feed.card.menu")
            }
            Button {
                guard let url = post.safeURL else { error = "Video address is unavailable."; return }
                playback = FeedPlaybackItem(url: url, title: post.title)
            } label: {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 56)).foregroundStyle(StudioCraftTheme.accentText)
                    Text(post.title).font(.specialElite(18, relativeTo: .title3)).foregroundStyle(StudioCraftTheme.text)
                }.frame(maxWidth: .infinity, minHeight: 190).background(StudioCraftTheme.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
            }.accessibilityLabel("Play \(post.title)").accessibilityIdentifier("feed.card.play")
            if !post.caption.isEmpty { Text(post.caption).font(.specialElite(14, relativeTo: .callout)) }
            HStack(spacing: 18) {
                Button { Task { await like(post) } } label: {
                    Label(String(post.likes), systemImage: post.liked ? "heart.fill" : "heart")
                        .foregroundStyle(post.liked ? StudioCraftTheme.accentText : StudioCraftTheme.textDim)
                        .frame(minHeight: 44)
                }
                .disabled(timeline.inFlight.contains(post.id) || offlineUpdatedAt != nil)
                .accessibilityLabel("\(post.liked ? "Unlike" : "Like") video, \(post.likes) likes")
                .accessibilityIdentifier("feed.card.like")
                if let url = post.safeURL {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                        .accessibilityIdentifier("feed.card.share")
                }
                if FeedExportPolicy.canExport(post) {
                    Button { Task { await export(post) } } label: {
                        Label(exporting == post.id ? "Exporting…" : "Export", systemImage: "square.and.arrow.down").frame(minHeight: 44)
                    }
                    .disabled(exporting != nil)
                    .accessibilityHint("The creator permits saving this video file.")
                    .accessibilityIdentifier("feed.card.export")
                }
                Spacer()
            }.font(.specialElite(13, relativeTo: .footnote))
            switch FeedExportPolicy.state(post) {
            case .allowed: EmptyView()
            case .needsPaidPlan: Text("The creator permits saving this video; saving files needs a paid plan. Sharing the link is allowed.").communityCaption()
                    .accessibilityIdentifier("feed.card.export-plan")
            case .notPermitted: Text("Export not permitted by the creator; sharing links is allowed.").communityCaption()
            }
        }
        .accessibilityIdentifier("feed.card")
    }

    @MainActor private func load(reset: Bool) async {
        guard !loading, auth.isAuthenticated, let account = auth.userId else { return }
        if reset { epoch = UUID(); timeline.reset(); offlineUpdatedAt = nil }
        guard timeline.canLoadMore else { return }
        let revision = epoch, page = timeline.nextPage
        loading = true
        defer { if revision == epoch { loading = false } }
        do {
            let result = try await CommunityServices.feed.page(category, page: page, account: account, asOf: timeline.asOf, cursor: timeline.nextCursor)
            guard !Task.isCancelled, revision == epoch, account == auth.userId else { return }
            try timeline.merge(page: page, posts: result.posts, hasMore: result.hasMore, asOf: result.asOf, cursor: result.cursor)
            if case .cache(let updatedAt) = result.source { offlineUpdatedAt = updatedAt } else { offlineUpdatedAt = nil }
            loaded = true; error = nil
        } catch { if revision == epoch { loaded = true; self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    @MainActor private func like(_ post: FeedPost) async {
        guard auth.isAuthenticated, let snapshot = timeline.beginLike(post.id, enabled: !post.liked) else { return }
        let revision = epoch
        var confirmed = false
        do { confirmed = try await CommunityServices.feed.like(post.id, enabled: !post.liked) }
        catch { if revision == epoch { self.error = CommunityGateway.normalize(error).errorDescription } }
        guard revision == epoch else { return }
        timeline.finish(post.id, confirmed: confirmed, snapshot: snapshot)
        if !confirmed && error == nil { error = "The like was not confirmed. The count shows the server's last value." }
    }
    @MainActor private func follow(_ post: FeedPost) async {
        guard auth.isAuthenticated, let snapshot = timeline.beginFollow(post.creator, enabled: !post.following) else { return }
        let revision = epoch
        var confirmed = false
        do { confirmed = try await CommunityServices.feed.follow(post.creator, enabled: !post.following) }
        catch { if revision == epoch { self.error = CommunityGateway.normalize(error).errorDescription } }
        guard revision == epoch else { return }
        timeline.finish(post.creator, confirmed: confirmed, snapshot: snapshot)
        if confirmed { notice = post.following ? "Unfollowed \(post.creator_name)." : "Following \(post.creator_name)." }
    }
    @MainActor private func block(_ post: FeedPost) async {
        blocking = nil
        guard auth.isAuthenticated else { return }
        let revision = epoch
        do {
            if try await CommunityServices.feed.block(post.creator) {
                guard revision == epoch else { return }
                timeline.removeCreator(post.creator); notice = "Blocked \(post.creator_name)."
            } else if revision == epoch { error = "The block was not confirmed." }
        } catch { if revision == epoch { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    @MainActor private func report(_ post: FeedPost, _ reason: FeedReportReason) async {
        guard auth.isAuthenticated else { return }
        let revision = epoch
        do {
            if try await CommunityServices.feed.report(post.id, reason: reason) {
                if revision == epoch { notice = "Report recorded for moderation. Reporters are not identified to creators." }
            } else if revision == epoch { error = "The report was not confirmed." }
        } catch { if revision == epoch { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    /// Creator-permitted export: explicit tap, bounded download to a temporary
    /// file, then the system share sheet. Removed when the sheet closes.
    @MainActor private func export(_ post: FeedPost) async {
        guard exporting == nil else { return }
        exporting = post.id; let revision = epoch
        defer { if revision == epoch { exporting = nil } }
        do {
            let file = try await CommunityServices.feed.exportFile(for: post) { url in
                let (temporary, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw CommunityError.transport("The video could not be downloaded.")
                }
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-export-" + UUID().uuidString + ".mp4")
                try FileManager.default.moveItem(at: temporary, to: destination)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? -1
                return (destination, size)
            }
            guard revision == epoch else { try? FileManager.default.removeItem(at: file); return }
            exportFile = FeedExportFile(url: file, title: post.title)
        } catch { if revision == epoch { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
}

private struct FeedPlaybackItem: Identifiable { let id = UUID(); let url: URL; let title: String }

/// Plays one approved HTTPS rendition after an explicit tap. Shows loading,
/// slow-start, buffering and failure states from the player itself, caps
/// bit rate and resolution on expensive (cellular/hotspot) networks and keeps
/// a short forward buffer. Retry builds a fresh item; closing stops playback.
/// No account token is attached to the media request.
struct CommunityVideoPlayer: View {
    let url: URL
    let title: String
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
                            Button("Retry") { model.load(url) }.buttonStyle(CommunitySecondaryButtonStyle())
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
        .onAppear { model.load(url) }
        .onDisappear { model.stop() }
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
private struct FeedExportFile: Identifiable {
    let id = UUID(); let url: URL; let title: String
    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}
