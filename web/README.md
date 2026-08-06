# The Written site

One static page. No build step, no dependencies, no framework — `index.html`,
`styles.css`, `app.js` and `assets/`. Open it with any static server:

    cd web && python3 -m http.server 8787      # then /en-us/, not /

`_redirects` is Cloudflare's, so a plain static server does not honour it and
the root is a 404 locally. That is expected; open `/en-us/` directly.

**Everything in this directory is published, including this file.** That is easy
to disbelieve because the two config files here are *not*: Workers consumes
`_headers` and `_redirects` itself, so both answer 404, which makes it look as
though non-HTML is somehow exempt. It is not. This README was served at
`https://written-stl.com/README.md` for a day — the Google scope
justifications, the demo-video plan, and the paragraph recording that the beta
syncs Spotify while the privacy policy deliberately omits it, on the domain
whose policy Google is being asked to trust. `.assetsignore` excludes it now.
**Anything added here that is notes rather than site goes in that file in the
same commit**, and the check is one line:

    curl -s -o /dev/null -w '%{http_code}\n' https://written-stl.com/README.md   # 404

## Why it exists

Three jobs, and the last two are the ones with deadlines. **This is not a
consumer funnel and should not be edited as though it were** — every page here
is read by a reviewer before it is read by anybody looking for a date.

1. It is the front door — the painting, the mark, and an account of what
   distillation is.
2. **It is the homepage Google's OAuth verification requires.** `youtube.readonly`
   is a *sensitive* scope, and publishing the consent screen needs a homepage and
   a privacy policy on a domain we own and have verified in Search Console.
   Until that exists the app's refresh tokens expire every 7 days and every
   tester re-authorises YouTube weekly.
3. **It is the Support URL App Store Connect requires**, which is a separate
   mandatory field from the privacy policy and cannot be a `mailto:`.
   `/en-us/support/` is it, and it doubles as where Guideline 1.2's "published
   contact information" and the account-deletion instructions live.

That is why the pages carry the Limited Use disclosure, every scope by name, the
30-day retention rule, the revocation link and a stated response time. They are
not filler.

**Every claim on this site has to be a fact about the shipped app**, and the way
that goes wrong is not lying — it is the site staying still while the app moves.
It described a one-sign-in-method app with no Google Calendar and no
notifications for a day after all three had shipped, and it promised a control
for removing a single source that has never existed. So: **adding a source, a
sign-in method or anything that leaves the device means editing
`en-us/privacy/` in the same commit.**

## Shape

    wrangler.jsonc                at the REPO root, not in here — so it is not
                                  itself one of the files served
    web/
      _redirects                  /  ->  /en-us/, and the four short paths
      _headers                    CSP and friends; see below
      404.html                    served by not_found_handling
      styles.css  app.js          served from the root, so every page shares them
      assets/                     referenced absolutely as /assets/…
      en-us/index.html            the page
      en-us/privacy/              the document Google's reviewer reads
      en-us/support/              the document App Review reads
      en-us/terms/  en-us/cookies/

Neither `_redirects` nor `_headers` is served — Workers static assets parses
both and applies them to everything else. Redirects run before headers, so a
path matching a rule in each is redirected and never reaches the header rule.

**`_headers` is what makes the cookies page true rather than merely honest.**
That page says nothing is fetched from anywhere else; the CSP is
`default-src 'self'` with `connect-src 'none'`, so a tag manager pasted in later
does not quietly start working — it fails. `style-src` carries `'unsafe-inline'`
only because a few callouts use a `style="margin:0"` attribute; move those into
`styles.css` and the keyword can go.

`/en-us/` is a promise rather than a fact — nothing is translated. Dropping it
is deleting the `_redirects` lines and moving the directory up — but **not until
after Google's verification**, because the consent screen carries these URLs and
a homepage that has moved is a homepage that does not match.

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
- ~~**A `www` → apex Redirect Rule**~~ — **done 2026-08-05.** It cannot live in
  `_redirects`, which matches paths and not hosts. Two parts, and the first is
  the non-obvious one: an **`A` record, name `www`, `192.0.2.1`, proxied, TTL
  auto**. That address is TEST-NET-1 and routes nowhere — the record exists only
  so Cloudflare accepts traffic for the hostname, and because it is *proxied*
  the Redirect Rule answers at the edge and the address is never contacted.
  **Not a CNAME to the apex**, which is a Worker custom domain and returns Error
  1000. Then Rules → Redirect Rules, matching `Hostname equals
  www.written-stl.com`, type **dynamic**, expression `concat("https://written-stl.com",
  http.request.uri.path)`, 301, preserve query string. Dynamic because a static
  redirect drops the path, and a reviewer following a deep link would land on
  the homepage.
- **Email routing** for `hello@written-stl.com`, which every page now prints.
- **Read the terms and the privacy policy before they go up.** They are written
  from what the app actually does, but they are legal documents. Two known
  open questions: whether a postal address is required where you operate, and
  whether a legal entity should be named rather than "Written".
- **Spotify.** The beta build syncs Spotify rows and the site deliberately does
  not mention it, because it is slated for removal before the App Store build.
  **The code has to go before external TestFlight testers arrive**, not before
  the App Store build — an external tester is covered by this published policy,
  and the policy does not describe a source they can connect. Internal testers
  are the developer's own team and are the window this arrangement has.

## The derived-metrics disclosure — written, NOT yet published

The wording below goes live **with the feature and before acceptance**, not
after it. That ordering is not a preference: Google requires the demo video to
show real end-to-end functionality and says scopes must not be requested for
hypothetical features, so a submission describing something that does not run is
refused on its own terms. The way through is to build it, demonstrate it, keep
**production** gated behind the entitlement, and have the site say Written is
*requesting* approval.

**Publish when both are true:** the ontology layer and the review screen exist
in the build, and an application has actually been filed. It then replaces the
conservative paragraphs on `web/en-us/` and `web/en-us/privacy/` **in the same
commit as the feature**. On acceptance, "is requesting approval to operate" is
changed to the operative form — a two-word edit, and the last one.

> ### How Written uses YouTube information
>
> When you choose Distill YouTube, Written reads the YouTube information you
> authorize, including metadata associated with your subscriptions, liked
> videos, and playlists. Written analyzes the subject matter of those videos and
> channels and may assign additional descriptive tags using Written's own
> content ontology — for example, "long-form science education," "independent
> cinema," or "strategy gaming." These tags are generated independently by
> Written from the YouTube information you authorized. They are not supplied,
> approved, or endorsed by YouTube, and they do not replace or modify YouTube's
> published categories, statistics, or labels. Written first shows the resulting
> analysis privately to you so that you can review, edit, or remove it. Tags you
> choose to retain may be summarized into broader interests and used with
> information you confirm from other sources to improve your Written profile,
> dynamic bio, and conversational suggestions. Written does not use this
> analysis to produce alternative YouTube engagement metrics, evaluate creator
> performance, estimate YouTube's business or revenue, or infer sensitive
> protected characteristics. Written is requesting approval to operate this
> workflow under YouTube's additional derived-metrics policies for Content
> Categorization and Tagging, which permit accepted developers to create
> additive proprietary tags that are clearly distinguished from YouTube-supplied
> data.

**Three corrections against an earlier draft, each worth keeping:**

- **Never say the tags are "not sourced from YouTube."** They are generated from
  authorized YouTube API Data and saying otherwise is inaccurate — which is the
  exact misrepresentation III.E.4.h's disclosure limb exists to prevent. The
  true distinction is *generated independently by Written from YouTube
  information you authorized; not supplied, approved, or endorsed by YouTube*.
- **Never imply the approval already exists.** "Is requesting" until it is not.
- **Disclose the whole downstream chain**, and resist the instinct to describe
  only the tagging step. The amendment is granted for the *submitted* use case,
  so a submission that hides the summarisation into user-level interests would
  buy approval for a narrower product than Written actually is. Google should
  see: `YouTube metadata → Written-generated tags → user review → broader
  interest themes → profile, bio and conversation prompts`.

**And the privacy policy needs its own sentence, separately:** ordinary metadata
— titles, creator names, descriptions — stays on the standard 30-day
delete-or-refresh rules, while accepted derived outputs may be retained up to 36
months **only if** the amendment is granted. That sentence is also the answer to
the open question flagged in `CLAUDE.md` about whether `0016`'s premise survives.

**Every clause is a requirement on the build**, and four are unmet:

- *"do not replace or modify YouTube's published categories"* — the tag sits
  **beneath** YouTube's own category, which is why
  `YouTubeDistiller.channelTopics` fetching `topicDetails` stays even after the
  ontology is switched back on. Additive to a category never retrieved is not
  demonstrable.
- *"generated independently by Written"* — a visible label wherever a tag is
  shown, not a line in a policy. III.E.4.h's disclosure limb, mandatory with or
  without the amendment.
- *"first shows the resulting analysis privately to you"* — the review layer.
  Does not exist.
- *"does not … infer sensitive protected characteristics"* —
  `Ontology.refusedTopics` is the start and covers YouTube's topic vocabulary
  only. A proprietary ontology needs exclusions that hold for tags it *invents*,
  which is the harder half and is not started.

**One judgement left to a person.** Running the ontology over YouTube data in a
build shown to Google, before acceptance, is defensible — the demonstration is
*for* the party whose permission is being sought, and production stays gated —
but it is still the operation the guide tells unapproved clients not to perform.
Decide it deliberately rather than by drifting into it, and keep the gate real:
one server-side entitlement, off by default, so the review build and production
cannot diverge by accident.

## The Google submission, ready to file

**The URLs, character for character.** These must match what the app links
(`SignInView.swift`) and what the consent screen carries. Use the final paths,
never the short redirecting ones — a 301 is legal and a mismatch is a rejection.

| Field | Value |
|---|---|
| Application home page | `https://written-stl.com/en-us/` |
| Privacy policy | `https://written-stl.com/en-us/privacy/` |
| Terms of service | `https://written-stl.com/en-us/terms/` |
| Per-scope disclosure | `https://written-stl.com/en-us/privacy/#google-user-data` |

**Scope justifications.** One per scope, and each has to answer *why nothing
narrower will do* as well as what it is for. Drafts, matching the table on the
privacy page:

- `youtube.readonly` — Written builds a dating profile from what a person
  already follows and keeps. It reads subscriptions, liked videos, playlists and
  playlist contents once, when the user taps Connect, and derives the subjects
  the profile is written from. There is no narrower read scope for this data.
  Titles and channel names are deleted after 30 days by a scheduled job; only
  the derived, non-identifying reading remains.
- `calendar.calendarlist.readonly` — Reads calendar *names* only, and its whole
  purpose is to read less: birthday and public-holiday calendars are identified
  by name and skipped before any event inside them is requested. Asking only for
  the events scope would mean opening calendars we have no business reading.
- `calendar.events.readonly` — Reads the events in the calendars that were not
  skipped. Title, date, location, organiser and booking link are what separate a
  concert somebody paid for from a note to themselves, which is the signal the
  profile is built from. `calendar.readonly` would cover both of these in one
  grant and is deliberately not requested.
- **Only offered where it adds something.** Google Calendar is presented
  alongside Apple Calendar rather than instead of it, and events from both are
  reconciled into one diary before anything is shown, so nothing is counted
  twice.

**The demo video.** Unlisted on YouTube. It must show the app name and branding,
the complete consent screen with these exact scopes, and the functionality that
uses the data.

**The hard part is the client ID**, which the video has to show and
`ASWebAuthenticationSession` gives no address bar for. Two ways, and the second
is safer: run the same grant once in Safari on a Mac where the URL is visible
and film that alongside the device; or film the Google Cloud console's
credentials page showing the client ID immediately before the grant, in one
unbroken take.

Shot list, one recording, no cuts:

1. The app's sign-in screen, name and mark visible, with the three links.
2. The client ID on screen by whichever route above.
3. Tap Connect on Media → the Google consent screen, scopes legible.
4. Grant, return to the app, the branch grows.
5. Memories showing what was derived — the functionality the scope is for.
6. Press and hold an entry, strike it off — this is the in-app control the
   policy describes.
7. Memories → Delete account → Delete everything.

Step 7 is worth filming even though it is not asked for: the audit's questions
about deletion are answered by watching it happen.

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
