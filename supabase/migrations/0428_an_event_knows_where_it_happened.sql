-- 0428 — an event knows where it happened.
--
-- **The owner's directive (2026-08-27): every booked event contributes
-- the city it happened in, in parallel with flight tickets** — the
-- Chichén Itzá tour happens in Cancún, and Cancún joins the visited
-- cities beside the flight-derived ones.
--
-- The city lives in the calendar event's *location* field, which the
-- RIS filing (0309) never filed — titles only. Two decisions here:
--
--   * **Location text gets its own table**, `source_location_evidence`,
--     mirroring `source_text_evidence`'s shape — NOT a second row in
--     the same table, because every existing reader (the classifier,
--     the mention grounding, the journey builder) joins evidence by
--     observation and assumes one text; a second row would silently
--     double their inputs. A new table starts with zero readers.
--   * **The backfill matches by title and refuses ambiguity** — the
--     `ris_link_observations` rule: without KMS a vault row rejoins its
--     legacy record by content, and a location filed onto the wrong
--     event is worse than no location. One distinct non-empty location
--     per (user, title) or nothing is filed.
--
-- Then the place: `event_place_concept_id` on the booked candidates,
-- matched from the location text against place-kind labels with the
-- accent fold (0423's matcher). The ontology's kind vocabulary is the
-- disambiguator — in "… Cancún, Quintana Roo, Mexico" only Cancún is
-- kind `place` (Mexico is a culture, Chichén Itzá a work), so the
-- match needs no address heuristics. Most occurrences wins; ties go to
-- the earliest position; zero matches stay null and mint nothing.

begin;

create table semantic_private.source_location_evidence (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  observation_id uuid not null,
  encrypted_text bytea,
  encryption_key_version text not null,
  retention_class text not null,
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null,
  refresh_status text not null default 'current',
  deleted_at timestamptz,
  unique (observation_id),
  foreign key (observation_id, user_id)
    references semantic_private.observations (id, user_id)
);

alter table semantic_private.source_location_evidence
  enable row level security;
grant select on semantic_private.source_location_evidence
  to semantic_worker;

-- Backfill from the legacy record the titles themselves were filed
-- from: same user, same title text, calendar events only, one distinct
-- non-empty location or the pairing is refused.
insert into semantic_private.source_location_evidence
  (user_id, observation_id, encrypted_text, encryption_key_version,
   retention_class, expires_at)
select e.user_id, e.observation_id,
       convert_to(l.detail, 'utf8'), 'ris_lab_plaintext_v1',
       e.retention_class, e.expires_at
  from semantic_private.source_text_evidence e
  join semantic_private.observations o
    on o.id = e.observation_id and o.user_id = e.user_id
   and o.lifecycle_state = 'active'
   and semantic_private.is_private_calendar_source(o.source_code)
  join lateral (
    select d.detail
      from public.summary_distilled_records d
     where d.user_id = e.user_id and d.data_type = 'event'
       and d.name = convert_from(e.encrypted_text, 'utf8')
       and coalesce(d.detail, '') <> ''
     group by d.detail
  ) l on true
 where e.refresh_status = 'current' and e.deleted_at is null
   and e.encryption_key_version = 'ris_lab_plaintext_v1'
   and not exists (
     select 1 from semantic_private.source_location_evidence sl
      where sl.observation_id = e.observation_id)
   and (select count(distinct d2.detail)
          from public.summary_distilled_records d2
         where d2.user_id = e.user_id and d2.data_type = 'event'
           and d2.name = convert_from(e.encrypted_text, 'utf8')
           and coalesce(d2.detail, '') <> '') = 1;

alter table semantic_private.booked_activity_candidates
  add column event_place_concept_id uuid;

-- The place of each eligible booked event, from its location text.
with located as (
  select b.id as candidate_id,
         extensions.unaccent(lower(convert_from(sl.encrypted_text, 'utf8')))
           as loc_text
    from semantic_private.booked_activity_candidates b
    join semantic_private.source_location_evidence sl
      on sl.observation_id = b.source_observation_id
     and sl.user_id = b.user_id
     and sl.refresh_status = 'current' and sl.deleted_at is null
     and sl.encryption_key_version = 'ris_lab_plaintext_v1'
),
placed as (
  select l.candidate_id, p.concept_id
    from located l
    join lateral (
      select cl.concept_id,
             count(*) as hits,
             min(position(extensions.unaccent(cl.normalized_label)
                          in l.loc_text)) as first_pos
        from ontology.concept_labels cl
        join ontology.concept_revisions r
          on r.concept_id = cl.concept_id
         and r.ontology_version_id = cl.ontology_version_id
         and r.status = 'active' and r.concept_kind = 'place'
        join ontology.versions v
          on v.id = cl.ontology_version_id and v.status = 'published'
       where cl.status = 'active'
         and (length(cl.normalized_label) >= 4
              or cl.normalized_label ~ '[^\x00-\x7F]')
         and position(extensions.unaccent(cl.normalized_label)
               in l.loc_text) > 0
       group by cl.concept_id
       order by count(*) desc, min(position(
                extensions.unaccent(cl.normalized_label) in l.loc_text))
       limit 1
    ) p on true
)
update semantic_private.booked_activity_candidates b
   set event_place_concept_id = placed.concept_id
  from placed
 where placed.candidate_id = b.id;

do $$
declare filed integer; placed integer;
begin
  select count(*) into filed
    from semantic_private.source_location_evidence;
  select count(*) into placed
    from semantic_private.booked_activity_candidates
   where event_place_concept_id is not null;
  raise notice '0428: % location texts filed, % booked events placed',
    filed, placed;
end;
$$;

commit;
