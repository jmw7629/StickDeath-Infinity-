import SwiftUI

/// Feed card artwork (#217): the poster frame the publishing worker extracted from
/// the approved copy, or the plain play placeholder when the server recorded none or
/// the image cannot be loaded. The image is fetched over HTTPS without account
/// credentials; nothing is synthesized locally.
struct FeedPosterView: View {
    let post: FeedPost

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork.frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190).clipped()
            Text(post.title).font(.specialElite(18, relativeTo: .title3)).foregroundStyle(StudioCraftTheme.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(StudioCraftTheme.canvas.opacity(0.85)).clipShape(Capsule()).padding(10)
        }
        .background(StudioCraftTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
    }

    @ViewBuilder private var artwork: some View {
        if let url = post.poster.url {
            AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().overlay(playBadge).accessibilityIdentifier("feed.card.poster")
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
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
