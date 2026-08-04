# The Written site

One static page. No build step, no dependencies, no framework — `index.html`,
`styles.css`, `app.js` and `assets/`. Open it with any static server:

    cd web && python3 -m http.server 8787      # then /en-us/, not /

`_redirects` is Cloudflare's, so a plain static server does not honour it and
the root is a 404 locally. That is expected; open `/en-us/` directly.

## Why it exists

Two jobs, and the second is the one with a deadline.

1. It is the front door — the painting, the mark, and an account of what
   distillation is.
2. **It is the homepage Google's OAuth verification requires.** `youtube.readonly`
   is a *sensitive* scope, and publishing the consent screen needs a homepage and
   a privacy policy on a domain we own and have verified in Search Console.
   Until that exists the app's refresh tokens expire every 7 days and every
   tester re-authorises YouTube weekly.

That is why the page carries the Limited Use disclosure, the scope, the 30-day
retention rule and the revocation link. They are not filler: a reviewer reads
this page.

## Shape

    wrangler.jsonc                at the REPO root, not in here — so it is not
                                  itself one of the files served
    web/
      _redirects                  /  ->  /en-us/, and the three short paths
      404.html                    served by not_found_handling
      styles.css  app.js          served from the root, so every page shares them
      assets/                     referenced absolutely as /assets/…
      en-us/index.html            the page
      en-us/privacy/              the document Google's reviewer reads
      en-us/terms/  en-us/cookies/

`/en-us/` is a promise rather than a fact — nothing is translated. Dropping it
is deleting four lines of `_redirects` and moving the directory up.

Asset paths inside `styles.css` stay **relative** and must: the stylesheet sits
at the root, so `assets/…` resolves from there whatever page loads it. Only the
HTML needed absolute paths.

## What still needs a person

Ordered. The first two block Google's verification and nothing else does.

- **Register `written-stl.com`** at dash.cloudflare.com and answer the ICANN
  verification email.
- **Verify it in Search Console as a Domain property** — the DNS one, not URL
  prefix — signed in as a Google account that is a **Project Owner** of the
  Cloud project holding the YouTube credentials. Wrong account is the common
  rejection and it is silent.
- **Deploy**: Workers & Pages → Connect to Git → `Shinghei98/Written`. This is
  the **Workers** flow, not the older Pages one, so there is no "output
  directory" field — the settings are a **build command (leave it empty)** and a
  **deploy command (`npx wrangler deploy`, the default)**. What points it at the
  site is `wrangler.jsonc` at the repo root, which serves `./web` as static
  assets with no Worker script.
- **A `www` → apex Redirect Rule** in the Cloudflare dashboard. It cannot live
  in `_redirects`, which matches paths and not hosts.
- **Email routing** for `hello@written-stl.com`, which every page now prints.
- **Read the terms and the privacy policy before they go up.** They are written
  from what the app actually does, but they are legal documents. Two known
  open questions: whether a postal address is required where you operate, and
  whether a legal entity should be named rather than "Written".
- **Spotify.** The beta build syncs Spotify rows and the privacy policy does not
  mention it, because `CLAUDE.md` has it slated for removal before the App Store
  build. Those two facts cannot both stay true once the policy is public —
  either the code goes before the site does, or the policy has to say so.

## Review flags

Query parameters, in the spirit of the app's `-route` / `-stage` launch flags —
drive the state from the URL rather than editing the source to look at it.

| Flag | Does |
|---|---|
| `?intro=0` | Opens straight onto the page, no opening |
| `?grown=1` | Draws the vine and the prose already revealed |
| `?flat=1` | Caps the painting at 640px so a whole-page capture fits |

Headless Chrome is what these are for, and it has two traps that cost a
measurement each:

- **It will not compose a fixed banner against a programmatic scroll.** Every
  capture taken after a fragment jump came back as blank parchment with the
  painting stranded at the bottom. Capture the whole document in one tall
  viewport with `?flat=1&grown=1` instead of scrolling to a section.
- **Its viewport has a 500px minimum width.** Ask for 390 and it lays out at
  500 and crops the image to 390 — which reads exactly like the page
  overflowing. 500 is the narrowest width it can actually tell you about.

## Two things that look like style and are not

- **The opening is the app's own frames, not a reconstruction of them.** A
  reconstruction was built first — the centreline path from
  `Resources/Logo/written-logo-animation.html`, revealing the real artwork
  through a travelling stroke mask — and it broke the mark into detached
  pieces. The path is not a skeleton of the glyph: no uniform stroke width fits
  it better than **IoU 0.60**, and even at the reference's own width 66 it never
  covers ~5,800 of the glyph's pixels. It exists to paint a fat stroke of flat
  colour, which is exactly what the reference HTML does — its embedded image is
  a solid brand-green fill, so masking it simply paints the stroke. Used as a
  window onto calligraphy it uncovers the wrong ink at the wrong moment.
  `assets/intro.webp` is the shipped GIF's 49 frames rebuilt with **loop count
  1**, because an opener that restarts under the reader is worse than none.
- **The hidden states are applied by script; the stylesheet's default is
  visible.** Written the other way round, a page whose JavaScript fails is a
  page of invisible prose, and a banner whose scroll handler never runs is white
  type on parchment. Both now degrade to plain rather than to absent.

## The assets

Generated from the app's own files, so the site and the phone cannot drift:

| File | From |
|---|---|
| `assets/w-logo.png` | `Written/Resources/Logo/written_logo.png`, cropped to the mark and turned into black-with-alpha so CSS can paint it white or ink |
| `assets/intro.webp` | `Written/Resources/Logo/written_logo_slogan_animation.gif` — the same 49 frames, rebuilt with loop count 1 |
| `assets/intro.gif` | the same file unchanged, as the fallback |
| `assets/intro-still.png` | its last frame, for `prefers-reduced-motion` |
| `assets/fonts/Quicksand-*` | `Written/Resources/Fonts/Quicksand-Regular.ttf` (OFL, licence included) |
| `assets/hero-*.jpg/webp` | Manet, *Monet Painting on His Studio Boat*, 1874 — public domain |

`w-logo.png` is the still mark, and the only one of these the page paints
itself — the banner and the footer use it as a CSS mask so the same file can be
white over the painting and ink below it.
