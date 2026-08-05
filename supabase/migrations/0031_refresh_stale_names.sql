-- Bring the frozen names on `conversations` and `likes` up to date, once.
--
-- Both tables denormalise a name at the moment something happens — `liker_name`
-- when a like is sent, `user_a_name` / `user_b_name` when the thread is created
-- out of it — and nothing has ever corrected either. A name wrong at that
-- instant stayed wrong: measured here, one conversation read "Marco" against a
-- card saying "Chan Tai Man", and another read "A" and "B" against "Joon" and
-- "Mina".
--
-- **The app no longer reads these for display.** `ChatService.cards(for:)` takes
-- the name from `discovery_cards` alongside the photograph, for the reason that
-- table was already being used for faces: it is the one place a signed-in user
-- may read about another, and a copy elsewhere is a second thing to keep in
-- step. So this migration fixes nothing the app shows — it stops the fallback
-- being a lie for anybody who has no card at that moment, and stops the next
-- person to read these columns directly being misled.
--
-- **It is not a trigger and must not become one.** Keeping these permanently in
-- step would mean writing to every conversation whenever anybody edits their
-- name, which is a fan-out on a table two people share for the sake of a value
-- that is now only a fallback. The card is the answer; this is housekeeping.
--
-- Safe to re-run: it only touches rows that disagree with a card that exists.

update public.conversations c
   set user_a_name = d.display_name
  from public.discovery_cards d
 where d.user_id = c.user_a
   and length(btrim(coalesce(d.display_name, ''))) > 0
   and c.user_a_name is distinct from d.display_name;

update public.conversations c
   set user_b_name = d.display_name
  from public.discovery_cards d
 where d.user_id = c.user_b
   and length(btrim(coalesce(d.display_name, ''))) > 0
   and c.user_b_name is distinct from d.display_name;

-- The likes too. An admirers row shows `liker_name`, and an unanswered like
-- from months ago would otherwise still be listed under a name its sender has
-- since changed — and would copy that name onto the conversation on being
-- accepted, putting back exactly what the two statements above just cleaned up.
update public.likes l
   set liker_name = d.display_name
  from public.discovery_cards d
 where d.user_id = l.liker_id
   and length(btrim(coalesce(d.display_name, ''))) > 0
   and l.liker_name is distinct from d.display_name;

-- Afterwards, this should return nothing:
--
--   select c.id, c.user_a_name, c.user_b_name,
--          (select display_name from public.discovery_cards where user_id = c.user_a),
--          (select display_name from public.discovery_cards where user_id = c.user_b)
--     from public.conversations c
--    where c.user_a_name is distinct from
--          (select display_name from public.discovery_cards where user_id = c.user_a)
--       or c.user_b_name is distinct from
--          (select display_name from public.discovery_cards where user_id = c.user_b);
--
-- Rows *will* come back for anybody with no card — a synthetic account, or
-- somebody who has never distilled — and that is correct: there is nothing to
-- copy, and the stored name is all there is.
