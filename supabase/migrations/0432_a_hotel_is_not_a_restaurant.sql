-- 0432 — a hotel is not a restaurant.
--
-- **Timi's events card said "Restaurant" under "Stay at DoubleTree",
-- "Hotel check-in" and an Enterprise car rental.** 0430 made
-- `restaurant` the structural reading of `commercial_reservation`, but
-- that class was drawn by a pattern ("reservation|hotel|airbnb|
-- check-?in|…") that always covered lodging and transport too — the
-- class is commerce, not dining. Under the owner's five categories,
-- lodging and transport are `other`, and `other` is never drawn.
--
-- The categorizer now runs the authored patterns for every class —
-- a lodging/transport tier at priority 5 sends stays, check-ins and
-- rentals to `other` — and only then falls back by class: a
-- reservation that is not lodging is dining; a ticketed event that
-- matches nothing stays `other`. The place minting is untouched: a
-- hotel still contributes its city to the visited list, because the
-- stay happened somewhere even when the row is not worth a line.
--
-- **And the owner's second correction in the same breath: the Chichén
-- Itzá Premier Tour is not a live show.** "Live shows (including
-- tours)" meant concert tours, and the bare token `\mtour\M` cannot
-- tell a world tour from a sightseeing one — so it stops deciding
-- anything. A concert tour announces itself ("world tour", orchestra,
-- concert, the FF VII row matches twice over without the bare word);
-- a tourist tour carries sightseeing vocabulary (guided, walking,
-- premier, excursion, day trip), which now routes to `other`
-- explicitly, and anything the vocabulary cannot read falls to
-- `other` by default — the safe floor is silence, not a wrong badge.
-- The city minting is untouched: the tour still contributes Cancún.
--
-- Presentation only — the scorer reads candidates, not categories —
-- so no recompute is enqueued.

begin;

alter table semantic_private.booked_event_category_patterns
  drop constraint booked_event_category_patterns_category_check;
alter table semantic_private.booked_event_category_patterns
  add constraint booked_event_category_patterns_category_check
  check (category in ('festival', 'live_show', 'exhibition', 'other'));

insert into semantic_private.booked_event_category_patterns
  (pattern, category, priority)
values
  ('(hotel|hostel|airbnb|motel|resort|\mstay\M|check.?in|check.?out|rent.?a.?car|car rental|rental car|rent-?al reservation|enterprise rent|hertz|avis rent|酒店|旅館|旅馆|ホテル|호텔|租車|租车)',
   'other', 5),
  ('(guided tour|walking tour|day tour|premier tour|city tour|bus tour|boat tour|food tour|tasting|sightseeing|excursion|day trip|cruise|观光|觀光|遊覽|游览|ツアー|투어)',
   'other', 7);

-- The bare word decided nothing and stops pretending to: a concert
-- tour still matches on its own vocabulary.
update semantic_private.booked_event_category_patterns
   set pattern = replace(pattern, '|\mtour\M', '')
 where category = 'live_show' and pattern like '%|\mtour\M%';

create or replace function semantic_private.booked_event_category(
  p_event_class text, p_title text)
returns text
language sql
stable
set search_path to ''
as $function$
  select coalesce(
    (select cp.category
       from semantic_private.booked_event_category_patterns cp
      where p_title ~* cp.pattern
      order by cp.priority, cp.id limit 1),
    case when p_event_class = 'commercial_reservation' then 'restaurant'
         else 'other' end);
$function$;

-- Re-backfill every standing candidate under the corrected reading.
update semantic_private.booked_activity_candidates b
   set display_category = semantic_private.booked_event_category(
         c.event_class,
         coalesce(convert_from(e.encrypted_text, 'utf8'), ''))
  from semantic_private.calendar_event_classifications c
  left join semantic_private.source_text_evidence e
    on e.observation_id = c.observation_id and e.user_id = c.user_id
   and e.refresh_status = 'current' and e.deleted_at is null
   and e.encryption_key_version = 'ris_lab_plaintext_v1'
 where c.id = b.calendar_classification_id and c.user_id = b.user_id;

do $$
declare u record; receipt jsonb;
begin
  for u in select distinct user_id from (
    select user_id from semantic_private.scheduled_travel_candidates
    union select user_id from semantic_private.booked_activity_candidates) x
  loop
    select semantic_private.build_memories_snapshot(u.user_id) into receipt;
    raise notice '0432: %', receipt;
  end loop;
end;
$$;

commit;
