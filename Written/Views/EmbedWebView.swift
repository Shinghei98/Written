import SwiftUI
import WebKit

/// A shared video, playing inside a card.
///
/// **The page is a normal iframe embed, given a real origin by
/// `loadSimulatedRequest`.** Everything difficult here was one problem wearing
/// three hats, and it took three wrong answers to see it: locally-made HTML has
/// no origin, and YouTube's player will not run without one.
///
/// - `loadHTMLString` with a base URL → **error 152**. A base URL is not an
///   origin; the document still comes from nowhere.
/// - The same, plus an `origin` player parameter → **152 again**. Declaring an
///   origin the document does not have persuades nobody.
/// - Loading `youtube.com/embed/…` as a top-level request → **error 153**, which
///   is the referrer complaint. The document had a real origin at last, but an
///   app navigating straight to an embed sends no `Referer`, and the embed
///   endpoint expects to be inside a page.
///
/// `loadSimulatedRequest(_:responseHTML:)` gives our own HTML the origin of a
/// URL we name — not a base for resolving links, the actual security origin. So
/// the iframe sits in a page that genuinely is `youtube.com`, which is the one
/// arrangement the player accepts. It is iOS 15 and up; this project ships to
/// 16.
///
/// Having a page back also restores the IFrame API, and with it `playVideo`,
/// `pauseVideo` and a real `onError` to report codes rather than inferring them
/// from a `<video>` element that never turned up.
struct EmbedWebView: UIViewRepresentable {
    let videoID: String
    /// Whether this card is the one in the middle of the screen.
    var isPlaying: Bool
    /// Muted until the reader asks otherwise.
    var isMuted: Bool
    /// The player's own error code, for the debug line on the card.
    var onUnavailable: (Int) -> Void = { _ in }

    /// What the page pretends to be. The iframe it holds is served from the same
    /// place, so the embed is same-origin with its container — which is the
    /// situation YouTube is built for and every previous attempt was not.
    private static let origin = "https://www.youtube.com"

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
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.loaded != videoID {
            coordinator.loaded = videoID
            guard let url = URL(string: Self.origin + "/embed/" + videoID) else { return }
            webView.loadSimulatedRequest(
                URLRequest(url: url),
                responseHTML: Self.page(for: videoID)
            )
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

    /// The player, and the three functions Swift calls into it.
    ///
    /// `controls=0` because the card decides when this plays, and a scrub bar on
    /// something that starts and stops with scrolling invites a fight over who
    /// is in charge. `rel=0` stops the end screen offering other people's
    /// videos, which in a feed reads as the app handing the reader off.
    ///
    /// It starts **muted**, and that is not a detail: WebKit blocks unmuted
    /// autoplay outright, so an unmuted player would simply never begin.
    private static func page(for videoID: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, \
        maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: #000; \
        overflow: hidden; }
          #player { position: absolute; inset: 0; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script src="\(origin)/iframe_api"></script>
        <script>
          var p, ready = false, wantPlay = false, wantMute = true;

          function onYouTubeIframeAPIReady() {
            p = new YT.Player('player', {
              videoId: '\(videoID)',
              playerVars: {
                playsinline: 1, rel: 0, controls: 0, modestbranding: 1,
                enablejsapi: 1, origin: '\(origin)'
              },
              events: {
                onReady: function () {
                  ready = true;
                  // The wishes may have arrived before the player did — the API
                  // is a network fetch and Swift does not wait for it.
                  wMute(wantMute);
                  if (wantPlay) { p.playVideo(); }
                },
                onError: function (e) {
                  window.webkit.messageHandlers.written.postMessage('error:' + e.data);
                },
                onStateChange: function (e) {
                  // Loop, as a reel does. A card that plays once and then shows
                  // a still frame looks broken rather than finished.
                  if (e.data === YT.PlayerState.ENDED) { p.seekTo(0); p.playVideo(); }
                }
              }
            });
          }

          function wPlay()  { wantPlay = true;  if (ready) { p.playVideo(); } }
          function wPause() { wantPlay = false; if (ready) { p.pauseVideo(); } }
          function wMute(on) {
            wantMute = on;
            if (!ready) { return; }
            if (on) { p.mute(); } else { p.unMute(); p.setVolume(100); }
          }
        </script>
        </body>
        </html>
        """
    }
}
