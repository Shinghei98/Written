-- 0394 — JYP joins the shelf.
--
-- **The owner, 2026-08-25: organizations shelve under "Music Labels" /
-- "Entertainment Labels"; those are the card titles.** 0392 shelved the
-- organizations it could find — keyed on name-siblings among the `work:`
-- fracture rows — and JYP Entertainment was not among them: it lives as
-- `creator:jyp_entertainment`, carrying a curated `broader → genre:k_pop`
-- from an earlier round, so the page files it under K-Pop while YG, SM
-- and KBS sit on the shelf beside it. Same referent class, two headings.
--
-- The repair follows the ruling rather than the accident: the genre edge
-- retires (an organization is not a genre member; its artists are), the
-- shelf edge arrives (the genre edge is marked 'rejected' — the edge
-- vocabulary has no 'retired'), and the version bumps. **This one does need the
-- recompute tail** — edges are read at each score's own version, so the
-- new edge is invisible until a run stamps the new version.
--
-- Keyed by name, not by literal id: any `creator:` concept whose active
-- label ends in a label-marker word (entertainment/labels) and which
-- carries a genre broader edge but no shelf edge gets the same move, so
-- a sibling found later falls under the same rule instead of a 0395.

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  shelf_id uuid;
  org record;
  moved integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  create temporary table _orgs on commit drop as
  select distinct c.id as concept_id, c.concept_key, r.preferred_label
    from ontology.concepts c
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = old_version_id
     and r.status = 'active'
   where c.retired_at is null
     and c.concept_key like 'creator:%'
     and r.preferred_label ~* '(entertainment|labels)$'
     and exists (
       select 1 from ontology.concept_edges e
        join ontology.concepts g on g.id = e.object_concept_id
       where e.subject_concept_id = c.id
         and e.ontology_version_id = old_version_id
         and e.status = 'active' and e.predicate_key = 'broader'
         and g.concept_key like 'genre:%')
     and not exists (
       select 1 from ontology.concept_edges e
        join ontology.concepts s on s.id = e.object_concept_id
       where e.subject_concept_id = c.id
         and e.ontology_version_id = old_version_id
         and e.status = 'active' and e.predicate_key = 'broader'
         and s.concept_key in ('subject:music_labels',
                               'subject:entertainment_labels'));

  if not exists (select 1 from _orgs) then
    raise notice '0394: no genre-filed organization stands; the rule waits';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Genre-filed label organizations move to their shelf.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  select id into shelf_id from ontology.concepts
   where concept_key = 'subject:music_labels';

  for org in select * from _orgs loop
    -- 'rejected', not 'retired': the edge status vocabulary is
    -- candidate/active/rejected/blocked, and rejected is the state for an
    -- edge the ontology no longer stands behind at this version.
    update ontology.concept_edges e
       set status = 'rejected'
      from ontology.concepts g
     where e.subject_concept_id = org.concept_id
       and e.ontology_version_id = new_version_id
       and e.status = 'active' and e.predicate_key = 'broader'
       and g.id = e.object_concept_id
       and g.concept_key like 'genre:%';

    insert into ontology.concept_edges (
      ontology_version_id, subject_concept_id, predicate_key,
      object_concept_id, confidence, provenance_type, provenance, status)
    values (new_version_id, org.concept_id, 'broader', shelf_id,
            0.9, 'curated',
            jsonb_build_object('rule', '0394 organizations shelve'),
            'active')
    on conflict do nothing;

    moved := moved + 1;
    raise notice '0394: % moves to the music shelf', org.concept_key;
  end loop;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || moved || ' organization(s) moved to their shelf');
  raise notice '0394: % published — % moved', next_version, moved;
end;
$$;

commit;
