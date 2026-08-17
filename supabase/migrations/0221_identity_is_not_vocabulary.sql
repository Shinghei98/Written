-- 0221 — identity is not vocabulary.
--
-- ## The distinction this draws
--
-- **A globally identifiable thing is not automatically ontology vocabulary.**
-- An ISRC identifies a recording exactly, permanently and across every account
-- that holds it. That makes the recording a *verified shared catalogue entity*
-- — the identity is certain and nothing about it is provisional. What has not
-- happened, and should not, is **promotion**: becoming a term the system may say
-- about a person.
--
-- The two were conflated because minting a concept was the only way to have a
-- durable handle on a thing. So `0214` minted 560 `recording:isrc_*` concepts
-- into the versioned ontology, and they have sat there ever since being copied
-- forward, scored, and asserted about nobody.
--
-- The layers this separates:
--
-- | layer | holds | versioned |
-- |---|---|---|
-- | identity registry | `ontology.external_entities` — ISRC → title, artist, genres | no |
-- | semantic ontology | genres, creators, works, activities, topics | **yes** |
-- | evidence | `observation_mappings` | per run |
--
-- **Recordings belong to the first layer and are being moved back to it.**
-- They were never absent from it: every one of the 560 was minted *from* an
-- `external_entities` row that is still there, still keyed by ISRC, and still
-- carrying more than the concept ever did.
--
-- ## Why this is not tidying
--
-- Three measured reasons, in the order they matter.
--
-- **1. A recording is `concept_kind = 'work'`, and `work` is on the Memories
-- allowlist.** `api.list_assertions` admits `creator`, `work`, `activity` and
-- `topic`; the work bar is the 0.25 relief. So the only thing keeping *"you are
-- someone who owns this particular track"* off somebody's profile is that 560
-- recordings average 1.31 observations and top out at `strength` 0.148. **That
-- is a margin, not a rule.** A heavily-played track on a future library crosses
-- it and puts a song title on a page as a claim about a person. Removing the
-- concepts removes the possibility rather than relying on the number.
--
-- **2. The rollup was anchored to vocabulary it does not use.** The genre rollup
-- (`0220`) fired only where a recording concept existed, but it reads its genres
-- from `external_entities`, which states a genre for **1,421** catalogued songs
-- against the **560** recordings ever minted. Measured over both live accounts,
-- that gate reached **245 of the 666 weight available and cost a real crossing**
-- — `genre:dance` at 0.649. The resolver change shipping with this migration
-- reads the registry directly, which is both more evidence and one less thing
-- that has to exist first.
--
-- **3. The cost is permanent and compounds.** Every future ontology version
-- copies all five tables forward, so the 560 concepts, their labels, their edges
-- and their links are recopied into every version this project ever publishes,
-- to be scored and discarded each time.
--
-- ## What is kept, because retirement is not deletion
--
-- **Ontology version 0.34.0 keeps its 560 recordings, untouched and forever.**
-- Published versions are immutable, and every run computed against 0.34.0 must
-- stay reproducible against exactly what it saw. Nothing is deleted, no revision
-- is rewritten, and no `external_entities` row is touched — the identity
-- registry is the layer recordings are moving *to*.
--
-- What changes is that **0.35.0 does not carry them forward**, which is the only
-- honest way to remove a concept from a system whose versions are immutable.
--
-- **And that makes the split structural rather than a convention.**
-- `observation_mappings` references
-- `concept_revisions (ontology_version_id, concept_id)`, so a mapping exists
-- only where a revision of that concept exists *in that version*. With no
-- recording revision in 0.35.0, a recording mapping at 0.35.0 is refused by a
-- foreign key — not merely not written by code that remembers not to. The 731
-- mappings already recorded at 0.34.0 are untouched for the same reason, their
-- revisions being exactly where they were.
--
-- ## The helper, and why the exclusion cannot be left to the next author
--
-- The five-table copy-forward is hand-written in every migration that publishes
-- a version. **`0213` exists because one of them forgot the fifth table** and
-- silently dropped 760 links down to 1. An exclusion that also has to be
-- remembered by hand would be the same bug with a different name — and worse,
-- because forgetting it *restores* the concepts rather than losing them, which
-- nothing would report.
--
-- So `ontology.copy_forward_version` is the copy-forward, once, with the
-- exclusion inside it, and `ontology.is_identity_registry_concept` is the single
-- place a family is named. A second identity family later is one line there
-- rather than an edit to every future migration. **The failure mode of a
-- deny-list is silence**, so the assertions below demand the predicate answer
-- both ways over real rows.

begin;

-- ---------------------------------------------------------------------------
-- 1. One place that names an identity family.
-- ---------------------------------------------------------------------------

create or replace function ontology.is_identity_registry_concept(concept_key text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  -- **A key prefix, deliberately, and not a `concept_kind`.** A recording is
  -- `work`, and so are the album and soundtrack concepts that are perfectly
  -- good vocabulary — the kind cannot separate the identifier-keyed thing from
  -- the nameable one. This is the same shape as `NEVER_ASSERTED_KEY_PREFIXES`
  -- in `score.py`, which had to say the same about `era:`, `sphere:` and
  -- `scene:` for the same reason.
  select concept_key like 'recording:isrc\_%';
$$;

comment on function ontology.is_identity_registry_concept(text) is
  'True for concepts whose identity comes from an external registry and which '
  'are therefore not versioned semantic vocabulary. Named by key prefix because '
  'concept_kind cannot tell an identifier-keyed work from a nameable one.';

-- ---------------------------------------------------------------------------
-- 2. The copy-forward, once, with the exclusion inside it.
-- ---------------------------------------------------------------------------

create or replace function ontology.copy_forward_version(
  old_version_id uuid,
  new_version_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  excluded_concepts integer;
begin
  if old_version_id is null or new_version_id is null then
    raise exception 'copy_forward_version: both versions are required';
  end if;
  if not exists (select 1 from ontology.versions where id = new_version_id and status = 'draft') then
    raise exception 'copy_forward_version: the target must exist and be draft';
  end if;

  insert into ontology.concept_revisions
    (ontology_version_id, concept_id, preferred_label, concept_kind, definition,
     sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition,
         r.sensitivity, r.inference_policy, r.status, r.metadata
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = old_version_id
     and not ontology.is_identity_registry_concept(c.concept_key)
  on conflict do nothing;

  insert into ontology.concept_labels
    (ontology_version_id, concept_id, label, normalized_label, locale, label_type,
     provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale,
         l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l
    join ontology.concepts c on c.id = l.concept_id
   where l.ontology_version_id = old_version_id
     and not ontology.is_identity_registry_concept(c.concept_key)
  on conflict do nothing;

  -- **Both ends of an edge are tested.** An edge from a surviving concept to a
  -- removed one would be copied forward pointing at a concept with no revision
  -- in this version, which is the shape `publish_version` refuses only for
  -- *external* provenance and would otherwise let through.
  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
     confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id,
         e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e
    join ontology.concepts subject on subject.id = e.subject_concept_id
    join ontology.concepts object on object.id = e.object_concept_id
   where e.ontology_version_id = old_version_id
     and not ontology.is_identity_registry_concept(subject.concept_key)
     and not ontology.is_identity_registry_concept(object.concept_key)
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

  -- **The fifth, which `0179`, `0180` and the mint function all forgot** and
  -- `0213` had to repair after 760 links became 1. It is inside this function
  -- now so that it cannot be forgotten a fourth time.
  insert into ontology.external_concept_links
    (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, x.concept_id, x.external_entity_id, x.link_type,
         x.confidence, x.status
    from ontology.external_concept_links x
    join ontology.concepts c on c.id = x.concept_id
   where x.ontology_version_id = old_version_id
     and not ontology.is_identity_registry_concept(c.concept_key)
  on conflict do nothing;

  select count(*) into excluded_concepts
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = old_version_id
     and ontology.is_identity_registry_concept(c.concept_key);

  raise notice 'copy_forward_version: % identity-registry concept(s) left behind',
    excluded_concepts;
end;
$$;

revoke all on function ontology.copy_forward_version(uuid, uuid)
  from public, anon, authenticated, semantic_ingestor, semantic_worker;
revoke all on function ontology.is_identity_registry_concept(text)
  from public, anon, authenticated, semantic_ingestor;

-- ---------------------------------------------------------------------------
-- 3. Publish 0.35.0 without them.
-- ---------------------------------------------------------------------------

do $$
declare
  old_version_id  uuid;
  new_version_id  uuid;
  current_version text;
  next_version    text;
  left_behind     integer;
  carried         integer;
  before_count    integer;
begin
  select id, version into old_version_id, current_version
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise exception '0221: there is no published ontology version';
  end if;

  select count(*) into left_behind
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = old_version_id
     and ontology.is_identity_registry_concept(c.concept_key);

  -- **Conditional on there being something to move**, so this replays against
  -- an empty database. A version published purely to drop nothing would be a
  -- version that states a change it did not make.
  if left_behind = 0 then
    raise notice '0221: no identity-registry concept is in %; nothing to split out',
      current_version;
    return;
  end if;

  select count(*) into before_count
    from ontology.concept_revisions where ontology_version_id = old_version_id;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Identity is not vocabulary: ' || left_behind || ' identity-registry '
          || 'concept(s) are not carried forward from ' || current_version
          || '. They remain in ' || current_version || ' and in '
          || 'ontology.external_entities, which is the layer they belong to.');
  select id into new_version_id from ontology.versions where version = next_version;

  perform ontology.copy_forward_version(old_version_id, new_version_id);

  select count(*) into carried
    from ontology.concept_revisions where ontology_version_id = new_version_id;
  if carried <> before_count - left_behind then
    raise exception
      '0221: expected % revision(s) carried forward, found % (was %, leaving % behind)',
      before_count - left_behind, carried, before_count, left_behind;
  end if;

  perform ontology.publish_version(new_version_id);

  raise notice '0221: published % with % concept(s), % left in %',
    next_version, carried, left_behind, current_version;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Resolver 0.13.0, and the stale work queued against 0.12.0.
-- ---------------------------------------------------------------------------
--
-- **0.12.0 never ran.** It was published by `0220` and the Lambda carrying its
-- rollup had not been deployed when this landed, so the three `recompute_user`
-- jobs it enqueued are pinned — by `resolver_model_id` and
-- `ontology_version_id` in their payload — to a resolver and an ontology that
-- are both about to be retired. Left queued they would execute *this* code and
-- record it under 0.12.0 against 0.34.0, which is exactly the defect `0217` was
-- written to repair: **a run stating something untrue about what produced it.**
--
-- So they are marked `dead` rather than left to run, and the enqueue at the
-- foot replaces them with jobs pinned to what will actually execute. A dead job
-- is a queue outcome, not evidence being destroyed; the row and its payload stay
-- exactly where they are.

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select extensions.gen_random_uuid(), 'ontology_first_resolver', '0.13.0', 'resolver', null,
       old.parameters || jsonb_build_object(
         'identity_registry_split',
         'Recordings are no longer versioned semantic vocabulary. The ISRC route '
         || 'still resolves identity, but reads it from ontology.external_entities '
         || 'rather than from a recording concept, and writes no provider_id '
         || 'mapping to one — there is no such concept in this ontology version. '
         || 'The genre rollup consequently runs for any observation whose ISRC '
         || 'the catalogue knows, not only for the subset that had been minted: '
         || 'the registry states a genre for 1,421 catalogued songs where 560 '
         || 'recordings existed, and the old gate reached 245 of the 666 weight '
         || 'available while costing one real crossing. Recording concepts are '
         || 'not deleted: ontology 0.34.0 keeps all 560 so its runs stay '
         || 'reproducible, and they are simply not copied into 0.35.0.'
       ),
       'active'
  from (
    select * from ontology.model_versions
     where model_key = 'ontology_first_resolver'
     order by string_to_array(version, '.')::integer[] desc
     limit 1
  ) old
on conflict (model_key, version) do update
   set parameters = ontology.model_versions.parameters || excluded.parameters,
       status = 'active';

update ontology.model_versions set status = 'retired'
 where model_key = 'ontology_first_resolver'
   and status = 'active'
   and version <> '0.13.0';

update semantic_private.worker_jobs j
   set status = 'dead'
 where j.status = 'queued'
   and j.job_type = 'recompute_user'
   and not exists (
     select 1 from ontology.model_versions m
      where m.id = (j.payload ->> 'resolver_model_id')::uuid
        and m.status = 'active');

-- ---------------------------------------------------------------------------
-- 5. Prove it, both ways, over real rows.
-- ---------------------------------------------------------------------------

do $$
declare
  published_id   uuid;
  recordings_now integer;
  recordings_old integer;
  genres_now     integer;
  registry_rows  integer;
  actives        integer;
  stale_jobs     integer;
  enqueued       integer;
begin
  select count(*) into actives
    from ontology.model_versions
   where model_key = 'ontology_first_resolver' and status = 'active';
  if actives <> 1 then
    raise exception '0221: expected one active resolver, found %', actives;
  end if;

  -- **The predicate must answer both ways**, or it is not believed. A rule that
  -- has only ever returned false is indistinguishable from one that always does.
  if not ontology.is_identity_registry_concept('recording:isrc_gbayk8600001') then
    raise exception '0221: the predicate refuses a recording key';
  end if;
  if ontology.is_identity_registry_concept('genre:baroque')
     or ontology.is_identity_registry_concept('creator:apple_123')
     or ontology.is_identity_registry_concept('work:apple_456') then
    raise exception '0221: the predicate claims ordinary vocabulary is a registry entry';
  end if;

  select id into published_id from ontology.versions where status = 'published';

  select count(*) into recordings_now
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = published_id
     and ontology.is_identity_registry_concept(c.concept_key);
  if recordings_now <> 0 then
    raise exception '0221: % recording(s) are still in the published ontology',
      recordings_now;
  end if;

  -- **The genres the rollup needs must have survived the same copy-forward.**
  -- Removing concepts by predicate is precisely how an over-broad predicate
  -- empties something it was never aimed at, and a count of the thing that must
  -- remain is what catches it.
  select count(*) into genres_now
    from ontology.concept_revisions r
   where r.ontology_version_id = published_id and r.concept_kind = 'genre';

  select count(*) into recordings_old
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
    join ontology.versions v on v.id = r.ontology_version_id
   where v.status = 'retired'
     and ontology.is_identity_registry_concept(c.concept_key);

  -- **Identity is untouched.** This migration moves recordings *to* the
  -- registry, so the registry losing rows would mean it had done the opposite of
  -- what it says.
  select count(*) into registry_rows
    from ontology.external_entities
   where provider = 'apple_music_catalog' and entity_kind = 'song';

  if registry_rows = 0 and recordings_old > 0 then
    raise exception '0221: recordings were removed from the ontology and the registry is empty';
  end if;

  if genres_now = 0 and recordings_old > 0 then
    raise exception '0221: the copy-forward left no genre concept; the predicate is too broad';
  end if;

  select count(*) into stale_jobs
    from semantic_private.worker_jobs j
   where j.status = 'queued' and j.job_type = 'recompute_user'
     and not exists (
       select 1 from ontology.model_versions m
        where m.id = (j.payload ->> 'resolver_model_id')::uuid
          and m.status = 'active');
  if stale_jobs <> 0 then
    raise exception '0221: % job(s) are still queued against a retired resolver', stale_jobs;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'resolver 0.13.0 and ontology without the identity registry'
         ) into enqueued;

  raise notice
    '0221: % recording(s) retained in the retired version, 0 published, % genre(s) kept, % registry row(s), % job(s) enqueued',
    recordings_old, genres_now, registry_rows, enqueued;
end;
$$;

commit;
