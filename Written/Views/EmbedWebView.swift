import SwiftUI
import WebKit

/// A shared video, playing inside a card.
///
/// The first `WKWebView` in this app, and it is deliberately a small one: it
/// shows an embed and nothing else. No navigation, no back and forward, nothing
/// the user could steer somewhere unexpected.
///
/// It builds the player through **YouTube's IFrame API** rather than dropping an
/// `<iframe>` in. A bare iframe cannot be told anything once it exists, and this
/// has to be told two things — play when the card reaches the middle of the
/// screen, stop when it leaves — so the page exposes `wPlay`, `wPause` and
/// `wMute` for `evaluateJavaScript` to call.
struct EmbedWebView: UIViewRepresentable {
    let videoID: String
    /// Whether this card is the one in the middle of the screen.
    var isPlaying: Bool
    /// Muted until the reader asks otherwise. See `page(for:)`.
    var isMuted: Bool
    /// The player refused to play it. Some videos genuinely cannot be embedded —
    /// the uploader's choice — and a card showing YouTube's own error screen
    /// with a numeric code is worse than saying so plainly.
    var onUnavailable: () -> Void = {}

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Otherwise a tap takes the video full screen and out of the feed.
        configuration.allowsInlineMediaPlayback = true
        // Autoplay is allowed *because it is muted*. This was `.all` when the
        // feed had no idea which card was on screen, and lifting it is only safe
        // alongside the muting below — a video that starts talking as it scrolls
        // past is the thing this must never become.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // How the page reports a refusal back. Without it a video the uploader
        // has blocked shows YouTube's grey "unavailable" panel inside the card
        // and the app has no idea anything went wrong.
        configuration.userContentController.add(context.coordinator, name: "written")

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
        let coordinator = context.coordinator

        if coordinator.loaded != videoID {
            coordinator.loaded = videoID
            // `baseURL` matters: YouTube refuses to serve the API to a page with
            // no origin, and an HTML string loaded without one has none.
            webView.loadHTMLString(
                Self.page(for: videoID),
                baseURL: URL(string: "https://www.youtube.com")
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

    /// Registered as a script-message handler, so it has to be released
    /// explicitly — the content controller holds it, and the web view holds the
    /// controller, so without this the pair outlive the card.
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "written")
    }

    /// What has already been asked for, so `updateUIView` — which SwiftUI calls
    /// on any redraw — only acts on what actually changed.
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loaded: String?
        var playing = false
        var muted = true
        let onUnavailable: () -> Void

        init(onUnavailable: @escaping () -> Void) {
            self.onUnavailable = onUnavailable
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String, body.hasPrefix("error") else { return }
            onUnavailable()
        }
    }

    /// The player, and the three functions Swift calls into it.
    ///
    /// `playsinline` keeps it in the card on iPhone; `rel=0` stops the end screen
    /// offering someone else's videos, which in a feed reads as the app handing
    /// the reader off; `controls=0` because the card decides when this plays,
    /// and a scrub bar on something that starts and stops with scrolling invites
    /// a fight over who is in charge.
    ///
    /// It starts **muted**, and that is not a detail. WebKit blocks unmuted
    /// autoplay outright, so an unmuted player would simply not start; and even
    /// where it worked, sound arriving unasked as a feed scrolls is the worst
    /// thing an app like this can do. Tapping the card unmutes it.
    private static func page(for videoID: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, \
        maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: transparent; \
        overflow: hidden; }
          #player { position: absolute; inset: 0; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          var p, ready = false, wantPlay = false, wantMute = true;

          function onYouTubeIframeAPIReady() {
            p = new YT.Player('player', {
              videoId: '\(videoID)',
              // `origin` is the one that matters, and its absence is what made
              // every video come back "unavailable, error 152-4". The player
              // checks who is embedding it, and a page built by
              // `loadHTMLString` has no origin of its own to offer however the
              // base URL is set — so it has to be told, and told the same thing
              // the base URL says.
              playerVars: {
                playsinline: 1, rel: 0, controls: 0, modestbranding: 1,
                enablejsapi: 1, origin: 'https://www.youtube.com'
              },
              events: {
                onReady: function () {
                  ready = true;
                  // The wishes may have arrived before the player did — the API
                  // script is a network fetch and Swift does not wait for it.
                  wMute(wantMute);
                  if (wantPlay) { p.playVideo(); }
                },
                onError: function (e) {
                  // 101 and 150 are "the uploader does not allow embedding",
                  // which is a real answer rather than a fault. Everything else
                  // is reported the same way: the card cannot show this, and
                  // saying so beats a code.
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
