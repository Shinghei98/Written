import SwiftUI
import WebKit

/// A shared video, playing inside a card.
///
/// **It loads YouTube's embed URL directly** rather than building a page around
/// an iframe, and that is the whole design rather than a detail of it.
///
/// The first version wrote its own HTML and let the IFrame API construct the
/// player inside it. Every video came back with error 152 — including "Me at the
/// zoo", which embeds everywhere — so it was the page and not the videos. A
/// document made by `loadHTMLString` is not really *from* anywhere: whatever
/// base URL it is handed, the request the player makes carries no origin YouTube
/// will accept, and adding an `origin` parameter to claim otherwise did not help
/// either. Two attempts at persuading it, both wrong.
///
/// Loading `youtube.com/embed/…` as a request removes the question rather than
/// answering it. The document is served by YouTube, so its origin *is*
/// YouTube's, and there is nothing left to declare.
///
/// The cost is the IFrame API: with no parent frame there is nobody to call
/// `playVideo()` from. Playback is driven through the `<video>` element the
/// player is built on instead — cruder, and it works.
struct EmbedWebView: UIViewRepresentable {
    let videoID: String
    /// Whether this card is the one in the middle of the screen.
    var isPlaying: Bool
    /// Muted until the reader asks otherwise.
    var isMuted: Bool
    /// No player ever appeared. Carries a code for the debug line on the card.
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
        webView.navigationDelegate = context.coordinator
        // Part of a card, not a page inside one.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.wantsPlaying = isPlaying
        coordinator.wantsMuted = isMuted

        if coordinator.loaded != videoID {
            coordinator.loaded = videoID
            guard let url = Self.embed(videoID) else { return }
            webView.load(URLRequest(url: url))
            // Nothing to send yet — the state is applied when the page finishes.
            return
        }
        coordinator.apply(to: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onUnavailable: onUnavailable) }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "written")
    }

    /// `controls=0` because the card decides when this plays, and a scrub bar on
    /// something that starts and stops with scrolling invites a fight over who
    /// is in charge. `rel=0` stops the end screen offering other people's
    /// videos, which in a feed reads as the app handing the reader off.
    private static func embed(_ videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/embed/\(videoID)"
            + "?playsinline=1&controls=0&rel=0&modestbranding=1&mute=1")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var loaded: String?
        var wantsPlaying = false
        var wantsMuted = true
        private let onUnavailable: (Int) -> Void

        init(onUnavailable: @escaping (Int) -> Void) {
            self.onUnavailable = onUnavailable
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            apply(to: webView)
        }

        /// Tells the `<video>` element what to do, waiting for it to exist.
        ///
        /// It is not there when the page reports itself finished — the player
        /// builds it a moment afterwards — so this retries for a few seconds
        /// rather than asking once and giving up. Running out of tries is also
        /// the only way a video that cannot play is noticed now, since the
        /// IFrame API's `onError` went with the wrapper page.
        func apply(to webView: WKWebView) {
            let script = """
            (function () {
              var tries = 0;
              function go() {
                var v = document.querySelector('video');
                if (v) {
                  v.muted = \(wantsMuted ? "true" : "false");
                  \(wantsPlaying
                    ? "var q = v.play(); if (q && q.catch) { q.catch(function () {}); }"
                    : "v.pause();")
                  return;
                }
                if (++tries > 40) {
                  window.webkit.messageHandlers.written.postMessage('error:-2');
                  return;
                }
                setTimeout(go, 100);
              }
              go();
            })();
            """
            webView.evaluateJavaScript(script)
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String, body.hasPrefix("error:") else { return }
            onUnavailable(Int(body.dropFirst("error:".count)) ?? -1)
        }
    }
}
