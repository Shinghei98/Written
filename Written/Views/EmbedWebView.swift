import SwiftUI
import WebKit

/// A shared video, playing inside a card.
///
/// **The page comes from the server**, at
/// `…/functions/v1/player?v=<id>` — see `supabase/functions/player`. That is the
/// whole fix, and it took four failures to arrive at.
///
///     loadHTMLString with a base URL          -> error 152
///     the same, plus an `origin` player var   -> 152 again
///     loading youtube.com/embed top-level     -> 153, the referrer complaint
///     loadSimulatedRequest with a real URL    -> 152 again
///
/// Every one of those tried to give the page an origin without one existing. A
/// base URL resolves relative links; a player parameter is a claim; a simulated
/// request never touches a network. YouTube wanted a document actually served
/// from somewhere, and the only way to have one is to serve it.
///
/// What this view does now is small: load a URL, and call three functions the
/// page defines.
struct EmbedWebView: UIViewRepresentable {
    let videoID: String
    /// Whether this card is the one in the middle of the screen.
    var isPlaying: Bool
    /// Muted until the reader asks otherwise.
    var isMuted: Bool
    /// The player's own error code, for the debug line on the card.
    var onUnavailable: (Int) -> Void = { _ in }


    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Otherwise a tap takes the video full screen and out of the feed.
        configuration.allowsInlineMediaPlayback = true
        // Allowed *because it is muted*: WebKit blocks unmuted autoplay outright,
        // and a video that starts talking as it scrolls past is the thing this
        // must never become.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "written")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Part of a card, not a page inside one.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
#if DEBUG
        // Attachable from Safari → Develop → iPhone. Four attempts at this have
        // been reasoned from an error number and all four were wrong; the
        // console says what the number only hints at.
        if #available(iOS 16.4, *) { webView.isInspectable = true }
#endif
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.loaded != videoID {
            coordinator.loaded = videoID
            guard let url = Self.player(for: videoID) else { return }
            webView.load(URLRequest(url: url))
        }

        // Only the calls, never a reload — reloading a player mid-video restarts
        // it, which as a card scrolls in and out would mean starting from zero
        // every time.
        if coordinator.playing != isPlaying {
            coordinator.playing = isPlaying
            webView.evaluateJavaScript(isPlaying ? "wPlay()" : "wPause()")
        }
        if coordinator.muted != isMuted {
            coordinator.muted = isMuted
            webView.evaluateJavaScript(isMuted ? "wMute(true)" : "wMute(false)")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onUnavailable: onUnavailable) }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "written")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loaded: String?
        var playing = false
        var muted = true
        private let onUnavailable: (Int) -> Void

        init(onUnavailable: @escaping (Int) -> Void) {
            self.onUnavailable = onUnavailable
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String, body.hasPrefix("error:") else { return }
            onUnavailable(Int(body.dropFirst("error:".count)) ?? -1)
        }
    }

    /// The page, on the server. Public and sessionless — it wraps an embed
    /// that is already public — which is why the function is deployed without
    /// JWT verification: a web view navigating to a URL cannot attach an
    /// Authorization header.
    private static func player(for videoID: String) -> URL? {
        // `appendingPathComponent`, not string concatenation: `supabaseURL` has
        // no trailing slash, so joining it by hand produced
        // `supabase.cofunctions/v1/…` — a URL that parses fine and resolves to
        // nothing.
        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("functions/v1/player"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components?.url
    }
}
