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
    /// Everything the page says — its console, its errors, the player's state.
    ///
    /// Five attempts at this were reasoned from a single number and all five
    /// were wrong. The page can simply tell us what happened instead.
    var onLog: (String) -> Void = { _ in }

    /// What the page claims to be — and deliberately **not** YouTube.
    ///
    /// The log settled what five rounds of inference could not: `api: loaded`,
    /// `player: ready`, then `error: 152`. The script arrives and the player
    /// builds; only playback is refused. So this was never about loading or
    /// referrers, and the one thing left that was strange is that the page
    /// claimed to *be* youtube.com. Nothing on the real web does that — an embed
    /// sits on somebody else's site, and a page insisting it is YouTube itself
    /// is a case YouTube has no reason to allow.
    ///
    /// The project's own Supabase host, which exists and answers over HTTPS, so
    /// the origin is an ordinary third-party site rather than an invention or an
    /// impersonation.
    private static let origin = AppConfig.supabaseURL.absoluteString

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
        // Attachable from Safari → Develop → iPhone.
        if #available(iOS 16.4, *) { webView.isInspectable = true }
#endif
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.loaded != videoID {
            coordinator.loaded = videoID
            guard let url = URL(string: Self.origin + "/player/" + videoID) else { return }
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onUnavailable: onUnavailable, onLog: onLog)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "written")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loaded: String?
        var playing = false
        var muted = true
        private let onUnavailable: (Int) -> Void
        private let onLog: (String) -> Void

        init(onUnavailable: @escaping (Int) -> Void, onLog: @escaping (String) -> Void) {
            self.onUnavailable = onUnavailable
            self.onLog = onLog
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String else { return }
            onLog(body)
            guard body.hasPrefix("error:") else { return }
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
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          // Everything the page has to say, forwarded to the app. Cheaper than
          // attaching a debugger, and it works on any device without a Mac.
          function tell(text) {
            if (window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.written) {
              window.webkit.messageHandlers.written.postMessage(String(text).slice(0, 200));
            }
          }
          window.onerror = function (m, s, l) { tell('js: ' + m + ' @' + l); };
          ['log', 'warn', 'error'].forEach(function (level) {
            var was = console[level];
            console[level] = function () {
              tell(level + ': ' + Array.prototype.join.call(arguments, ' '));
              was.apply(console, arguments);
            };
          });
          // Whether the API arrived at all is the first fork: no script means a
          // load problem, a script and a refusal means an embed problem.
          setTimeout(function () {
            tell(window.YT ? 'api: loaded' : 'api: MISSING after 5s');
          }, 5000);
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
                  tell('player: ready');
                  // The wishes may have arrived before the player did — the API
                  // is a network fetch and Swift does not wait for it.
                  wMute(wantMute);
                  if (wantPlay) { p.playVideo(); }
                },
                onError: function (e) { tell('error:' + e.data); },
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
