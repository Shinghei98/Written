-- The dynamic profile's three figures become named things, not shapes.
--
-- `0037` put `domains` on the card and the page drew "Music 83%, Sport 17%".
-- That is a category, and a category says less about somebody than the artist
-- names already sitting beside it in `interests` — anyone reading a card with
-- Ado and Fujii Kaze on it can see that this person listens to music. The three
-- figures sit where Instagram puts posts / followers / following, and the whole
-- argument for them is that they are what somebody's attention is *made of*.
-- "Bach 22%" is that. "Music 83%" is a shape.
--
-- **`domains` stays and is still written.** The caption fallback on that page is
-- `Domain.sharedLine` — what two people share when they share no particular
-- artist — so the domains are still needed, just no longer drawn as the triple.
--
-- **Subjects are published, so the publishing test applies.** `discovery_cards`
-- is the one table in this schema every signed-in user may read, and each entry
-- has to be something a sentence can be about *and* something the source's
-- terms allow a stranger to see. `Ontology.subjects` therefore counts Apple
-- Music and nothing else: YouTube channel names are Authorized Data under
-- III.E.3.b, calendar titles are the least publishable thing this app holds,
-- and podcast shows and Health sports are undecided rather than forbidden.
-- Widening this is a decision to take deliberately, in that file and this
-- comment together.
--
-- Written by the device, like `domains`, because the classical rule needs each
-- row's `genres` and `composer` and `Ontology` is where that rule lives in
-- Swift. It agrees with `0038`'s rule in `seed_icebreaker` on purpose: the
-- profile and the icebreaker must not call the same listening by two different
-- names. That pair has to be changed together.

alter table public.discovery_cards
    add column if not exists top_subjects jsonb not null default '[]'::jsonb;

comment on column public.discovery_cards.top_subjects is
    'Ranked named things as [{"subject":"Johann Sebastian Bach","share":0.22}], '
    'computed on the device by Ontology.subjects. Apple Music only — see the '
    'migration header for why each other source is excluded. Shares are over '
    'the music counted, not over everything distilled, and the list is capped '
    'at what the page draws.';
