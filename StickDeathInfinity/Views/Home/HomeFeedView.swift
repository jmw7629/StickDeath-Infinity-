import SwiftUI
import AVKit
import Supabase

struct HomeFeedView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var posts: [VideoFeedPost] = []
    @State private var category = "recent"
    @State private var nextPage = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var updating = false
    @State private var error: String?
    @State private var notice: String?
    @State private var epoch = UUID()
    @State private var playback: FeedPlayback?
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active):\(category)" }
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("StickDeath ∞").font(.specialElite(24)).foregroundColor(.sdRed)
                Spacer()
                Button { Task { await load(reset: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh feed").disabled(loading)
            }.padding(16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(["trending","recent","following","featured"], id: \.self) { filter in
                        Button(filter.capitalized) { category = filter }
                            .font(.specialElite(14)).padding(.horizontal, 14).padding(.vertical, 10)
                            .background(category == filter ? Color.sdRed : Color.sdSurface)
                            .clipShape(Capsule())
                            .accessibilityAddTraits(category == filter ? .isSelected : [])
                    }
                }.padding(.horizontal, 16)
            }
            ScrollView {
                LazyVStack(spacing: 16) {
                    if !auth.isAuthenticated { Text("Sign in to view the community feed.").padding() }
                    if let error { Text(error).foregroundColor(.sdRed).padding() }
                    if let notice { Text(notice).font(.caption).foregroundColor(.sdTextSecondary) }
                    ForEach(posts) { post in card(post) }
                    if loading { ProgressView().padding() }
                    if auth.isAuthenticated && !loading && posts.isEmpty && error == nil {
                        Text("No approved videos in this feed yet.").foregroundColor(.sdTextSecondary).padding()
                    }
                    if auth.isAuthenticated && hasMore && !loading {
                        Button(error == nil ? "Load more" : "Retry") { Task { await load(reset: false) } }
                    }
                }.padding(16).padding(.bottom, 60)
            }.refreshable { await load(reset: true) }
        }
        .foregroundColor(.sdTextPrimary).background(Color.sdBackground.ignoresSafeArea())
        .task(id: identity) {
            epoch = UUID(); posts = []; nextPage = 0; hasMore = true; loading = false
            playback?.player.pause(); playback = nil; error = nil; notice = nil
            if phase == .active { await load(reset: true) }
        }
        .sheet(item: $playback) { item in
            VideoPlayer(player: item.player).onAppear { item.player.play() }.onDisappear { item.player.pause() }
        }
        .onDisappear { playback?.player.pause(); playback = nil }
    }
    private func card(_ post: VideoFeedPost) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.crop.circle.fill").font(.title)
                VStack(alignment: .leading) {
                    Text(post.creator_name).font(.specialElite(16))
                    Text(post.published_at, style: .relative).font(.caption).foregroundColor(.sdTextSecondary)
                }
                Spacer()
                Menu {
                    if post.creator.uuidString.lowercased() != auth.userId?.lowercased() {
                        Button(post.following ? "Unfollow creator" : "Follow creator") {
                            Task { await mutate(FeedRequest(action: "follow", target: post.creator, enabled: !post.following)) }
                        }
                        Button("Block creator", role: .destructive) {
                            Task { await mutate(FeedRequest(action: "block", target: post.creator)) }
                        }
                    }
                    Menu("Report video") {
                        ForEach(["rights","abuse","unsafe","spam"], id: \.self) { reason in
                            Button(reason.capitalized) { Task { await mutate(FeedRequest(action: "report", post_id: post.id, reason: reason)) } }
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44,height: 44) }
                    .disabled(updating)
            }
            Button {
                guard let url = post.safeURL else { error = "Video address is unavailable."; return }
                playback?.player.pause(); playback = FeedPlayback(player: AVPlayer(url: url))
            } label: {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 56))
                    Text(post.title).font(.specialElite(18))
                }.frame(maxWidth: .infinity, minHeight: 190).background(Color.sdBackground)
            }.accessibilityLabel("Play \(post.title)")
            if !post.caption.isEmpty { Text(post.caption).font(.callout) }
            HStack(spacing: 24) {
                Button {
                    Task { await mutate(FeedRequest(action: "like", post_id: post.id, enabled: !post.liked)) }
                } label: {
                    Label(String(post.likes), systemImage: post.liked ? "heart.fill" : "heart")
                        .foregroundColor(post.liked ? .sdRed : .sdTextSecondary)
                }.disabled(updating).accessibilityLabel("\(post.liked ? "Unlike" : "Like") video, \(post.likes) likes")
                if let url = post.safeURL { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
                Spacer()
            }
        }.padding(16).background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    @MainActor private func load(reset: Bool) async {
        guard !loading, auth.isAuthenticated, let account = auth.userId else { return }
        if reset { epoch = UUID(); posts = []; nextPage = 0; hasMore = true }
        let revision = epoch, page = nextPage
        loading = true
        defer { if revision == epoch { loading = false } }
        do {
            let response: FeedResponse = try await client.rpc("sdi_feed_action", params: FeedRequest(action: "list", category: category, page: page)).execute().value
            guard !Task.isCancelled, revision == epoch, account == auth.userId else { return }
            if let problem = response.error { error = problem; return }
            guard let incoming = response.posts, let more = response.has_more else { error = "The feed returned an incomplete response."; return }
            // Offset ranking may shift during engagement; preserve identity and
            // avoid duplicate cards. Pull-to-refresh restarts the current ranking.
            for post in incoming {
                if let index = posts.firstIndex(where: {$0.id == post.id}) { posts[index] = post }
                else { posts.append(post) }
            }
            nextPage = page + 1; hasMore = more && nextPage < 40; error = nil
        } catch { if revision == epoch { self.error = "The feed could not be loaded. Check your connection and service configuration." } }
    }
    @MainActor private func mutate(_ request: FeedRequest) async {
        guard !updating, auth.isAuthenticated, let account = auth.userId else { return }
        let revision = epoch; updating = true; notice = nil
        defer { updating = false }
        do {
            let response: FeedResponse = try await client.rpc("sdi_feed_action", params: request).execute().value
            guard !Task.isCancelled, revision == epoch, account == auth.userId else { return }
            if let problem = response.error { error = problem; return }
            guard response.status == "confirmed" else { error = "The action was not confirmed."; return }
            if request.action == "report" { notice = "Report recorded for moderation." }
            await load(reset: true)
        } catch { if revision == epoch { self.error = "The action was not confirmed. Refresh before retrying." } }
    }
}
private struct FeedPlayback: Identifiable { let id = UUID(); let player: AVPlayer }
private struct FeedRequest: Encodable {
    let action: String
    var post_id: UUID? = nil; var target: UUID? = nil; var enabled = true
    var category = "recent"; var page = 0; var reason: String? = nil
}
private struct FeedResponse: Decodable {
    let status: String?; let error: String?; let posts: [VideoFeedPost]?; let has_more: Bool?
}
private struct VideoFeedPost: Decodable, Identifiable {
    let id: UUID; let creator: UUID; let creator_name: String; let caption: String
    let published_at: Date; let allow_export: Bool; let title: String; let url: String
    let likes: Int; let liked: Bool; let following: Bool
    var safeURL: URL? {
        guard let parts = URLComponents(string: url), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}
