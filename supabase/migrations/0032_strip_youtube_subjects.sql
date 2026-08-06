-- Remove YouTube subjects from every discovery card already written.
--
-- **This is a policy obligation, not a tidy-up.** YouTube API Services
-- Developer Policies III.E.3.b: an API Client "must not display or allow access
-- to Authorized Data to anyone other than the authorizing user or agents
-- expressly approved by that user". A subscription list is Authorized Data, and
-- `discovery_cards` is the one table in this schema readable by every
-- authenticated user — so a channel name written into `interests` is shown to
-- strangers by construction.
--
-- `DistillViewModel.publishDiscoveryCard` stopped emitting them in the same
-- commit as this file. That fixes the next card and not one already stored:
-- a card is rewritten only when its owner distils again, which for somebody who
-- has stopped using the app is never. The rows have to be swept.
--
-- Deleting is right here, where the schema's usual answer is to keep. Nothing
-- downstream reads `interests` for history — `DiscoveryFeed` renders whatever
-- the card holds now — and the whole objection is that the value exists at all.
-- The user loses nothing they can see: the same channels are still in
-- `distilled_records`, still theirs, still on their own dashboard.
--
-- Matched on `source` rather than on the subject text, because the subject is a
-- channel name and channel names are arbitrary. `source` is written by the app
-- and is the only field here with a fixed vocabulary.

update public.discovery_cards
set    interests = coalesce(
           (
               select jsonb_agg(entry)
               from   jsonb_array_elements(interests) as entry
               where  entry ->> 'source' is distinct from 'youtube'
           ),
           '[]'::jsonb
       )
where  interests @> '[{"source": "youtube"}]'::jsonb;

-- `coalesce` is load-bearing: `jsonb_agg` over an empty set returns NULL, not
-- an empty array, so a card whose interests were *entirely* YouTube would
-- violate the `not null` constraint on the column rather than becoming `[]`.
-- That is exactly the card most likely to exist — somebody who connected
-- YouTube and nothing else.
--
-- The `where` clause keeps this to the rows that need it, so the statement can
-- be re-run and is a no-op the second time.
