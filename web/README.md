# The Written site

One static page. No build step, no dependencies, no framework — `index.html`,
`styles.css`, `app.js` and `assets/`. Open it with any static server:

    cd web && python3 -m http.server 8787      # then http://localhost:8787

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

## What still needs a person

- **A domain.** `written.app` is *not ours* — it is a live, unrelated
  decentralised e-book store with its own App Store listing. Everything else
  queues behind buying one, because the homepage URL, the policy URL and the
  Search Console verification all have to sit on it.
- **Search Console verification** of that domain, using the same Google account
  that owns the Cloud project.
- **Hosting.** Any static host serves this unchanged — Cloudflare Pages,
  Netlify, Vercel, GitHub Pages.
- **A real contact address.** `index.html` still says `hello@example.com`.
- **A privacy policy at its own URL.** It is a section with a `#privacy` anchor
  today, which is enough to read and probably not enough for the verification
  form; `/privacy` as its own page is the safer answer.
- **`SignInView` points at `written.app`'s privacy policy** and will need
  repointing once the domain exists.

## Review flags

Query parameters, in the spirit of the app's `-route` / `-stage` launch flags —
drive the state from the URL rather than editing the source to look at it.

| Flag | Does |
|---|---|
| `?p=0.6` | Freezes the write-on at a fraction of its length |
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

- **The write-on is driven frame by frame from JavaScript, never by a CSS
  transition.** The path lives inside `<defs>`, and an element that is not
  rendered does not run transitions — declared as one, the offset stays parked
  and the mark never appears at all. The app's own logo animation drives the
  same path from `requestAnimationFrame` for the same reason.
- **The hidden states are applied by script; the stylesheet's default is
  visible.** Written the other way round, a page whose JavaScript fails is a
  page of invisible prose, and a banner whose scroll handler never runs is white
  type on parchment. Both now degrade to plain rather than to absent.

## The assets

Generated from the app's own files, so the site and the phone cannot drift:

| File | From |
|---|---|
| `assets/w-logo.png` | `Written/Resources/Logo/written_logo.png`, cropped to the mark and turned into black-with-alpha so CSS can paint it white or ink |
| the `#ink` path in `index.html` | `Written/Resources/Logo/written-logo-animation.html` |
| `assets/fonts/Quicksand-*` | `Written/Resources/Fonts/Quicksand-Regular.ttf` (OFL, licence included) |
| `assets/hero-*.jpg/webp` | Manet, *Monet Painting on His Studio Boat*, 1874 — public domain |

The mark is the artwork revealed through a stroke travelling its own centreline,
not the centreline stroked directly: stroking it overshoots the letterform badly
(measured, IoU 0.49 against the real glyph) and loses the nib.
