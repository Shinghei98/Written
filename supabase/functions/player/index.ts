// Serves the page a shared video plays inside.
//
// Why a server has to be involved at all: YouTube's player refuses to run in a
// document with no origin, and a document built inside the app has none. Four
// attempts were made to get around that and all four failed —
//
//   loadHTMLString with a base URL          -> error 152
//   the same, plus an `origin` player var   -> 152 again
//   loading youtube.com/embed top-level     -> 153, the referrer complaint
//   loadSimulatedRequest with a real URL    -> 152 again
//
// — because none of them gave the page an origin; they described one. A base URL
// resolves relative links, a player parameter is a claim, and a simulated
// request still never touched a network. This function is the difference: the
// page is fetched over HTTPS from a host that exists, so its origin and the
// `Referer` its iframe sends are both real and neither has to be argued for.
//
// It holds no secrets and needs no session. It takes a video id and returns
// markup — nothing here can read or write anything.
//
// Deployed with:
//   SUPABASE_ACCESS_TOKEN=<pat> npx supabase@latest functions deploy player \
//       --project-ref fwnezkbesjoazlpaflbq --no-verify-jwt
//
// `--no-verify-jwt` is deliberate and worth being clear about. A `WKWebView`
// navigating to a URL cannot attach an Authorization header, so a page meant to
// be *loaded* rather than fetched cannot be behind JWT verification. What that
// exposes is an HTML wrapper around a public YouTube embed, which is already
// public — unlike `delete-account`, which keeps `verify_jwt` on because it acts
// on an account.

const ALLOWED = /^[A-Za-z0-9_-]{11}$/;

Deno.serve((request: Request) => {
  const url = new URL(request.url);
  const videoID = url.searchParams.get("v") ?? "";

  // The id goes straight into a script literal below, so it is checked against
  // YouTube's own shape rather than trusted. Eleven characters of base64url and
  // nothing else — the app validates the same way before storing, and this
  // repeats it because a function that is only safe when its caller behaves is
  // not safe.
  if (!ALLOWED.test(videoID)) {
    return new Response("bad video id", { status: 400 });
  }

  const html = `<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
  html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
  #player { position: absolute; inset: 0; width: 100%; height: 100%; }
</style>
</head>
<body>
<div id="player"></div>
<script src="https://www.youtube.com/iframe_api"></script>
<script>
  var p, ready = false, wantPlay = false, wantMute = true;

  function send(text) {
    if (window.webkit && window.webkit.messageHandlers &&
        window.webkit.messageHandlers.written) {
      window.webkit.messageHandlers.written.postMessage(text);
    }
  }

  function onYouTubeIframeAPIReady() {
    p = new YT.Player('player', {
      videoId: '${videoID}',
      playerVars: {
        playsinline: 1, rel: 0, controls: 0, modestbranding: 1, enablejsapi: 1,
        origin: window.location.origin
      },
      events: {
        onReady: function () {
          ready = true;
          // The wishes may arrive before the player does: the API is a network
          // fetch and the app does not wait for it.
          wMute(wantMute);
          if (wantPlay) { p.playVideo(); }
          send('ready');
        },
        onError: function (e) { send('error:' + e.data); },
        onStateChange: function (e) {
          // Loop, as a reel does. A card that plays once and then shows a still
          // frame looks broken rather than finished.
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
</html>`;

  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      // Cached: the page is the same for a given video, and re-fetching it as a
      // card scrolls back into view would be a round trip for nothing.
      "cache-control": "public, max-age=3600",
    },
  });
});
