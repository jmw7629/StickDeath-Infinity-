import SwiftUI
import UIKit
import ImageIO

/// Artwork comes only from the approved row. A retained hidden card owns no
/// request; media uses no account credentials, cookies or persistent cache.
struct FeedPosterView: View {
    let post: FeedPost
    let generation: UUID
    let viewport: CGRect
    let isAllowed: @MainActor () -> Bool
    @Environment(\.scenePhase) private var phase
    @Environment(\.sdiSubjectWindowVisible) private var subjectWindowVisible
    @State private var posterFrame: CGRect?
    @StateObject private var loader = FeedPosterLoader()

    private var requestIdentity: String {
        "\(post.id):\(post.poster.url?.absoluteString ?? ""):\(generation):\(phase == .active):\(subjectWindowVisible):\(intersectsViewport)"
    }
    private var intersectsViewport: Bool {
        guard let posterFrame,
              viewport.width > 0, viewport.height > 0,
              !viewport.isNull, !viewport.isInfinite,
              !posterFrame.isNull, !posterFrame.isInfinite,
              posterFrame.width > 0, posterFrame.height > 0 else { return false }
        let visible = viewport.intersection(posterFrame)
        return !visible.isNull && !visible.isEmpty && visible.width > 0 && visible.height > 0
    }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork.frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190).clipped()
            Text(post.title).font(.specialElite(18, relativeTo: .title3)).foregroundStyle(StudioCraftTheme.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(StudioCraftTheme.canvas.opacity(0.85)).clipShape(Capsule()).padding(10)
        }
        .background(StudioCraftTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
        .background {
            GeometryReader { row in
                Color.clear.preference(key: FeedPosterBoundsKey.self,
                                       value: row.frame(in: .named("feed.home.viewport")))
            }
        }
        .onPreferenceChange(FeedPosterBoundsKey.self) { posterFrame = $0 }
        .onAppear { reload() }
        .onChange(of: requestIdentity) { _, _ in reload() }
        .onDisappear { loader.stop(clearImage: true) }
    }
    @MainActor private func reload() {
        // LazyVStack may realize a card before it enters the viewport. Unknown
        // bounds never authorize work; leaving the viewport also releases pixels.
        guard intersectsViewport else { loader.stop(clearImage: true); return }
        loader.start(post.poster.url, allowed: {
            intersectsViewport && phase == .active && subjectWindowVisible &&
                UIApplication.shared.applicationState == .active && isAllowed()
        })
    }
    @ViewBuilder private var artwork: some View {
        if let image = loader.image {
            Image(uiImage: image).resizable().scaledToFill().overlay(playBadge)
                .accessibilityIdentifier("feed.card.poster")
        } else { placeholder }
    }
    private var placeholder: some View {
        Image(systemName: "play.rectangle.fill").font(.system(size: 56)).foregroundStyle(StudioCraftTheme.accentText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("feed.card.poster-placeholder")
    }
    private var playBadge: some View {
        Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white).shadow(radius: 4)
    }
}

private struct FeedPosterBoundsKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() }
}

/// All URLSession callbacks are delivered on OperationQueue.main and enter
/// MainActor synchronously. Check -> create -> resume contains no suspension;
/// stopping a scope cancels its task rather than waiting for another Swift Task.
@MainActor
private final class FeedPosterLoader: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published private(set) var image: UIImage?
    private var imageURL: URL?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var allowed: (@MainActor () -> Bool)?
    private var data = Data()
    private var accepted = false
    private let maximumBytes = 4 * 1024 * 1024
    private let maximumPixels = 2_073_600

    func start(_ url: URL?, allowed: @escaping @MainActor () -> Bool) {
        stop(clearImage: false)
        guard let url, CommunityMediaURL.checked(url.absoluteString) == url, allowed() else { return }
        if imageURL == url, image != nil { return }
        image = nil; imageURL = nil
        self.allowed = allowed
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.httpAdditionalHeaders = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        guard allowed() else { session.invalidateAndCancel(); self.allowed = nil; return }
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }
    func stop(clearImage: Bool) {
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        allowed = nil; data = Data(); accepted = false
        if clearImage { image = nil; imageURL = nil }
    }
    private func owns(_ task: URLSessionTask) -> Bool {
        self.task === task && allowed?() == true && UIApplication.shared.applicationState == .active
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        // Refuse redirects, including any new request after a scope was paused.
        completionHandler(nil)
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                               completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated {
            guard self.task === dataTask else { completionHandler(.cancel); return }
            guard owns(dataTask), let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength < 0 || response.expectedContentLength <= Int64(maximumBytes) else {
                completionHandler(.cancel); stop(clearImage: false); return
            }
            accepted = true
            completionHandler(.allow)
        }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        MainActor.assumeIsolated {
            guard self.task === dataTask else { return }
            guard owns(dataTask), accepted, bytes.count <= maximumBytes - data.count else { stop(clearImage: false); return }
            data.append(bytes)
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard self.task === task else { return }
            guard owns(task), accepted, error == nil, !data.isEmpty,
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, width.intValue <= 4096, height.intValue > 0, height.intValue <= 4096,
                  width.intValue <= maximumPixels / height.intValue,
                  let decoded = UIImage(data: data) else { stop(clearImage: false); return }
            let url = task.originalRequest?.url
            stop(clearImage: false)
            image = decoded; imageURL = url
        }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                               willCacheResponse proposedResponse: CachedURLResponse,
                               completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
