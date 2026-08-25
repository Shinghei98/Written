-- 0378 — YouTube's own topics register, so aggregation has a target.
--
-- **The owner's rule extended to subjects, 2026-08-25: "we need them
-- minted, same as the MCU idea, so that it can be aggregated across
-- entries."** Identity mints; weight measures; the cutoff hides noise.
--
-- What the data showed before writing this: YouTube's `topicDetails`
-- taxonomy in this corpus is **thirty coarse labels** — statistics or
-- biomedicine granularity does not exist in it (finest is "Knowledge"),
-- so fine subjects must come from the corpus's `field` family, which the
-- extractor has emitted zero times (booked as a corpus rule). What CAN
-- register today are the provider's own labels that resolve to nothing:
-- five benign topics stood unminted, every occurrence dropped on the
-- floor with no target to accumulate into.
--
-- **This is a read, and the projection of a closed provider taxonomy is
-- authorship** — the same act as 0066 (Apple's genres) and III.E.4's own
-- remedy ("only offer metrics available via the API"). The topic-to-hub
-- map below is authored curation of YouTube's fixed vocabulary, not a
-- per-term fix; a future topic outside the map simply stays unminted
-- until authored.
--
-- **The refused topics stay refused.** Health, Politics, Religion,
-- Society (and Military) never mint whatever the provider says — the
-- protected-characteristic rule, and the probe below asserts none became
-- resolvable, the same assertion every import migration carries.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  minted          integer := 0;
  refused_topic   text;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- The authored projection of the provider's closed taxonomy: only
  -- topics observed in payloads, not already resolvable, and not refused.
  create temporary table _topics on commit drop as
  with observed as (
    select distinct regexp_replace(
             jsonb_array_elements_text(o.normalized_payload->'topics'),
             '^.*/', '') as raw
    from semantic_private.observations o
    where o.source_code = 'youtube' and o.normalized_payload ? 'topics'
  ),
  named as (
    select raw,
           initcap(replace(regexp_replace(raw, '_\(.*\)$', ''), '_', ' ')) as label,
           lower(replace(regexp_replace(raw, '_\(.*\)$', ''), '_', ' ')) as normalized
    from observed
  ),
  mapped as (
    select n.*, m.hub_key,
           'subject:' || replace(n.normalized, ' ', '_') as concept_key
    from named n
    join (values
      ('entertainment',    'hub:film_video'),
      ('hobby',            'hub:games_play'),
      ('performing arts',  'hub:arts_live'),
      ('physical fitness', 'hub:sports_movement'),
      ('lifestyle',        'hub:daily_rhythms')
    ) as m(normalized, hub_key) on m.normalized = n.normalized
  )
  select * from mapped m
   where not exists (
     select 1 from ontology.concept_labels l
      join ontology.concepts c on c.id = l.concept_id
      where l.ontology_version_id = old_version_id and l.status = 'active'
        and l.normalized_label = m.normalized and c.retired_at is null)
     and not exists (select 1 from ontology.concepts c2
                      where c2.concept_key = m.concept_key);

  if not exists (select 1 from _topics) then
    raise notice '0378: every mapped topic already resolves; nothing to mint';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'YouTube''s own unresolved benign topics register as subjects.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  insert into ontology.concepts (id, concept_key)
  select extensions.gen_random_uuid(), t.concept_key from _topics t
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, t.label, 'topic', null,
         'ordinary', 'review_required', 'active',
         jsonb_build_object('origin', '0378_provider_topic',
                            'provider', 'youtube', 'raw', t.raw)
    from _topics t join ontology.concepts c on c.concept_key = t.concept_key
  on conflict (ontology_version_id, concept_id) do nothing;
  get diagnostics minted = row_count;

  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, c.id, t.label, t.normalized, 'en',
         'preferred', 'provider', 1.0, 'active',
         jsonb_build_object('provider', 'youtube', 'raw', t.raw)
    from _topics t join ontology.concepts c on c.concept_key = t.concept_key
  on conflict do nothing;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, c.id, 'broader', h.id, 1.0, 'curated',
         jsonb_build_object('source', '0378_provider_topic'), 'active'
    from _topics t
    join ontology.concepts c on c.concept_key = t.concept_key
    join ontology.concepts h on h.concept_key = t.hub_key
  on conflict do nothing;

  if minted = 0 then
    raise exception '0378: topics stood unresolved and none minted';
  end if;

  -- The refused topics did not become resolvable, whatever the provider says.
  select string_agg(probe.term, ', ') into refused_topic
    from (values ('health'), ('politics'), ('religion'), ('military'), ('society')) as probe(term)
   where exists (
     select 1 from ontology.concept_labels l
      where l.ontology_version_id = new_version_id and l.status = 'active'
        and l.normalized_label = probe.term);
  if refused_topic is not null then
    raise exception '0378: a refused topic became resolvable: %', refused_topic;
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || minted || ' provider topic(s) registered');
  raise notice '0378: % published — % subject(s) minted from the provider''s own labels',
    next_version, minted;
end;
$$;

commit;
