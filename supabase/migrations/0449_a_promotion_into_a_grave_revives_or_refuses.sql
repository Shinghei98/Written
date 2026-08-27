-- 0449 — a promotion into a grave revives or refuses.
--
-- **The defect the owner's question uncovered**: Timi's channels were
-- minted on 0.28.0, withdrawn by 0.29.0's curation one version later,
-- and the 2026-08-24 promotion then pointed their dictionary terms at
-- the withdrawn concepts without noticing — `promoted_concept_id` set,
-- every read answering nothing, no error anywhere. The silent shape
-- this codebase names as its recurring defect.
--
-- Two halves:
--
--   1. **The revival, by rule.** Any concept a dictionary term points
--      at that is deprecated at the published version, where the term
--      carries current corpus support (`last_seen_at` within the v21
--      run's window), revives at a new draft version — revision and
--      labels back to active — and publishes. This is the owner's own
--      framing of the re-run: "make sure nothing is removed by older
--      versions." The 0438 tag-edge rule then re-runs over the newly
--      living channels, because it is a standing rule and a channel
--      that just came back deserves its field edges the same day.
--
--   2. **The refusal, forever.** A trigger on `presumed_terms` refuses
--      any future write of `promoted_concept_id` whose target has no
--      active revision at the published version — so the next
--      promotion-into-a-grave raises at the write instead of shipping
--      a silent nothing. Migrations that intend to revive do the
--      reviving first, in their own words.

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  revived integer;
  edges integer;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          '0449: withdrawn concepts with current support revive');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  create temporary table _revive on commit drop as
  select distinct t.promoted_concept_id as concept_id
    from semantic_private.presumed_terms t
    join ontology.concept_revisions r
      on r.concept_id = t.promoted_concept_id
     and r.ontology_version_id = new_version_id
     and r.status = 'deprecated'
   where t.promoted_concept_id is not null
     and t.last_seen_at >= now() - interval '7 days';

  update ontology.concept_revisions r
     set status = 'active'
    from _revive x
   where r.concept_id = x.concept_id
     and r.ontology_version_id = new_version_id
     and r.status = 'deprecated';
  get diagnostics revived = row_count;

  update ontology.concept_labels l
     set status = 'active'
    from _revive x
   where l.concept_id = x.concept_id
     and l.ontology_version_id = new_version_id
     and l.status = 'deprecated';

  raise notice '0449: % concept(s) revived with current support', revived;

  -- The 0438 rule, re-run over whoever just came back: channel tags,
  -- matched whole against the curated field vocabulary.
  with chan as (
    select distinct lower(d.name) as lname, d.extra ->> 'keywords' as kw
      from public.summary_distilled_records d
     where d.source = 'youtube' and d.data_type = 'subscription'
       and coalesce(d.extra ->> 'keywords', '') <> ''
  ),
  resolved as (
    select c.lname, c.kw, min(l.concept_id::text)::uuid as concept_id
      from chan c
      join ontology.concept_labels l
        on l.normalized_label = c.lname and l.status = 'active'
       and l.ontology_version_id = new_version_id
      join ontology.concept_revisions r
        on r.concept_id = l.concept_id and r.status = 'active'
       and r.concept_kind = 'creator'
       and r.ontology_version_id = new_version_id
     group by 1, 2
    having count(distinct l.concept_id) = 1
  ),
  tags as (
    select r.concept_id, lower(replace(btrim(t.tag), '_', ' ')) as tag
      from resolved r,
           unnest(string_to_array(r.kw, '|')) as t(tag)
  ),
  fields as (
    select distinct tg.concept_id as channel_id, fc.id as field_id
      from tags tg
      join ontology.concept_revisions fr
        on lower(fr.preferred_label) = tg.tag and fr.status = 'active'
       and fr.concept_kind = 'topic'
       and fr.ontology_version_id = new_version_id
      join ontology.concepts fc
        on fc.id = fr.concept_id and fc.concept_key like 'subject:%'
     where semantic_private.concept_hub(fc.id, new_version_id)
             = 'hub:ideas_learning'
       and tg.concept_id <> fc.id
  )
  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key,
     object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, f.channel_id, 'broader', f.field_id, 0.7, 'provider',
         jsonb_build_object('source', 'uploader_tags',
                            'rule', '0438 whole-tag match'),
         'active'
    from fields f
   where not exists (
     select 1 from ontology.concept_edges e
      where e.ontology_version_id = new_version_id
        and e.subject_concept_id = f.channel_id
        and e.predicate_key = 'broader'
        and e.object_concept_id = f.field_id
        and e.provenance_type = 'provider');
  get diagnostics edges = row_count;
  raise notice '0449: % channel-to-field edge(s) for the revived', edges;

  perform ontology.publish_version(new_version_id);
  raise notice '0449: % published', next_version;
end;
$$;

-- The refusal: no future promotion may point at a concept with no
-- active revision at the published version.
create or replace function semantic_private.guard_promotion_targets_living_concept()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.promoted_concept_id is not null
     and new.promoted_concept_id is distinct from old.promoted_concept_id
     and not exists (
       select 1 from ontology.concept_revisions r
        join ontology.versions v on v.id = r.ontology_version_id
       where r.concept_id = new.promoted_concept_id
         and r.status = 'active' and v.status = 'published')
  then
    raise exception 'promotion targets a concept with no active revision at the published version — revive it first, in your own words';
  end if;
  return new;
end;
$function$;

drop trigger if exists presumed_terms_guard_promotion_target
  on semantic_private.presumed_terms;
create trigger presumed_terms_guard_promotion_target
  before update of promoted_concept_id on semantic_private.presumed_terms
  for each row
  execute function semantic_private.guard_promotion_targets_living_concept();

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0449: the withdrawn revive with current support; promotions refuse graves');
end;
$$;

commit;
