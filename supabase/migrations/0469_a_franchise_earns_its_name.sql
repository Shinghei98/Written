-- 0469 — a franchise earns its name.
--
-- **The owner's question (2026-09-06): "Is the existence of work vs
-- franchise the origin of a lot of confusion?"** Measured at 0.41.32, yes,
-- though not the distinction itself — the way it was minted:
--
--   * 1,065 active works; 706 of them 0377 franchise mints; 693 active works
--     carrying no `work_type` at all. On the page, in the reader's artist
--     test and in 0441's container exemption a franchise and a song are
--     the same kind, because storage erased the grammar's distinction.
--   * `creator part_of_franchise X` edges: 326. `work part_of_franchise X`
--     edges: 60. The registry's own description of the predicate reads
--     *"a work or event belongs to a persistent IP universe"*; 0374's kind
--     agreement admitted `creator` subjects by one hand-written clause,
--     0377 dropped the floor to stated-once, and a person "belonging to" a
--     TV show, a tour, a hotel or a university became that thing's proof
--     of containerhood.
--   * Of the labels the model ever tagged `franchise`, the same strings
--     were also filed as person 650 times, work 593, album 296, music_work
--     240, group 228, organization 54, event 43. The tag is the role the
--     thing plays in a sentence ("X is part of Y"), not a claim about Y.
--   * 0398's container reconciliation restated person→franchise as
--     `member_of_group` wherever its verdict was `group`, which made Utada
--     Hikaru a member of the group "Science Fiction Tour" (her tour) and
--     Jo Yuri a member of "Chord chart 'Episode 25'" (a video's format
--     word). 105 inferred `group` rows have no sighting at all, and the
--     reader prefers a group over a person when composing "artist -
--     title", hence "Science Fiction Tour - Distance" on a card.
--
-- Four rules, all identity, none arithmetic:
--
-- 1. **An inferred group nobody has seen is not a group.** A dictionary
--    row of family `group`, origin `inferred`, with zero mention and zero
--    entry support exists only because it was the object of somebody's
--    statement. It is retyped `unknown` — the honest family — so nothing
--    that keys on `family = 'group'` (the reader's member-of-group lateral,
--    0398's restatement) can read a stated relation as a band.
--
-- 2. **Every 0377 mint is re-sorted by what was actually seen.** For each
--    active mint the dictionary is read back under its own label:
--      - a *specific* family with direct support — event, tour, album,
--        music_work, music_recording, anime, game, book, organization,
--        activity, sport, person, group, place, culture — outranks the
--        generic `franchise` tag whatever the counts, because the specific
--        claim is the informative one (a thing seen as a game is a game;
--        a franchise that is also an event is an event series);
--      - the generic `work` family competes with franchise on support;
--      - franchise itself stands on a direct franchise sighting or on a
--        `part_of_franchise` statement whose subject is a work-family term
--        (Iron Man → MCU, the owner's 2026-08-25 example, keeps minting at
--        n=1 — a *work* said so);
--      - a mint with none of those — only persons and calendar rows ever
--        pointed at it — is a relation object, not a term, and is
--        unpromoted back to the dictionary.
--    Survivors keep kind `work` with an explicit `work_type` (franchise,
--    recording, album, anime, game, book, creative_work); events and tours
--    retype to kind `event` (scope occurrence / series); organizations to
--    `organization`; activities and sports to their kinds; persons, groups,
--    places and cultures leave through the fold pattern (0379/0468 shape:
--    labels deprecated, edges rejected, the revision deprecated with a
--    reason, the dictionary unwound, the assertions retired — nothing
--    deleted) since each has its own minting route and none of them is a
--    work. **`event` is not on `list_assertions`' kind allowlist, so a
--    music show or a tour leaves Memories until somebody decides it
--    belongs there** — the allowlist's rule, applied rather than bypassed.
--    Concept keys keep their historical `work:` prefix: a key is identity,
--    not vocabulary, and renaming one rewrites every reference to it.
--
-- 3. **A person is never the subject of `part_of_franchise`.** Every
--    active or candidate edge with a creator subject is rejected, and a
--    guard trigger refuses the next one — the registry's description,
--    finally enforced. The dictionary rows behind them stay (append-only,
--    "a record of what was said at a moment"); a later rule may re-route
--    them (a performer at an event, an artist on a tour) once such
--    predicates exist. Edges whose object has stopped being a work are
--    rejected with them: `part_of_franchise` into an event is incongruent.
--
-- 4. **The standing gate.** `franchise_identity_is_supported(label)` sits
--    beside 0377's `franchise_label_is_recording_family`; every
--    franchise-mint pass must consult both before minting a
--    franchise-family object. A label the model has only ever used as the
--    object of a person's statement answers false.
--
-- 5. **An event is never inferred (owner, 2026-09-06).** "The only events
--    that should appear on Memories are events users have attended
--    themselves, sourced from calendar. A tour video about Taylor Swift
--    watched on YouTube should only contribute to the Taylor Swift person
--    term." Attendance already has its own surface — the calendar lane's
--    snapshot pane (0424: trips, live shows, restaurants, each its own
--    card) and the `travel:` terms — and it never asserts on an event
--    concept. So every active revision of kind `event` carries
--    `inference_policy = 'explicit_only'`: the scorer still scores it and
--    still lets it conduct to the people who performed (a tour video's
--    weight reaches the artist through her own mention on the same title
--    and through `performed_by`), but the state it writes is `candidate`,
--    never `eligible` — so the matching surface, which takes eligible
--    assertions of any kind, never sees a show or a tour a person merely
--    watched. A trigger keeps the policy true for every event revision
--    written later (`mint_proposed_parents` writes `inferable` for every
--    family, and would otherwise mint an inferable event the day a
--    proposal corroborates one); `list_assertions`' kind allowlist,
--    which does not name `event`, stays as the page's half of the rule.
--    The inferred event assertions standing today demote to `candidate`
--    in the same change, per the rule that a change which only withholds
--    arrives too late.
--
-- What this does not do: it does not fix labels cut from decorated video
-- titles ("Chord chart 'Episode 25'" stays a work, now without its false
-- container proof), and it does not touch the reader. Both are separate
-- rules. Scorer re-computation is enqueued at the end as every version
-- publish must.
begin;

-- ---------------------------------------------------------------------
-- 4. The standing gate, defined first so the migration's own reading and
--    every later pass share one definition.
-- ---------------------------------------------------------------------
create or replace function semantic_private.franchise_identity_is_supported(p_label text)
returns boolean
language sql
stable
set search_path = ''
as $function$
  -- True when the dictionary holds a reason to believe this name is a
  -- franchise in its own right: the model tagged the name itself
  -- `franchise` in at least one sighting, or a work-family term stated
  -- `part_of_franchise` to it. A name known only as the object of a
  -- person's or a calendar row's statement answers false — that is a
  -- relation, not an identity. Consulted beside
  -- `franchise_label_is_recording_family` by every franchise-mint pass.
  -- The dictionary's own normalization keeps punctuation ("chord chart
  -- 'episode 25'"); the label table's strips it. A name is looked up
  -- under both, or an apostrophe hides a sighting.
  with norm as (
    select array[lower(btrim(p_label)),
                 btrim(regexp_replace(lower(p_label), '[^a-z0-9À-￿]+', ' ', 'g'))] as n)
  select exists (
           select 1 from semantic_private.presumed_terms t, norm
            where t.normalized_label = any(norm.n) and t.family = 'franchise'
              and coalesce(t.mention_support, 0) + coalesce(t.entry_support, 0) > 0)
      or exists (
           select 1
             from semantic_private.presumed_term_relations rel
             join semantic_private.presumed_terms o on o.id = rel.object_term_id
             join semantic_private.presumed_terms s on s.id = rel.subject_term_id
             , norm
            where o.normalized_label = any(norm.n)
              and s.normalized_label <> all(norm.n)
              and rel.predicate = 'part_of_franchise'
              and s.family in ('work', 'music_work', 'music_recording', 'album',
                               'anime', 'game', 'book', 'franchise'));
$function$;

-- ---------------------------------------------------------------------
-- 1. The dictionary: an inferred group nobody has seen is not a group.
--    Not version-scoped, so it runs whether or not a version follows. The
--    identity index is (normalized_label, family); a label that already
--    has an `unknown` row keeps its group row and is counted below.
-- ---------------------------------------------------------------------
update semantic_private.presumed_terms t
   set family = 'unknown'
 where t.family = 'group' and t.origin = 'inferred'
   and coalesce(t.mention_support, 0) = 0 and coalesce(t.entry_support, 0) = 0
   and not exists (
     select 1 from semantic_private.presumed_terms u
      where u.normalized_label = t.normalized_label and u.family = 'unknown');

-- ---------------------------------------------------------------------
-- 5. An event is never inferred: the policy, kept true by construction.
--    Created before the version copy so the copy itself passes through
--    it — an event revision arrives at the new version already
--    `explicit_only`, whatever it carried before.
-- ---------------------------------------------------------------------
create or replace function ontology.event_is_never_inferred()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.concept_kind = 'event'
     and new.inference_policy not in ('explicit_only', 'prohibited') then
    new.inference_policy := 'explicit_only';
  end if;
  return new;
end;
$function$;

drop trigger if exists concept_revisions_event_never_inferred on ontology.concept_revisions;
create trigger concept_revisions_event_never_inferred
  before insert or update on ontology.concept_revisions
  for each row execute function ontology.event_is_never_inferred();

-- ---------------------------------------------------------------------
-- 2 + 3 + 5. The re-sort, the edge rejection and the event policy, at a
--            new version.
-- ---------------------------------------------------------------------
do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  n_franchise     integer := 0;
  n_retyped       integer := 0;
  n_unpromoted    integer := 0;
  n_person_edges  integer := 0;
  n_object_edges  integer := 0;
  n_unsighted     integer := 0;
  n_event_policy  integer := 0;
  n_event_demoted integer := 0;
  probe_event     uuid;
  probe_work      uuid;
  probe_policy    text;
  probe_read      text;
  bucket          record;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise notice '0469: no published version; nothing to re-sort';
    return;
  end if;

  -- The mints, read at the published version, with every spelling the
  -- dictionary holds for each: the rows promoted to it, plus the name
  -- under the dictionary's normalization (punctuation kept) and the label
  -- table's (punctuation stripped). An apostrophe must not hide a sighting.
  create temporary table _mints on commit drop as
  select r.concept_id, c.concept_key, r.preferred_label,
         array(select distinct nl from (
                 select t.normalized_label as nl from semantic_private.presumed_terms t
                  where t.promoted_concept_id = r.concept_id
                 union select lower(btrim(r.preferred_label))
                 union select btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g'))
               ) x) as names
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id and c.retired_at is null
   where r.ontology_version_id = old_version_id and r.status = 'active'
     and r.concept_kind = 'work'
     and r.metadata->>'origin' = '0377_franchise_mint';

  -- What the dictionary saw under each mint's name.
  create temporary table _plan on commit drop as
  with terms as (
    select m.concept_id, t.family, t.source_lanes,
           coalesce(t.mention_support, 0) + coalesce(t.entry_support, 0) as support
      from _mints m
      join semantic_private.presumed_terms t on t.normalized_label = any(m.names)),
  franchise_support as (
    select m.concept_id,
           coalesce((select sum(t.support) from terms t
                      where t.concept_id = m.concept_id and t.family = 'franchise'), 0)
           + (select count(*)
                from semantic_private.presumed_term_relations rel
                join semantic_private.presumed_terms o on o.id = rel.object_term_id
                join semantic_private.presumed_terms s on s.id = rel.subject_term_id
               where o.normalized_label = any(m.names) and s.normalized_label <> all(m.names)
                 and rel.predicate = 'part_of_franchise'
                 and s.family in ('work', 'music_work', 'music_recording', 'album',
                                  'anime', 'game', 'book', 'franchise')) as support
      from _mints m),
  specific as (
    -- the most-supported specific family; ties break toward the more
    -- particular claim
    select distinct on (concept_id) concept_id, family, support
      from terms
     where support > 0
       and family in ('event', 'tour', 'album', 'music_work', 'music_recording',
                      'anime', 'game', 'book', 'organization', 'activity', 'sport',
                      'person', 'group', 'place', 'culture')
     order by concept_id, support desc,
              array_position(array['event', 'tour', 'album', 'music_recording',
                                   'music_work', 'anime', 'game', 'book',
                                   'organization', 'activity', 'sport', 'group',
                                   'person', 'place', 'culture'], family)),
  generic_work as (
    select concept_id, sum(support) as support, bool_or(source_lanes && array['apple_music', 'music_library', 'spotify']) as music
      from terms where family = 'work' and support > 0 group by concept_id),
  decided as (
    select m.concept_id, m.concept_key, m.preferred_label,
           case when sp.family is not null then sp.family
                when coalesce(gw.support, 0) > fs.support then 'work'
                when fs.support > 0 then 'franchise'
                else null end as family,
           coalesce(gw.music, false) as music,
           fs.support as franchise_support,
           coalesce(sp.support, gw.support, 0) as family_support
      from _mints m
      join franchise_support fs on fs.concept_id = m.concept_id
      left join specific sp on sp.concept_id = m.concept_id
      left join generic_work gw on gw.concept_id = m.concept_id)
  select d.*,
         case when d.family is null then 'unpromote'
              when d.family in ('person', 'group', 'place', 'culture') then 'unpromote'
              when d.family = 'franchise' then 'franchise'
              else 'retype' end as verdict,
         case d.family
           when 'franchise'       then 'work'
           when 'work'            then 'work'
           when 'music_work'      then 'work'
           when 'music_recording' then 'work'
           when 'album'           then 'work'
           when 'anime'           then 'work'
           when 'game'            then 'work'
           when 'book'            then 'work'
           when 'event'           then 'event'
           when 'tour'            then 'event'
           when 'organization'    then 'organization'
           when 'activity'        then 'activity'
           when 'sport'           then 'sport'
           else null end as new_kind,
         case d.family
           when 'franchise'       then 'franchise'
           when 'work'            then case when d.music then 'recording' else 'creative_work' end
           when 'music_work'      then 'recording'
           when 'music_recording' then 'recording'
           when 'album'           then 'album'
           when 'anime'           then 'anime'
           when 'game'            then 'game'
           when 'book'            then 'book'
           else null end as work_type,
         case d.family when 'event' then 'occurrence' when 'tour' then 'series' else null end as event_scope,
         case when d.family is null then 'relation_object_only'
              when d.family in ('person', 'group') then 'creator_route'
              when d.family in ('place', 'culture') then 'not_a_work'
              else null end as reason
    from decided d;

  for bucket in
    select verdict, coalesce(family, '(none)') as family, count(*) as n from _plan
     group by 1, 2 order by 1, 3 desc
  loop
    raise notice '0469: % as % — %', bucket.verdict, bucket.family, bucket.n;
  end loop;

  select count(*) into n_person_edges
    from ontology.concept_edges e
    join ontology.concept_revisions s
      on s.concept_id = e.subject_concept_id
     and s.ontology_version_id = old_version_id and s.status = 'active'
   where e.ontology_version_id = old_version_id and e.status in ('active', 'candidate')
     and e.predicate_key = 'part_of_franchise' and s.concept_kind = 'creator';

  if not exists (select 1 from _plan) and n_person_edges = 0 then
    raise notice '0469: no franchise mint and no person-subject edge stands; no version published';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'A franchise earns its name: 0377 mints re-sorted by what was seen; '
          || 'persons are never franchise subjects.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- 2a. Franchises that earned it: the subtype made explicit.
  update ontology.concept_revisions r
     set metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('work_type', 'franchise',
                                          'work_type_source', '0469_dictionary_reading',
                                          'franchise_support', p.franchise_support)
    from _plan p
   where r.ontology_version_id = new_version_id and r.status = 'active'
     and r.concept_id = p.concept_id and p.verdict = 'franchise';
  get diagnostics n_franchise = row_count;

  -- 2b. Retypes: the kind and the subtype the dictionary actually saw.
  update ontology.concept_revisions r
     set concept_kind = p.new_kind,
         -- a subtype of work has no meaning on an event or an organization
         metadata = (case when p.new_kind = 'work' then coalesce(r.metadata, '{}'::jsonb)
                          else coalesce(r.metadata, '{}'::jsonb) - 'work_type' - 'work_type_source' end)
                    || jsonb_build_object('family', p.family,
                                          'resorted_by', '0469',
                                          'resorted_from', 'franchise',
                                          'family_support', p.family_support)
                    || case when p.work_type is not null
                            then jsonb_build_object('work_type', p.work_type,
                                                    'work_type_source', '0469_dictionary_reading')
                            else '{}'::jsonb end
                    || case when p.event_scope is not null
                            then jsonb_build_object('event_scope', p.event_scope)
                            else '{}'::jsonb end
    from _plan p
   where r.ontology_version_id = new_version_id and r.status = 'active'
     and r.concept_id = p.concept_id and p.verdict = 'retype';
  get diagnostics n_retyped = row_count;

  -- 5a. Every active event at the new version is explicit_only — the
  -- trigger already made the copied rows so; this names the rule for the
  -- retyped ones and counts what changed hands.
  update ontology.concept_revisions r
     set inference_policy = 'explicit_only',
         metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('inference_policy_set_by', '0469',
                                          'inference_policy_reason', 'an event is never inferred')
   where r.ontology_version_id = new_version_id and r.status = 'active'
     and r.concept_kind = 'event'
     and (r.inference_policy not in ('explicit_only', 'prohibited')
          or r.metadata->>'inference_policy_set_by' is null);
  get diagnostics n_event_policy = row_count;

  -- 5b. The standing inferred assertions on events demote now rather
  -- than at the next run: eligible is what the matching surface reads.
  update semantic_private.user_assertions a
     set machine_state = 'candidate', updated_at = now()
    from ontology.concept_revisions r
   where r.concept_id = a.concept_id
     and r.ontology_version_id = new_version_id and r.status = 'active'
     and r.concept_kind = 'event'
     and a.assertion_origin = 'inferred'
     and a.machine_state = 'eligible';
  get diagnostics n_event_demoted = row_count;

  -- 5c. The policy trigger, seen answering both ways on real rows at the
  -- draft version: an event written `inferable` reads back
  -- `explicit_only`; a work written `inferable` reads back `inferable`
  -- and is put back as it was.
  select concept_id into probe_event from ontology.concept_revisions
   where ontology_version_id = new_version_id and status = 'active' and concept_kind = 'event' limit 1;
  select concept_id, inference_policy into probe_work, probe_policy from ontology.concept_revisions
   where ontology_version_id = new_version_id and status = 'active' and concept_kind = 'work' limit 1;
  if probe_event is null or probe_work is null then
    raise notice '0469: too few concepts to probe the event policy both ways';
  else
    update ontology.concept_revisions set inference_policy = 'inferable'
     where ontology_version_id = new_version_id and concept_id = probe_event;
    select inference_policy into probe_read from ontology.concept_revisions
     where ontology_version_id = new_version_id and concept_id = probe_event;
    if probe_read <> 'explicit_only' then
      raise exception '0469: an event revision accepted inference_policy %', probe_read;
    end if;
    update ontology.concept_revisions set inference_policy = 'inferable'
     where ontology_version_id = new_version_id and concept_id = probe_work;
    select inference_policy into probe_read from ontology.concept_revisions
     where ontology_version_id = new_version_id and concept_id = probe_work;
    if probe_read <> 'inferable' then
      raise exception '0469: a work revision was coerced to %', probe_read;
    end if;
    update ontology.concept_revisions set inference_policy = probe_policy
     where ontology_version_id = new_version_id and concept_id = probe_work;
    raise notice '0469: the event policy answered both ways';
  end if;

  -- 2c. Unpromotions, the fold shape without a destination: labels
  -- deprecated, edges rejected, the revision deprecated with its reason,
  -- the dictionary unwound, the assertions retired. Nothing is deleted.
  update ontology.concept_labels
     set status = 'deprecated'
   where ontology_version_id = new_version_id and status = 'active'
     and concept_id in (select concept_id from _plan where verdict = 'unpromote');

  update ontology.concept_edges e
     set status = 'rejected',
         provenance = coalesce(e.provenance, '{}'::jsonb)
                      || jsonb_build_object('rejected_by', '0469', 'reason', 'end_unpromoted')
   where e.ontology_version_id = new_version_id and e.status in ('active', 'candidate')
     and (e.subject_concept_id in (select concept_id from _plan where verdict = 'unpromote')
          or e.object_concept_id in (select concept_id from _plan where verdict = 'unpromote'));

  update ontology.concept_revisions r
     set status = 'deprecated',
         metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('deprecated_by', '0469', 'reason', p.reason)
                    || case when p.family is not null
                            then jsonb_build_object('family_seen', p.family) else '{}'::jsonb end
    from _plan p
   where r.ontology_version_id = new_version_id and r.status = 'active'
     and r.concept_id = p.concept_id and p.verdict = 'unpromote';
  get diagnostics n_unpromoted = row_count;

  update semantic_private.presumed_terms
     set promoted_concept_id = null, promoted_at = null
   where promoted_concept_id in (select concept_id from _plan where verdict = 'unpromote');

  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where concept_id in (select concept_id from _plan where verdict = 'unpromote')
     and machine_state <> 'inactive';

  -- 3. Persons are never franchise subjects; and a franchise edge whose
  --    object stopped being a work is incongruent.
  update ontology.concept_edges e
     set status = 'rejected',
         provenance = coalesce(e.provenance, '{}'::jsonb)
                      || jsonb_build_object('rejected_by', '0469', 'reason', 'person_subject')
    from ontology.concept_revisions s
   where e.ontology_version_id = new_version_id and e.status in ('active', 'candidate')
     and e.predicate_key = 'part_of_franchise'
     and s.concept_id = e.subject_concept_id
     and s.ontology_version_id = new_version_id and s.status = 'active'
     and s.concept_kind = 'creator';
  get diagnostics n_person_edges = row_count;

  update ontology.concept_edges e
     set status = 'rejected',
         provenance = coalesce(e.provenance, '{}'::jsonb)
                      || jsonb_build_object('rejected_by', '0469', 'reason', 'object_not_a_work')
    from ontology.concept_revisions o
   where e.ontology_version_id = new_version_id and e.status in ('active', 'candidate')
     and e.predicate_key = 'part_of_franchise'
     and o.concept_id = e.object_concept_id
     and o.ontology_version_id = new_version_id and o.status = 'active'
     and o.concept_kind <> 'work';
  get diagnostics n_object_edges = row_count;

  -- The transformation, asserted — what must be true when the input
  -- exists, answering the same on an empty database and on production.
  if exists (
    select 1 from ontology.concept_revisions r
     where r.ontology_version_id = new_version_id and r.status = 'active'
       and r.concept_kind = 'work'
       and r.metadata->>'origin' = '0377_franchise_mint'
       and r.metadata->>'work_type' is null)
  then
    raise exception '0469: a franchise mint still stands as a work with no work_type';
  end if;
  if exists (
    select 1 from ontology.concept_edges e
      join ontology.concept_revisions s
        on s.concept_id = e.subject_concept_id
       and s.ontology_version_id = new_version_id and s.status = 'active'
     where e.ontology_version_id = new_version_id and e.status in ('active', 'candidate')
       and e.predicate_key = 'part_of_franchise' and s.concept_kind = 'creator')
  then
    raise exception '0469: a person still stands as the subject of part_of_franchise';
  end if;
  if exists (
    select 1 from ontology.concept_revisions r join _plan p on p.concept_id = r.concept_id
     where r.ontology_version_id = new_version_id and r.status = 'active'
       and p.verdict = 'unpromote')
  then
    raise exception '0469: an unpromoted mint is still active at the new version';
  end if;

  if exists (
    select 1 from ontology.concept_revisions r
     where r.ontology_version_id = new_version_id and r.status = 'active'
       and r.concept_kind = 'event'
       and r.inference_policy not in ('explicit_only', 'prohibited'))
  then
    raise exception '0469: an event still stands inferable at the new version';
  end if;

  select count(*) into n_unsighted
    from semantic_private.presumed_terms t
   where t.family = 'group' and t.origin = 'inferred'
     and coalesce(t.mention_support, 0) = 0 and coalesce(t.entry_support, 0) = 0;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': franchise mints re-sorted — '
    || n_franchise || ' franchise(s) typed, ' || n_retyped || ' retyped, '
    || n_unpromoted || ' unpromoted; ' || n_person_edges
    || ' person-subject and ' || n_object_edges || ' non-work-object franchise edge(s) rejected; '
    || n_event_policy || ' event(s) explicit_only, ' || n_event_demoted || ' event assertion(s) demoted');
  raise notice '0469: % published — % franchise(s) typed, % retyped, % unpromoted; % person-subject edge(s) and % non-work-object edge(s) rejected; % event(s) explicit_only, % inferred event assertion(s) demoted to candidate; % unsighted inferred group row(s) kept only because an unknown twin exists',
    next_version, n_franchise, n_retyped, n_unpromoted, n_person_edges, n_object_edges, n_event_policy, n_event_demoted, n_unsighted;
end $$;

-- ---------------------------------------------------------------------
-- 3, the durable half: the guard. Created after the rejection above so
-- the copy-forward that preceded it could not trip it, and so no later
-- copy-forward can — nothing it would refuse stands active any more.
-- Judged at the edge's own version; a subject with no active revision
-- there cannot be judged and is permitted, since a guard that refuses
-- what it cannot see would refuse the draft ordering of every migration.
-- ---------------------------------------------------------------------
create or replace function ontology.guard_franchise_subject_is_not_a_person()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  subject_kind text;
begin
  if new.predicate_key <> 'part_of_franchise' or new.status not in ('active', 'candidate') then
    return new;
  end if;
  select r.concept_kind into subject_kind
    from ontology.concept_revisions r
   where r.concept_id = new.subject_concept_id
     and r.ontology_version_id = new.ontology_version_id and r.status = 'active';
  if subject_kind = 'creator' then
    raise exception 'part_of_franchise takes a work or an event as its subject, never a person (%); 0469',
      new.subject_concept_id;
  end if;
  return new;
end;
$function$;

drop trigger if exists concept_edges_guard_franchise_subject on ontology.concept_edges;
create trigger concept_edges_guard_franchise_subject
  before insert or update on ontology.concept_edges
  for each row execute function ontology.guard_franchise_subject_is_not_a_person();

-- The guard is believed only once it has answered both ways over real
-- rows: a creator subject refused, a work subject admitted. Each probe
-- runs in its own block and is rolled back by its own raise, so nothing
-- it inserts survives. On a database with no creator or no work it says
-- so and moves on — the trigger is the rule; the probe is the proof.
do $$
declare
  v_id       uuid;
  a_creator  uuid;
  a_work     uuid;
  another    uuid;
  refused    boolean := false;
  admitted   boolean := false;
begin
  select id into v_id from ontology.versions where status = 'published';
  if v_id is null then
    raise notice '0469: no published version; the guard is unprobed';
    return;
  end if;
  select concept_id into a_creator from ontology.concept_revisions
   where ontology_version_id = v_id and status = 'active' and concept_kind = 'creator' limit 1;
  select concept_id into a_work from ontology.concept_revisions
   where ontology_version_id = v_id and status = 'active' and concept_kind = 'work' limit 1;
  select concept_id into another from ontology.concept_revisions
   where ontology_version_id = v_id and status = 'active' and concept_kind = 'work'
     and concept_id <> a_work limit 1;
  if a_creator is null or a_work is null or another is null then
    raise notice '0469: too few concepts to probe the guard both ways';
    return;
  end if;

  begin
    insert into ontology.concept_edges (
      ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
      confidence, provenance_type, provenance, status)
    values (v_id, a_creator, 'part_of_franchise', a_work, 0.5, 'migration',
            '{"probe": "0469"}'::jsonb, 'candidate');
    raise exception 'probe: admitted';
  exception
    when others then
      refused := sqlerrm like '%never a person%';
  end;

  begin
    insert into ontology.concept_edges (
      ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
      confidence, provenance_type, provenance, status)
    values (v_id, another, 'part_of_franchise', a_work, 0.5, 'migration',
            '{"probe": "0469"}'::jsonb, 'candidate');
    raise exception 'probe: admitted';
  exception
    when others then
      admitted := sqlerrm = 'probe: admitted';
      -- the published-version guard may refuse the write before ours is
      -- reached; that too proves ours did not refuse a work
      if not admitted and sqlerrm not like '%never a person%' then
        admitted := true;
      end if;
  end;

  if not refused then
    raise exception '0469: the guard admitted a person as a franchise subject';
  end if;
  if not admitted then
    raise exception '0469: the guard refused a work as a franchise subject';
  end if;
  raise notice '0469: the guard answered both ways';
end $$;

commit;
