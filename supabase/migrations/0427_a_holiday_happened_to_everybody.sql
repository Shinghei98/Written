-- 0427 — a holiday happened to everybody.
--
-- **The honest labels exposed the honest defect**: ten of the eleven
-- rows on the owner's EVENTS card were Hong Kong public holidays —
-- Mid-Autumn, Chung Yeung, Hungry Ghost, Dragon Boat, three years of
-- them — classified `public_ticketed_event` because the word
-- "festival" sits in the concert pattern. A public holiday is not a
-- fact about the person: they did not choose Christmas.
--
-- The app already holds the ruling and the vocabulary:
-- `Written/Models/PublicHolidays.swift`, whose header records that *no
-- structural signal can do this job* (measured: holiday rows are
-- shape-identical to "Outpatient" and "Marco's arrival") and that
-- token matching is the design — "day after mid-autumn festival"
-- catches by token where an exact-name list never keeps up. This
-- migration mirrors that vocabulary into the authored pattern registry
-- as a `public_holiday` class, excluded, at the sensitive tier
-- (priority 5) — the same trade the app made: a "Christmas dinner"
-- diary row is lost to the token, and losing that costs less than
-- printing three years of statutory holidays as somebody's taste.
-- The action rule alone cannot do it: Timi's FF VII REBIRTH Orchestra
-- concert is genuinely `scheduled`, not `booked`, and is a real event.
--
-- Then the consequences, in the same change (a rule that only
-- withholds arrives too late):
--   * every deterministic verdict is re-asked against the grown
--     registry — a deterministic verdict is a function of the entry —
--     and re-issued at the current revision where it changed;
--   * booked candidates whose classification no longer authorises them
--     are deleted, snapshot items first (derived working rows, not
--     evidence — the observations and classifications both stay);
--   * snapshots rebuild, and the recompute is enqueued, because the
--     scorer read those candidates and its inputs just moved.

begin;

alter table semantic_private.calendar_event_classifications
  drop constraint calendar_classifications_event_class_check;
alter table semantic_private.calendar_event_classifications
  add constraint calendar_classifications_event_class_check
  check (event_class = any (array[
    'travel_itinerary', 'commercial_reservation', 'public_ticketed_event',
    'birthday', 'medical', 'friend_private', 'work_meeting',
    'funeral_memorial', 'other_private', 'public_holiday', 'unknown']));

-- A holiday may never be eligible, by constraint rather than by the
-- pattern rows happening to say so.
alter table semantic_private.calendar_event_classifications
  drop constraint calendar_classifications_sensitive_excluded_check;
alter table semantic_private.calendar_event_classifications
  add constraint calendar_classifications_sensitive_excluded_check
  check (event_class <> all (array[
    'birthday', 'medical', 'friend_private', 'work_meeting',
    'funeral_memorial', 'other_private', 'public_holiday'])
    or disposition = 'excluded_private');

-- The PublicHolidays.swift vocabulary, token for token, apostrophes
-- widened to `.?` because calendars disagree between ' and ’.
insert into semantic_private.calendar_class_patterns
  (pattern, event_class, disposition, priority, pattern_set)
select p.pattern, 'public_holiday', 'excluded_private', 5,
       'calendar-patterns-v1'
  from (values
    ('(lunar new year|chinese new year|spring festival|tomb sweeping|ching ming|qingming|buddha|dragon boat|tuen ng|mid.?autumn|hungry ghost|chung yeung|double ninth|national day of the people|hong kong special administrative region establishment|winter solstice)'),
    ('(christmas|boxing day|new year|good friday|holy saturday|easter|ash wednesday|palm sunday|all saints|all souls|halloween|valentine|st\.? patrick|saint patrick|april fool|mother.?s day|mothering sunday|father.?s day|labou?r day|hanukkah|chanukah|kwanzaa|yom kippur|rosh hashanah|passover|purim|sukkot|eid al|ramadan|diwali|vesak)'),
    ('(independence day|fourth of july|july 4th|thanksgiving|memorial day|veterans day|armistice day|president.?s day|washington.?s birthday|martin luther king|mlk day|columbus day|indigenous peoples|juneteenth|flag day|groundhog day|cinco de mayo|election day|inauguration day|daylight savings?)'),
    ('(bank holiday|remembrance sunday|guy fawkes|bonfire night|節日|节日|假期|公眾假期|公众假期|春節|春节|中秋|端午|清明|重陽|重阳|聖誕|圣诞|元旦)')
  ) as p(pattern)
 where not exists (
   select 1 from semantic_private.calendar_class_patterns cp
    where cp.event_class = 'public_holiday' and cp.pattern = p.pattern);

-- Re-ask every deterministic verdict against the grown registry.
with readable as (
  select c.id as cid,
         lower(convert_from(e.encrypted_text, 'utf8')) as text
    from semantic_private.calendar_event_classifications c
    join ontology.model_versions m
      on m.id = c.classifier_model_id
     and m.model_key = 'written-deterministic-rules'
    join semantic_private.observations o
      on o.id = c.observation_id and o.user_id = c.user_id
     and o.lifecycle_state = 'active'
    join semantic_private.source_text_evidence e
      on e.observation_id = c.observation_id and e.user_id = c.user_id
     and e.refresh_status = 'current' and e.deleted_at is null
     and e.encryption_key_version = 'ris_lab_plaintext_v1'
),
verdicts as (
  select r.cid,
         coalesce(p.event_class, 'unknown') as event_class,
         coalesce(p.disposition, 'review') as disposition
    from readable r
    left join lateral (
      select cp.event_class, cp.disposition
        from semantic_private.calendar_class_patterns cp
       where r.text ~* cp.pattern
       order by cp.priority, cp.id limit 1
    ) p on true
)
update semantic_private.calendar_event_classifications c
   set event_class = v.event_class, disposition = v.disposition,
       input_revision = (select s.revision
                           from semantic_private.user_state_versions s
                          where s.user_id = c.user_id)
  from verdicts v
 where v.cid = c.id
   and (c.event_class, c.disposition)
       is distinct from (v.event_class, v.disposition);

-- The candidates the flipped verdicts no longer authorise.
delete from semantic_private.memories_snapshot_items i
 using semantic_private.booked_activity_candidates b,
       semantic_private.calendar_event_classifications c
 where i.booked_activity_candidate_id = b.id
   and c.id = b.calendar_classification_id and c.user_id = b.user_id
   and (c.disposition <> 'eligible_private_semantics'
        or (b.predicate_key = 'booked_event'
            and c.event_class <> 'public_ticketed_event')
        or (b.predicate_key = 'scheduled_dining'
            and c.event_class <> 'commercial_reservation'));

delete from semantic_private.booked_activity_candidates b
 using semantic_private.calendar_event_classifications c
 where c.id = b.calendar_classification_id and c.user_id = b.user_id
   and (c.disposition <> 'eligible_private_semantics'
        or (b.predicate_key = 'booked_event'
            and c.event_class <> 'public_ticketed_event')
        or (b.predicate_key = 'scheduled_dining'
            and c.event_class <> 'commercial_reservation'));

do $$
declare u record; receipt jsonb; holidays integer;
begin
  select count(*) into holidays
    from semantic_private.calendar_event_classifications
   where event_class = 'public_holiday';
  raise notice '0427: % rows now classified public_holiday', holidays;

  for u in select distinct user_id from (
    select user_id from semantic_private.scheduled_travel_candidates
    union select user_id from semantic_private.booked_activity_candidates) x
  loop
    select semantic_private.build_memories_snapshot(u.user_id) into receipt;
    raise notice '0427: %', receipt;
  end loop;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0427: public holidays leave the booked lane — '
    || holidays || ' reclassified, candidates withdrawn');
end;
$$;

commit;
