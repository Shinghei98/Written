import SwiftUI
import WebKit

/// A shared video, playing inside a card.
///
/// The first `WKWebView` in this app, and it is deliberately a small one: it
/// shows an embed and nothing else. No navigation, no back and forward, nothing
/// the user could steer somewhere unexpected.
///
/// It loads an **HTML wrapper** rather than the embed URL directly. Pointed at
/// the embed page, the player sits inside a document with its own margins and a
/// white background, so the card gets a video floating in a box; the wrapper is
/// three lines of CSS that make the iframe *be* the frame.
struct EmbedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Otherwise a tap takes the video full screen and out of the feed.
        configuration.allowsInlineMediaPlayback = true
        // **Nothing plays on its own.** A feed that starts a video as it scrolls
        // past is the thing this must not become — one sound source arriving
        // unasked is worse than no video at all.
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // It is part of a card, not a page inside one: no bounce, no scrolling
        // of its own, and the parchment showing through while it loads rather
        // than a white rectangle appearing first.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Guarded, or every redraw of the feed reloads the page — which for a
        // player mid-video means it restarts.
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        webView.loadHTMLString(Self.page(for: url), baseURL: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: URL?
    }

    /// The wrapper. `border: 0` and the absolute fill are what stop the player
    /// being a small rectangle in the middle of a white page.
    private static func page(for url: URL) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, \
        maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: transparent; }
          iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
        </style>
        </head>
        <body>
        <iframe src="\(url.absoluteString)" allow="encrypted-media; picture-in-picture" \
        allowfullscreen></iframe>
        </body>
        </html>
        """
    }
}
