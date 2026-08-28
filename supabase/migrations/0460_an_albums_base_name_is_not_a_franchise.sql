-- 0460 — an album's base name is not a franchise.
--
-- **How 379 songs became shows.** The model lane states
-- `part_of_franchise` for release families as readily as for media
-- franchises — "Resister (Special Edition)" part of "Resister",
-- "Die For You" part of "After Hours", and in the worst rows an artist
-- part of their own single. `0377` then minted every unpromoted
-- franchise-family object of such a relation, identity-gated against
-- *minted* labels only — the presumed dictionary's own same-name
-- `music_work` and `album` entries, the evidence that the "franchise"
-- is a recording, were never consulted. 379 recording names entered
-- the vocabulary as works (Illusion, Midnight City, Brave Shine,
-- Luxury Disease — and Leehom Wang, an artist), 157 of them carrying
-- assertions; their stated `Anime` genres attached, and the bio layer
-- read kind=work, block=genre:anime as television.
--
-- **The rule is tier-5's, extended to the dictionary the mint reads
-- from**: a label the dictionary itself also holds as a recording
-- family is not an unambiguous franchise identity — it refuses, and
-- waits for an independent signal. Measured before writing: of the 379,
-- exactly two carry independently curated identity — Twilight and
-- August Rush, real films with curated film-genre parents — and zero
-- carry an external (Wikidata) link. The two stay; independent identity
-- is precisely what the gate asks for.
--
-- Two acts:
--   1. the guard, `franchise_label_is_recording_family`, for every
--      future franchise-mint pass to call before trusting a
--      franchise-family dictionary row — the next corpus ingest repeats
--      0377's pattern, and the check must outlive this cleanup;
--   2. the cleanup: the mis-mints deprecate at a new version, their
--      assertions demote in the same change (a rule that only withholds
--      arrives too late), and the publish asks for its recompute.
--
-- Deprecated, never deleted: the revisions stay, the edges stay, and a
-- future mint with real identity (a Wikidata import, a curated
-- placement) revives the name through the normal routes.

begin;

-- ---------------------------------------------------------------
-- 1. The guard for the next mint pass.
-- ---------------------------------------------------------------
create or replace function semantic_private.franchise_label_is_recording_family(p_label text)
 returns boolean
 language sql
 stable
 set search_path to ''
as $function$
  -- True when the presumed dictionary holds this name as a recording —
  -- a music_work or album — which makes it an ambiguous franchise
  -- identity under tier-5: refuse, count, and wait for an independent
  -- signal. Every franchise-mint pass (0377's shape) must consult this
  -- before minting a franchise-family object.
  select exists (
    select 1 from semantic_private.presumed_terms t
     where t.family in ('music_work', 'album')
       and lower(btrim(coalesce(nullif(t.english_label, ''), t.canonical_label)))
           = lower(btrim(p_label)));
$function$;

-- ---------------------------------------------------------------
-- 2. The cleanup, at a new version, assertions demoted with it.
-- ---------------------------------------------------------------
do $$
declare
  current_version text;
  current_version_id uuid;
  next_version text;
  new_version_id uuid;
  deprecated_count integer := 0;
  demoted_count integer := 0;
  survivors integer := 0;
begin
  select version, id into current_version, current_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    return;  -- an empty database minted nothing; the replay is clean
  end if;

  create temporary table _recording_family_mints on commit drop as
  select c.id as concept_id
    from ontology.concepts c
    join ontology.concept_revisions cr on cr.concept_id = c.id
     and cr.ontology_version_id = current_version_id and cr.status = 'active'
   where cr.metadata ->> 'origin' = '0377_franchise_mint'
     and semantic_private.franchise_label_is_recording_family(cr.preferred_label)
     -- Independent identity survives: a curated or provider placement,
     -- or an external link, is the signal the refusal waits for.
     and not exists (
       select 1 from ontology.concept_edges e
        where e.subject_concept_id = c.id
          and e.ontology_version_id = current_version_id
          and e.status = 'active'
          and e.provenance_type in ('curated', 'provider'))
     and not exists (
       select 1 from ontology.external_concept_links x
        where x.concept_id = c.id
          and x.ontology_version_id = current_version_id
          and x.status = 'active');

  select count(*) into deprecated_count from _recording_family_mints;
  if deprecated_count = 0 then
    return;  -- nothing to repair; no version is spent saying so
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (gen_random_uuid(), next_version, current_version_id, 'draft',
          '0460: ' || deprecated_count
          || ' recording-family franchise mint(s) deprecate — an album''s '
          || 'base name is not a franchise.')
  returning id into new_version_id;

  perform ontology.copy_forward_version(current_version_id, new_version_id);

  update ontology.concept_revisions cr
     set status = 'deprecated'
    from _recording_family_mints m
   where cr.concept_id = m.concept_id
     and cr.ontology_version_id = new_version_id;

  -- The transformation, asserted: no recording-family 0377 mint without
  -- independent identity remains active at the new version.
  select count(*) into survivors
    from ontology.concept_revisions cr
    join _recording_family_mints m on m.concept_id = cr.concept_id
   where cr.ontology_version_id = new_version_id and cr.status = 'active';
  if survivors > 0 then
    raise exception '0460: % recording-family mint(s) still active', survivors;
  end if;

  perform ontology.publish_version(new_version_id);

  -- The claims demote with the rule that refuses them.
  update semantic_private.user_assertions a
     set machine_state = 'inactive', updated_at = now()
    from _recording_family_mints m
   where a.concept_id = m.concept_id
     and a.machine_state in ('candidate', 'eligible');
  get diagnostics demoted_count = row_count;

  -- 0396: the published version asks for the recompute that will read it.
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || deprecated_count
    || ' recording-family franchise mint(s) deprecated, '
    || demoted_count || ' assertion(s) demoted');
end;
$$;

commit;
