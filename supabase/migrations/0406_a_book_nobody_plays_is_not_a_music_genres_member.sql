-- 0406 — a book nobody plays is not a music genre's member.
--
-- **The last piece of the Red Chamber repair (owner's fix 2,
-- 2026-08-26).** The fold (0404) gave the novel one identity, and
-- Timi's rescore correctly re-resolved her row onto it — but the
-- survivor still wore the model's allusion-bled guesses: `mandopop` and
-- `world_music` beside the correct `fiction_literature`, all three from
-- the dictionary bridge, and mandopop sits on the card-title priority
-- list, so the novel filed as pop music.
--
-- The rule, general and evidence-tested: **a work carrying both a
-- literature genre and music genres, with no `performed_by` or
-- `composed_by` of its own, keeps the literature and sheds the music**
-- — the music genres could only have arrived by allusion, because
-- nothing performs the work. A work somebody actually plays keeps every
-- genre it earned (the performed_by test is the gate, not the label).
--
-- Ends with the recompute enqueue (0396's rule).

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  shed integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  create temporary table _allusion_bled on commit drop as
  select c.id as concept_id, c.concept_key
    from ontology.concepts c
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = old_version_id
     and r.status = 'active' and r.concept_kind = 'work'
   where exists (
       select 1 from ontology.concept_edges le
         join ontology.concepts lg on lg.id = le.object_concept_id
        where le.subject_concept_id = c.id
          and le.ontology_version_id = old_version_id
          and le.status = 'active' and le.predicate_key = 'broader'
          and lg.concept_key ~ '^genre:.*literature')
     and not exists (
       select 1 from ontology.concept_edges pe
        where pe.subject_concept_id = c.id
          and pe.ontology_version_id = old_version_id
          and pe.status = 'active'
          and pe.predicate_key in ('performed_by', 'composed_by'))
     and exists (
       select 1 from ontology.concept_edges me
         join ontology.concepts mg on mg.id = me.object_concept_id
        where me.subject_concept_id = c.id
          and me.ontology_version_id = old_version_id
          and me.status = 'active' and me.predicate_key = 'broader'
          and mg.concept_key like 'genre:%'
          and mg.concept_key !~ 'literature'
          and exists (
            with recursive up(cid, d) as (
              select mg.id, 0
              union all
              select e2.object_concept_id, up.d + 1
                from up join ontology.concept_edges e2
                  on e2.subject_concept_id = up.cid
                 and e2.predicate_key = 'broader'
                 and e2.ontology_version_id = old_version_id
                 and e2.status = 'active'
               where up.d < 8)
            select 1 from up join ontology.concepts hc on hc.id = up.cid
             where hc.concept_key = 'hub:music'));

  if not exists (select 1 from _allusion_bled) then
    raise notice '0406: no allusion-bled works stand; the rule waits';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Unperformed literary works shed their allusion-bled music genres.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  update ontology.concept_edges e
     set status = 'rejected'
    from _allusion_bled a, ontology.concepts g
   where e.subject_concept_id = a.concept_id
     and e.ontology_version_id = new_version_id
     and e.status = 'active' and e.predicate_key = 'broader'
     and g.id = e.object_concept_id
     and g.concept_key like 'genre:%'
     and g.concept_key !~ 'literature'
     and exists (
       with recursive up(cid, d) as (
         select g.id, 0
         union all
         select e2.object_concept_id, up.d + 1
           from up join ontology.concept_edges e2
             on e2.subject_concept_id = up.cid
            and e2.predicate_key = 'broader'
            and e2.ontology_version_id = new_version_id
            and e2.status = 'active'
          where up.d < 8)
       select 1 from up join ontology.concepts hc on hc.id = up.cid
        where hc.concept_key = 'hub:music');
  get diagnostics shed = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || shed
    || ' allusion-bled music edge(s) shed from unperformed literary works');
  raise notice '0406: % published — % edges shed', next_version, shed;
end;
$$;

commit;
