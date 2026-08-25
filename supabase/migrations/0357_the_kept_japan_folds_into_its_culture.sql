-- 0357 — the kept "Japan" folds into culture:japan.
--
-- **The owner's adjudication, 2026-08-25, of the conflict 0356 asserted.**
-- The vault settles what the kept concept is: the surface "Japan" was
-- extracted from a YouTube liked-video title with `type_hint: place`, and
-- the user kept it as family `place` (`mint_requests.requested_family`).
-- Two era-defects then dressed the country as a song: the pre-0337 mint
-- route filed every kept term as `work:kept_<hash>` kind `work` regardless
-- of the proposed family, and 0272's rule — "a kept term reaches the genre
-- its evidence states" — handed it the *entry's* genre, `genre:pop`,
-- reasonable for a song title and wrong for a country appearing in one.
-- Both defects are already fixed for new keeps (0337's family convention:
-- place → place:, kind place, hub:places_cultures); this row predates the
-- fix, and 0356 minted `culture:japan` beside it without its English name
-- rather than silently arbitrating. The owner arbitrated: fold.
--
-- **The merge is 0350's shape: a version-level deprecation, never a
-- deletion.** The kept concept's labels re-issue on `culture:japan` — and
-- `japan` arrives as the *preferred* label, because 0356's collision guard
-- left the culture with no preferred label row at all. The keep is
-- honoured, not erased: the user's `explicit_addition` assertion repoints
-- to the surviving concept (`affinity_to` is a user_claim and the origin is
-- not inferred, so the relation-class guard permits the move), and the
-- provisional entity's redirect follows it, `transfer_suppression_on_redirect`
-- carrying any suppression state as it was built to.
--
-- **Replayable by asserting the transformation, not the precondition.** The
-- kept concept was minted at runtime by a user's keep, so a clean replay
-- has no loser — and needs no fold, because on that path 0356's culture
-- already took its own name. Vacuous is correct there, not a failure.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  loser_id  uuid;
  winner_id uuid;
  labels_moved integer;
  assertions_moved integer;
  redirects_moved integer;
  probe_key text;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  select id into loser_id from ontology.concepts
   where concept_key = 'work:kept_dd80c8fc499c3058' and retired_at is null;
  select id into winner_id from ontology.concepts
   where concept_key = 'culture:japan' and retired_at is null;

  if winner_id is null then
    raise exception '0357: culture:japan is absent — 0356 must land first';
  end if;
  if loser_id is null then
    raise notice '0357: no kept Japan here; the culture already owns its name';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'The kept work "Japan" merges into culture:japan (owner adjudication).');
  select id into new_version_id from ontology.versions where version = next_version;

  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- The loser's labels, re-issued on the winner. `japan` lands as preferred
  -- because the winner holds no preferred label row (0356's collision guard
  -- refused it while the kept work stood); had one existed, the incoming
  -- preferred would demote, as in 0350.
  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, winner_id, l.label, l.normalized_label, l.locale,
         case when l.label_type = 'preferred' and exists (
                select 1 from ontology.concept_labels held
                 where held.ontology_version_id = new_version_id
                   and held.concept_id = winner_id
                   and held.label_type = 'preferred'
                   and held.status = 'active')
              then 'alternate' else l.label_type end,
         l.provenance_type, l.confidence, 'active',
         coalesce(l.external_ref, '{}'::jsonb)
           || jsonb_build_object('merged_from', 'work:kept_dd80c8fc499c3058')
    from ontology.concept_labels l
   where l.ontology_version_id = new_version_id
     and l.concept_id = loser_id
     and l.status = 'active'
     and not exists (
       select 1 from ontology.concept_labels taken
        where taken.ontology_version_id = new_version_id
          and taken.status = 'active'
          and taken.normalized_label = l.normalized_label
          and taken.concept_id not in (loser_id, winner_id))
  on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
    do nothing;
  get diagnostics labels_moved = row_count;

  -- The loser steps down, at this version only.
  update ontology.concept_labels
     set status = 'deprecated'
   where ontology_version_id = new_version_id
     and concept_id = loser_id and status = 'active';

  update ontology.concept_edges
     set status = 'rejected'
   where ontology_version_id = new_version_id
     and subject_concept_id = loser_id and status = 'active';

  update ontology.concept_revisions
     set status = 'deprecated',
         metadata = coalesce(metadata, '{}'::jsonb)
                    || jsonb_build_object('merged_into', 'culture:japan',
                                          'merged_by', '0357')
   where ontology_version_id = new_version_id
     and concept_id = loser_id and status = 'active';

  if labels_moved = 0 then
    raise exception '0357: the merge moved no labels, which is not a merge';
  end if;

  -- The keep is honoured: the user's assertion follows the subject it was
  -- always about, and the provisional redirect follows with it.
  update semantic_private.user_assertions
     set concept_id = winner_id
   where concept_id = loser_id;
  get diagnostics assertions_moved = row_count;

  update semantic_private.provisional_entities
     set redirect_concept_id = winner_id
   where redirect_concept_id = loser_id;
  get diagnostics redirects_moved = row_count;

  if exists (select 1 from semantic_private.user_assertions
              where concept_id = loser_id) then
    raise exception '0357: an assertion still names the deprecated concept';
  end if;

  perform ontology.publish_version(new_version_id);

  -- Read back through the vocabulary: the word reaches the culture.
  select c.concept_key into probe_key
    from ontology.concept_labels l
    join ontology.concepts c on c.id = l.concept_id
   where l.ontology_version_id = new_version_id and l.status = 'active'
     and l.normalized_label = 'japan'
   limit 1;
  if probe_key is distinct from 'culture:japan' then
    raise exception '0357: "japan" resolves to %, expected culture:japan',
      coalesce(probe_key, '(nothing)');
  end if;

  if exists (
    select 1 from ontology.concept_revisions r
     where r.ontology_version_id = new_version_id
       and r.concept_id = loser_id and r.status = 'active') then
    raise exception '0357: the kept concept still holds an active revision';
  end if;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': kept Japan merged into culture:japan');

  raise notice '0357: % published — % label(s) moved, % assertion(s) repointed, % redirect(s) repointed',
    next_version, labels_moved, assertions_moved, redirects_moved;
end;
$$;

commit;
