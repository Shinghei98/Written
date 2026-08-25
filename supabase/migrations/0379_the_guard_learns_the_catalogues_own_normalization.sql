-- 0379 — the guard learns the catalogue's own normalization, and the
--          shadows it admitted retire.
--
-- **The first trickle run presented the bill (2026-08-25).** 0377's
-- ambiguity guard compared `lower(btrim(name))` while the catalogue's
-- labels normalize punctuation to spaces — so "K-Pop" (guard: `k-pop`)
-- missed `genre:k_pop` (label: `k pop`) by exactly one hyphen, and the
-- fractured dictionary's franchise rows minted shadows of existing
-- identities: a genre, agencies, a broadcaster wearing `work:` keys, one
-- of them soaking 0.93 of trickle beside the real heading.
--
-- The repair is the corrected rule, applied both ways:
-- - **Retire every 0377/0378-minted concept whose properly-normalized
--   name matches a pre-existing concept's active label** — deprecated
--   with `merged_into`, edges rejected, dictionary promotion unwound so
--   the term is mintable-again once reconciled. Nothing is deleted.
-- - The correction is recorded here as the normalization contract for
--   every future support-free mint: compare through
--   `regexp_replace(lower(x), '[^a-z0-9À-￿]+', ' ', 'g')`, the same
--   collapse the twin-merge and fold migrations already use.
--
-- Replayable by asserting the transformation: a clean database has no
-- 0377 mints and retires nothing.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  retired         integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- The shadows: support-free mints whose corrected-normalized name
  -- matches an older concept's active label.
  create temporary table _shadows on commit drop as
  select distinct c.id as shadow_id, c.concept_key as shadow_key,
         older.concept_key as original_key
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
    join ontology.concept_labels l
      on l.ontology_version_id = old_version_id and l.status = 'active'
     and l.normalized_label = btrim(regexp_replace(
           lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g'))
    join ontology.concepts older on older.id = l.concept_id
     and older.id <> c.id and older.retired_at is null
   where r.ontology_version_id = old_version_id and r.status = 'active'
     and r.metadata->>'origin' in ('0377_franchise_mint', '0378_provider_topic')
     -- The label match must predate the mint: an older concept, not a
     -- fellow mint.
     and older.created_at < c.created_at;

  if not exists (select 1 from _shadows) then
    raise notice '0379: no shadows here; the corrected guard stands for the future';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Shadow mints retire: the guard normalizes as the catalogue does.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  update ontology.concept_labels
     set status = 'deprecated'
   where ontology_version_id = new_version_id
     and concept_id in (select shadow_id from _shadows) and status = 'active';

  update ontology.concept_edges
     set status = 'rejected'
   where ontology_version_id = new_version_id and status = 'active'
     and (subject_concept_id in (select shadow_id from _shadows)
          or object_concept_id in (select shadow_id from _shadows));

  update ontology.concept_revisions r
     set status = 'deprecated',
         metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('merged_into', s.original_key,
                                          'merged_by', '0379')
    from _shadows s
   where r.ontology_version_id = new_version_id
     and r.concept_id = s.shadow_id and r.status = 'active';
  get diagnostics retired = row_count;

  -- The dictionary unwinds: the term is mintable-again once reconciled.
  update semantic_private.presumed_terms
     set promoted_concept_id = null, promoted_at = null
   where promoted_concept_id in (select shadow_id from _shadows);

  -- Any assertion that reached a shadow retires with it.
  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where concept_id in (select shadow_id from _shadows)
     and machine_state <> 'inactive';

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || retired || ' shadow mint(s) retired');
  raise notice '0379: % published — % shadow(s) retired onto their originals',
    next_version, retired;
end;
$$;

commit;
