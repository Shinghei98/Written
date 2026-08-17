-- 0214 — a recording is its ISRC.
--
-- ## The gap this closes
--
-- 1,422 distinct song titles have been the largest single block of unresolved
-- evidence in this database for months, and the reason is that nothing mints a
-- non-game work: `work:apple_*` exists only for `is_game` soundtrack credits. A
-- library of songs therefore resolves to its artists and to nothing else.
--
-- The exact lane measured it precisely once it ran: 2,362 eligible mentions, one
-- resolvable. Not the resolver underperforming — the vocabulary is not there.
--
-- ## Identity is the ISRC, and the title is a label
--
-- `recording:isrc_<isrc>`. An ISRC identifies one concrete recording, issued by
-- the rights holder, and it is what both Apple and Spotify state about the same
-- track — so the same recording reached from either source is one concept
-- rather than two.
--
-- **Minting by title would have merged nine pairs in this batch alone.** 560
-- recordings carry 551 distinct titles: `Intro`, `Home`, and the rest of the
-- names that several unrelated recordings share. A title is a display string
-- and has never been an identity.
--
-- **So no `concept_labels` row is written.** The name lives in
-- `concept_revisions.preferred_label`, which is what a person reads, and the
-- resolver reaches these concepts through the external link rather than by
-- matching a string. Adding 560 titles as active exact aliases would raise the
-- published label set by a fifth overnight and make ambiguity the dominant
-- failure of a resolver that is not yet family-aware — it cannot tell that an
-- `album` mention should not match a recording. Titles become aliases when the
-- resolver can be told which family a mention is looking for, and not before.
--
-- ## What is deliberately not inferred
--
-- No abstract `music_work`, no `recording_of`, no `rerecording_of`, no album
-- identity, no soundtrack or franchise membership, no composer relation. **An
-- ISRC identifies a recording and says nothing about the composition behind
-- it** — a cover, a remaster and the original are three ISRCs and one work, and
-- this migration has no way to tell which is which. Every one of those is a
-- later decision with its own evidence.
--
-- The parent is `hub:music` and nothing finer. A genre parent is available —
-- Apple states `genreNames` on the same row — but a genre is a claim about the
-- recording and the hub is a drawer, and the first batch should only put things
-- where they can be found.
--
-- ## Cost, stated before it is paid
--
-- 560 concepts onto 2,961 revisions is a fifth again, and every future publish
-- copies all of them. That is affordable now and is the number to look at before
-- batch two: the remaining 953 ISRCs on this account alone would take it to
-- roughly 4,500, and the versioned ontology copies the whole set each time.
--
-- ## This is batch A
--
-- `0213` repaired `mint_vocabulary_from_catalogue`, which had never copied
-- `external_concept_links` forward and would have dropped all 760 on its next
-- publish. That fix has been proven by a statement-level probe and not yet by
-- two real batches. **This is the first one.** When the mint function next
-- publishes — batch B — these links must still be here, and that is the gate.

begin;

do $$
declare
  current_version text;
  old_version_id  uuid;
  next_version    text;
  new_version_id  uuid;
  music_hub       uuid;
  links_before    integer;
  links_after     integer;
  ambiguous_before integer;
  ambiguous_after  integer;
  minted          integer;
  revised         integer;
  edged           integer;
  linked          integer;
  unreachable     integer;
  published_now   text;
  enqueued        integer;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception '0214: no published ontology version to branch from';
  end if;

  select cr.concept_id into music_hub
    from ontology.concept_revisions cr
    join ontology.concepts c on c.id = cr.concept_id
   where cr.ontology_version_id = old_version_id
     and c.concept_key = 'hub:music' and cr.status = 'active';
  if music_hub is null then
    raise exception '0214: hub:music is not active at %', current_version;
  end if;

  select count(*) into links_before
    from ontology.external_concept_links where ontology_version_id = old_version_id;
  select count(*) into ambiguous_before from (
    select l.normalized_label from ontology.concept_labels l
     where l.ontology_version_id = old_version_id and l.status = 'active'
     group by l.normalized_label having count(distinct l.concept_id) > 1) a;

  -- The batch: one row per ISRC, newest catalogue answer, and only where an
  -- active observation actually carries that ISRC. A recording nobody has is
  -- vocabulary for its own sake.
  create temporary table recording_batch on commit drop as
  select distinct on (e.external_id)
         e.external_id                             as isrc,
         'recording:isrc_' || lower(e.external_id) as concept_key,
         e.raw_payload ->> 'name'                  as title,
         e.raw_payload ->> 'artistName'            as artist,
         e.id                                      as entity_id
    from ontology.external_entities e
   where e.provider = 'apple_music_catalog'
     and e.entity_kind = 'song'
     and coalesce(e.raw_payload ->> 'name', '') <> ''
     and exists (
       select 1 from semantic_private.observations o
        where o.lifecycle_state = 'active'
          and o.normalized_payload ->> 'isrc' = e.external_id)
   order by e.external_id, e.retrieved_at desc;

  select count(*) into minted from recording_batch;
  if minted = 0 then
    raise notice '0214: no catalogued recording is held by anybody; nothing to mint';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Recordings by ISRC, batch A: ' || minted || ' concepts. Copied forward from '
          || current_version || '.');
  select id into new_version_id from ontology.versions where version = next_version;

  -- ---- copy forward, all five ----
  insert into ontology.concept_revisions
    (ontology_version_id, concept_id, preferred_label, concept_kind, definition,
     sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition,
         r.sensitivity, r.inference_policy, r.status, r.metadata
    from ontology.concept_revisions r
   where r.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_labels
    (ontology_version_id, concept_id, label, normalized_label, locale, label_type,
     provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale,
         l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l
   where l.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
     confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id,
         e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e
   where e.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.motif_rules
    (id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
     evidence_predicate_key, output_predicate_key, rule_kind,
     minimum_independence_groups, minimum_strength, configuration, status)
  select extensions.gen_random_uuid(), new_version_id, m.rule_key,
         m.evidence_target_concept_id, m.output_concept_id, m.evidence_predicate_key,
         m.output_predicate_key, m.rule_kind, m.minimum_independence_groups,
         m.minimum_strength, m.configuration, m.status
    from ontology.motif_rules m
   where m.ontology_version_id = old_version_id
  on conflict do nothing;

  -- **The fifth**, which `0179`, `0180` and the mint function all forgot.
  insert into ontology.external_concept_links
    (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, x.concept_id, x.external_entity_id, x.link_type,
         x.confidence, x.status
    from ontology.external_concept_links x
   where x.ontology_version_id = old_version_id
  on conflict do nothing;

  -- ---- the recordings ----
  insert into ontology.concepts (id, concept_key)
  select extensions.gen_random_uuid(), b.concept_key from recording_batch b
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions
    (ontology_version_id, concept_id, preferred_label, concept_kind, definition,
     sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, b.title, 'work', null, 'ordinary', 'inferable', 'active',
         jsonb_build_object(
           'term_family', 'music_recording',
           'work_type', 'music_recording',
           'provider', 'apple_music_catalog',
           'external_id', b.isrc,
           -- The performer is recorded and is not a relation. Naming an artist
           -- concept here would be `performed_by`, which is a claim this batch
           -- has not established and `0200`'s predicate rules would police.
           'artist_name', b.artist)
    from recording_batch b
    join ontology.concepts c on c.concept_key = b.concept_key
  on conflict do nothing;
  get diagnostics revised = row_count;

  -- **`curated`, not `external`.** `publish_version` reads an `external` edge as
  -- a promise that `provenance ->> 'external_entity_id'` resolves, and fourteen
  -- edges that lied about it blocked the first real publish in eighteen
  -- versions. The provenance is recorded either way.
  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
     confidence, provenance_type, provenance, status)
  select new_version_id, c.id, 'broader', music_hub, 1.0, 'curated',
         jsonb_build_object('source', '0214', 'basis', 'isrc_recording'), 'active'
    from recording_batch b
    join ontology.concepts c on c.concept_key = b.concept_key
  on conflict do nothing;
  get diagnostics edged = row_count;

  insert into ontology.external_concept_links
    (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, c.id, b.entity_id, 'same_as', 1.0, 'active'
    from recording_batch b
    join ontology.concepts c on c.concept_key = b.concept_key
  on conflict do nothing;
  get diagnostics linked = row_count;

  -- ---- what must be true before publishing ----

  select count(*) into links_after
    from ontology.external_concept_links where ontology_version_id = new_version_id;
  if links_after < links_before + linked then
    raise exception '0214: % links at the new version, expected at least % carried plus % new',
      links_after, links_before, linked;
  end if;

  if revised <> minted or edged <> minted or linked <> minted then
    raise exception '0214: % recordings but % revisions, % edges, % links',
      minted, revised, edged, linked;
  end if;

  -- **No label was written, so no ambiguity may have been created.** This is
  -- the assertion that would fail the day somebody adds titles as aliases
  -- without making the resolver family-aware first.
  select count(*) into ambiguous_after from (
    select l.normalized_label from ontology.concept_labels l
     where l.ontology_version_id = new_version_id and l.status = 'active'
     group by l.normalized_label having count(distinct l.concept_id) > 1) a;
  if ambiguous_after <> ambiguous_before then
    raise exception '0214: ambiguity moved from % to %', ambiguous_before, ambiguous_after;
  end if;

  -- Every minted recording files somewhere a person can find it.
  select count(*) into unreachable
    from recording_batch b
    join ontology.concepts c on c.concept_key = b.concept_key
   where semantic_private.concept_block(c.id, new_version_id) is null;
  if unreachable <> 0 then
    raise exception '0214: % recording(s) reach no hub', unreachable;
  end if;

  perform ontology.publish_version(new_version_id);

  select version into published_now from ontology.versions where status = 'published';
  if published_now is distinct from next_version then
    raise exception '0214: expected % published, found %', next_version, published_now;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': ' || minted || ' recordings by ISRC'
         ) into enqueued;

  raise notice '0214: % recordings minted, % links carried + % new, % recompute job(s)',
    minted, links_before, linked, enqueued;
end;
$$;

commit;
