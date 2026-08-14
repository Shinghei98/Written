# Calendars become places, affinities and events

**Status: specification, nothing built.** Written against one real library —
324 calendar rows on the owner's account — so every example below is a row that
exists rather than one that would be convenient.

## The four families, and why a place is not one thing

The owner's rule: **a place is an affinity, unless it is a travel.** One event
therefore produces up to two claims, and they are different in kind.

| Family | Kind | Example | What it claims |
|---|---|---|---|
| `travel:*` | `event` | `travel:cancun` | somebody went there |
| `affinity:culture:*` | `affinity` | `affinity:culture:mexico` | somebody is drawn to the culture |
| `base:*` | `place` | `base:hong_kong` | somebody lives there, or did |
| `event:*` / `activity:*` | `event` / `activity` | `event:coachella`, `activity:wine_tasting` | what they went to, or did |

**The affinity is what connects; the travel term is what reads.** `travel:cancun`
is a thing a sentence can be about and belongs on somebody's own page.
`affinity:culture:mexico` is the row that carries `broader` edges onward to
cuisine, music and film — so cross-cultural confidence flows through the graph
rather than through a rule somebody has to remember.

**The template already exists, authored for one country.** `0146` minted
`place:italy`, `affinity:culture:italy`, `concept:italian_music`,
`concept:italian_cinema` and `concept:italian_cuisine`. Korea, Japan and Mexico
are the same five rows with different names. Nothing new is being invented here;
it is being generalised.

### The line that must not be crossed

`0146` also minted `identity:italian_ancestry`, `identity:italian_nationality`
and `identity:italian_native_language`, all with `status = 'blocked'`. That was
deliberate and it governs this whole design.

**Travel to Korea supports *drawn to Korean culture*. It never supports *is
Korean*.** Ancestry and nationality are protected characteristics, and the
existing rows say so. The same applies to the word chosen for repetition:
**`base:` or `residence:`, never `hometown:`** — where somebody *is* is a fact a
dating product legitimately needs; where somebody is *from* is an origin claim,
and the vocabulary is what the next person builds on.

## One trip is an affinity; repetition is a base

The owner's second rule, and it makes the arithmetic simple: **no bar to tune
for affinities.** A single booked flight or ticket is sufficient, because
booking is the act — it cost money and a Saturday, which is the whole reason
calendars were added as a source.

Repetition means something *categorically* different rather than merely
stronger. Proposed test, to be argued rather than assumed:

    base:X requires >= 3 distinct trips to X, spanning >= 6 months

Two traps sit under that, both real on this library.

### A flight names an airport, not a destination

Measured, on the owner's calendar:

    Flight to Hong Kong (CX 883)     2022-11-20
    Flight to Los Angeles (AA 453)   2022-11-19
    Flight to Los Angeles (CX 880)   2023-01-13
    Flight to St. Louis (AA 803)     2023-01-14

Los Angeles appears **twice, more than anywhere else** — and CX 880 and CX 883
are the Hong Kong–Los Angeles pair. **Los Angeles is a connection on the
HKG–STL route, not a place this person goes.** Under a naive count it would be
the strongest base signal in the library and it would be wrong.

So a trip is **an itinerary, not a flight**: same-day or overnight consecutive
segments collapse to their furthest point, and only the endpoint counts. Where
segments cannot be joined, a destination reached exactly once and always
adjacent to another flight is a hub, not a base.

### The duplication doubles every count

Apple Calendar and Google Calendar both hold these flights — every one of the
four appears under both sources with different `item_id`s, which is the known
gap `hasGoogleAccountOnDevice()` was meant to prevent. **Any repetition test
must dedupe by title and start before counting**, or three trips read as six
and a hub becomes a base twice as fast.

## What the calendar carries about booking

An earlier draft of this spec said `booked` and `recurring` were not stamped at
all. That was wrong, and wrong in an instructive way: the check looked for
`booked=1` in an `extra` column that stores `{"booked": "1"}`, so it could not
have matched anything. Both flags are stamped and both fire — 57 booked and 51
recurring across 1,356 calendar rows on three accounts.

**What was actually broken is what `booked` meant.** It was stamped whenever the
event carried a URL, and measured against this library that caught the wrong
things in both directions:

| Event | Was | Should be |
|---|---|---|
| `Ticket: Chichén Itzá Premier Tour` | booked | booked |
| `All of Us meeting 03/10` | booked | **not** — the URL is a Zoom link |
| `Flight to Hong Kong (CX 883)` | not booked | **booked** |
| `Flight to Los Angeles (CX 880)` | not booked | **booked** |

A conference call was a purchase and every flight was a typed reminder — and the
flights are the strongest travel evidence a calendar holds.

**Three states, not two**, because *somebody else put this in my diary* and *I
paid for this* are different facts and only the second is a preference:

    typed    no organizer, no url — the person wrote it themselves
    invited  an organizer exists — somebody else's meeting
    booked   a ticket, a flight, a reservation

`invited` comes from the organizer's *existence*, which is a fact rather than a
reading. A colleague's recurring Zoom says something about a working week and
nothing about what somebody chose to spend a Saturday on.

**A flight is booked whether or not anything wrote a URL back.** Apple parses
airline mail into `Flight to Los Angeles (CX 880)` and leaves the organizer as
`Unknown Organizer` with no url. The carrier code is what makes it a booking:
`Flight to Los Angeles` is a note, `Flight to Los Angeles (CX 880)` is a
boarding pass. The space inside the parentheses is load-bearing, since
`[A-Z0-9]{2,3}` is greedy — the same trap `_FLIGHT_TITLE_RE` already records.

**Outlook still cannot stamp `booked`.** Its `$select` asks for neither
`organizer` nor `webLink`, so its 45 rows carry `recurring` and nothing else.
Adding `organizer` is possible under `Calendars.Read` and remains a decision
rather than a consequence.

## Recognition: read, derive, discard

Same pattern as `title_works`, and for the same clause-free reason — calendar
titles carry no III.E.4 obligation, but they *are* other people's names and
locations, which is why the stored payload is at most four keys and a test
asserts no fragment of a title, address, organiser or email domain survives.

`written_ontology.calendar_semantics` is already an allowlist: `_FLIGHT_TITLE_RE`
matches the canonical flight title and nothing else, so **68 of 101 events are
`excluded_unknown`**. Recognition means extending the catalogue, not loosening
the rule. Four recognisers, in the order they should be built:

1. **Flight → place.** Already half-built. `Flight to Los Angeles (CX 880)`
   parses today; the missing half is mapping the destination to a place concept
   and collapsing segments into an itinerary.
2. **Ticketed tour or attraction → place + activity.**
   `Ticket: Chichén Itzá Premier Tour with Cenote Xuná` is in this library and
   is the strongest single row in it: a named site, prefixed `Ticket:`, on a
   date. Catalogue of world sites, matched whole.
3. **Named event → `event:*`.** Coachella, Lollapalooza, a named venue. A closed
   list, and no fuzzy matching: `exact_terms_only` is the resolver's standing
   rule and applies here for the same reason.
4. **Activity type → `activity:*`.** Wine tasting, spa, climbing. This is the
   only recogniser matching a *common noun* rather than a proper one, so it is
   the one that will attach something to somebody wrongly. Build it last, and
   require `booked=1` for it.

Every recogniser emits **concept keys**, never phrases, and the projection guard
should bound them by pattern the way `title_works` is bounded to
`^work:[a-z0-9_]{1,80}$` — so a title cannot be filed as a place even by a
rewritten client.

## What is deliberately excluded

- **Medical events.** The four most frequent titles on this library are a
  surgery, an outpatient appointment and two clinic visits. They are health
  data, they are not affinities, and no recogniser may touch them. The
  allowlist's default of `excluded_unknown` already does this — do not add a
  recogniser broad enough to catch them.
- **Public holidays.** `PublicHolidays` already strips these from what is drawn,
  and 49 of 77 surviving events on a real device were holidays. A holiday is not
  a trip and a festival in a holiday calendar is not attendance.
- **Anything unrecognised.** An event is excluded unless positively recognised.
  That is the design, not a gap.

## Open questions, for the owner

1. **Does a hub ever become a term?** Los Angeles twice, both as connections.
   The itinerary rule drops it — but somebody who genuinely flies to LA twice
   looks identical. The rule can be right in general and wrong for a person.
2. **How long does an affinity last?** A trip to Italy in 2019 and no other
   Italian signal — is that still an affinity in 2026? Nothing in the scorer
   expires an affinity today.
3. **Does a base expire?** `base:st_louis` while studying and `base:hong_kong`
   before it are both true, at different times. A base with no end date will be
   wrong about somebody the year they move.
