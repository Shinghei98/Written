-- 0431 — an unknown origin is no objection.
--
-- **0429's chains never formed.** The chain rule broke whenever a leg's
-- origin was unknown — and every origin was unknown, because flight
-- titles name only the destination ("Flight to Hong Kong (CX 883)")
-- while the origin sits in the location field ("洛杉磯 LAX"), which the
-- ontology has no Chinese-script or IATA labels to match. So each Los
-- Angeles layover kept its own journey and its own visited city.
--
-- Two corrections, both rules:
--   * **An absence is not a refusal** (the standing extraction rule):
--     a chain breaks on a *known* origin that mismatches the previous
--     destination, or on the 36-hour gap — never on an origin nobody
--     could read. Two flights hours apart on one calendar are one
--     itinerary; the known-mismatch case still separates genuinely
--     unrelated same-window trips.
--   * **The location evidence is asked for the origin** when the title
--     yields only the destination — filed by 0428, and effective the
--     day the place vocabulary gains the script and code aliases
--     (recorded in NEXT-STEPS); structure now, vocabulary when earned.
--
-- Same wipe-and-rebuild as 0429: derived rows only, evidence and
-- classifications untouched, snapshots rebuilt, recompute enqueued.

begin;

create or replace function semantic_private.build_travel_journeys_deterministic()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  published_version uuid;
  itinerary record;
  place_one record;
  place_two record;
  n_places integer;
  chain record;
  leg record;
  built integer := 0;
  connections integer := 0;
  held_multi integer := 0;
  no_place integer := 0;
  duplicate_reads integer := 0;
  journey_id uuid;
  candidate_action text;
  leg_index integer;
  chain_size integer;
begin
  select id into published_version from ontology.versions
   where status = 'published';

  -- Pass 1: one typed segment per unlinked eligible itinerary, exactly
  -- the 0423 place matching (accent-folded, place-kind labels only).
  for itinerary in
    select distinct on (c.user_id,
                        coalesce(o.content_lineage_hmac, o.record_fingerprint))
           c.id as classification_id, c.observation_id, c.user_id,
           coalesce(o.content_lineage_hmac, o.record_fingerprint)
             as record_fingerprint,
           o.occurred_at,
           extensions.unaccent(lower(convert_from(e.encrypted_text, 'utf8')))
             as text
      from semantic_private.calendar_event_classifications c
      join semantic_private.observations o
        on o.id = c.observation_id and o.user_id = c.user_id
       and o.lifecycle_state = 'active'
      join semantic_private.source_text_evidence e
        on e.observation_id = c.observation_id and e.user_id = c.user_id
       and e.refresh_status = 'current' and e.deleted_at is null
       and e.encryption_key_version = 'ris_lab_plaintext_v1'
     where c.disposition = 'eligible_private_semantics'
       and c.event_class = 'travel_itinerary'
       and not exists (
         select 1 from semantic_private.travel_segments s
          where s.calendar_classification_id = c.id and s.user_id = c.user_id)
       and not exists (
         select 1 from semantic_private.travel_segments s2
          where s2.user_id = c.user_id
            and s2.segment_lineage_hmac
                = coalesce(o.content_lineage_hmac, o.record_fingerprint))
     order by c.user_id,
              coalesce(o.content_lineage_hmac, o.record_fingerprint),
              c.id
  loop
    select count(distinct concept_id) into n_places from (
      select l.concept_id
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.concept_id = l.concept_id
         and r.ontology_version_id = published_version
         and r.status = 'active' and r.concept_kind = 'place'
       where l.ontology_version_id = published_version and l.status = 'active'
         and (length(l.normalized_label) >= 4
              or l.normalized_label ~ '[^\x00-\x7F]')
         and position(extensions.unaccent(l.normalized_label)
               in itinerary.text) > 0) p;

    if n_places = 0 then
      no_place := no_place + 1;
      continue;
    elsif n_places > 2 then
      held_multi := held_multi + 1;
      continue;
    end if;

    select p.concept_id into place_one from (
      select l.concept_id,
             position(extensions.unaccent(l.normalized_label)
               in itinerary.text) as pos
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.concept_id = l.concept_id
         and r.ontology_version_id = published_version
         and r.status = 'active' and r.concept_kind = 'place'
       where l.ontology_version_id = published_version and l.status = 'active'
         and (length(l.normalized_label) >= 4
              or l.normalized_label ~ '[^\x00-\x7F]')
         and position(extensions.unaccent(l.normalized_label)
               in itinerary.text) > 0) p
     group by p.concept_id order by min(p.pos) desc limit 1;

    select p.concept_id into place_two from (
      select l.concept_id,
             position(extensions.unaccent(l.normalized_label)
               in itinerary.text) as pos
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.concept_id = l.concept_id
         and r.ontology_version_id = published_version
         and r.status = 'active' and r.concept_kind = 'place'
       where l.ontology_version_id = published_version and l.status = 'active'
         and (length(l.normalized_label) >= 4
              or l.normalized_label ~ '[^\x00-\x7F]')
         and position(extensions.unaccent(l.normalized_label)
               in itinerary.text) > 0
         and l.concept_id <> place_one.concept_id) p
     group by p.concept_id order by min(p.pos) limit 1;

    -- The title only names the destination for most flights; ask the
    -- location evidence for the origin (0428) before giving up.
    if place_two.concept_id is null then
      select p.concept_id into place_two from (
        select l.concept_id,
               position(extensions.unaccent(l.normalized_label)
                 in extensions.unaccent(lower(
                      convert_from(sl.encrypted_text, 'utf8')))) as pos
          from semantic_private.source_location_evidence sl,
               ontology.concept_labels l
          join ontology.concept_revisions r
            on r.concept_id = l.concept_id
           and r.ontology_version_id = published_version
           and r.status = 'active' and r.concept_kind = 'place'
         where sl.observation_id = itinerary.observation_id
           and sl.user_id = itinerary.user_id
           and sl.refresh_status = 'current' and sl.deleted_at is null
           and sl.encryption_key_version = 'ris_lab_plaintext_v1'
           and l.ontology_version_id = published_version
           and l.status = 'active'
           and (length(l.normalized_label) >= 4
                or l.normalized_label ~ '[^\x00-\x7F]')
           and l.concept_id <> place_one.concept_id
           and position(extensions.unaccent(l.normalized_label)
                 in extensions.unaccent(lower(
                      convert_from(sl.encrypted_text, 'utf8')))) > 0) p
       group by p.concept_id order by min(p.pos) limit 1;
    end if;

    -- The same flight read through two calendar sources is one leg:
    -- same user, same destination, same start. The second read is
    -- refused here, or it chains onto its twin and forges a
    -- "connection" that ends at the terminal.
    if exists (
      select 1 from semantic_private.travel_segments s
      join semantic_private.observations o2
        on o2.id = s.source_observation_id and o2.user_id = s.user_id
     where s.user_id = itinerary.user_id
       and s.destination_place_concept_id = place_one.concept_id
       and s.segment_state <> 'cancelled'
       and o2.occurred_at = itinerary.occurred_at) then
      duplicate_reads := duplicate_reads + 1;
      continue;
    end if;

    insert into semantic_private.travel_segments
      (user_id, calendar_classification_id, source_observation_id,
       ontology_version_id, segment_lineage_hmac,
       origin_place_concept_id, destination_place_concept_id, segment_state)
    values (itinerary.user_id, itinerary.classification_id,
            itinerary.observation_id, published_version,
            itinerary.record_fingerprint,
            place_two.concept_id, place_one.concept_id, 'past_scheduled');
  end loop;

  -- Pass 2: chain the unlinked segments. Gaps-and-islands: a leg opens
  -- a new chain unless it departs from the previous leg's destination
  -- within 36 hours of the previous departure.
  for chain in
    with legs as (
      select s.id as segment_id, s.user_id,
             s.origin_place_concept_id as origin,
             s.destination_place_concept_id as dest,
             s.segment_lineage_hmac as fp,
             o.occurred_at, o.action_type
        from semantic_private.travel_segments s
        join semantic_private.observations o
          on o.id = s.source_observation_id and o.user_id = s.user_id
       where s.ontology_version_id = published_version
         and s.segment_state <> 'cancelled'
         and not exists (
           select 1 from semantic_private.travel_journey_segments js
            where js.segment_id = s.id and js.user_id = s.user_id)
    ),
    marked as (
      select legs.*,
             case when lag(dest) over w is null
                    or occurred_at - lag(occurred_at) over w
                       > interval '36 hours'
                    or (origin is not null
                        and lag(dest) over w is distinct from origin)
                  then 1 else 0 end as brk
        from legs
        window w as (partition by user_id
                     order by occurred_at, segment_id)
    ),
    numbered as (
      select marked.*,
             sum(brk) over (partition by user_id
                            order by occurred_at, segment_id) as chain_no
        from marked
    )
    select user_id, chain_no,
           array_agg(segment_id order by occurred_at, segment_id)
             as segment_ids,
           array_agg(dest order by occurred_at, segment_id) as dests,
           array_agg(action_type order by occurred_at, segment_id)
             as actions,
           array_agg(fp order by occurred_at, segment_id) as fps
      from numbered
     group by user_id, chain_no
  loop
    chain_size := array_length(chain.segment_ids, 1);

    insert into semantic_private.travel_journeys
      (user_id, ontology_version_id, journey_lineage_hmac,
       journey_state, terminal_place_concept_id)
    values (chain.user_id, published_version,
            chain.fps[chain_size], 'past_scheduled',
            chain.dests[chain_size])
    returning id into journey_id;

    for leg_index in 1 .. chain_size loop
      insert into semantic_private.travel_journey_segments
        (journey_id, user_id, ontology_version_id, segment_id,
         segment_role, segment_order)
      values (journey_id, chain.user_id, published_version,
              chain.segment_ids[leg_index],
              case when chain_size = 1 then 'one_way'
                   when leg_index = chain_size then 'terminal'
                   else 'connection' end,
              leg_index);
      if chain_size > 1 and leg_index < chain_size then
        connections := connections + 1;
      end if;
    end loop;

    candidate_action := case chain.actions[chain_size]
                          when 'booked' then 'booked' else 'scheduled' end;
    insert into semantic_private.scheduled_travel_candidates
      (user_id, travel_journey_id, ontology_version_id,
       destination_place_concept_id, action_semantics,
       strength, mapping_agreement, evidence_quality)
    values (chain.user_id, journey_id, published_version,
            chain.dests[chain_size], candidate_action, 1.0, 1.0, 1.0);
    built := built + 1;
  end loop;

  return jsonb_build_object('journeys_built', built,
                            'connection_legs', connections,
                            'held_multi_leg', held_multi,
                            'duplicate_reads', duplicate_reads,
                            'no_known_place', no_place);
end;
$function$;


-- The wipe: 0429's rows were built by the broken chain rule.
delete from semantic_private.memories_snapshot_items
 where scheduled_travel_candidate_id is not null
    or item_kind = 'visited_city';
delete from semantic_private.scheduled_travel_candidates;
delete from semantic_private.travel_journey_segments;
delete from semantic_private.travel_journeys;
delete from semantic_private.travel_segments;

do $$
declare u record; receipt jsonb;
begin
  select semantic_private.build_travel_journeys_deterministic() into receipt;
  raise notice '0431: %', receipt;

  for u in select distinct user_id from (
    select user_id from semantic_private.scheduled_travel_candidates
    union select user_id from semantic_private.booked_activity_candidates) x
  loop
    select semantic_private.build_memories_snapshot(u.user_id) into receipt;
    raise notice '0431: %', receipt;
  end loop;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0431: chains form past unknown origins; layovers leave the cities');
end;
$$;

commit;
