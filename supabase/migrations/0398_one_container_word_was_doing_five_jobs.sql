-- 0398 — one container word was doing five jobs.
--
-- **The owner's grammar replan, 2026-08-26.** The diagnosis (plan of
-- record: the grammar-replan section of the owner's plan file; evidence
-- queried from the dictionary itself): the extraction grammar had exactly
-- one container concept — `franchise` — and one containment predicate —
-- `part_of_franchise` — so the model filed every "X belongs to Y" as a
-- franchise whatever Y was. Groups (Brown Eyed Girls, KiiiKiii),
-- organizations (HYBE Labels), platforms (YouTube), work-cycles (Bach's
-- Violin Sonatas), performer credits (the Gardiner ensemble) and even
-- genres and eras ("Jazz", "K-Pop", "Contemporary Era") all landed in one
-- family, and every placement rule keyed on the true family found
-- `franchise` instead. The patches were correct and the grammar was wrong.
--
-- This is the reconciliation over the EXISTING dictionary — no
-- re-distillation (nobody re-distils for us). Every decision below is a
-- rule over stored evidence, never a name list:
--
--   1. **Classification objects become edges, never entities.** An
--      out-relation whose object's label uniquely names an existing genre
--      concept becomes `broader` on the subject's concept. (Thomas
--      Mulligan -> Jazz; KiiiKiii -> K-Pop.)
--   2. **A container whose label is a registered source code is the
--      platform itself** (`semantic_private.sources.source_code` — a
--      table, not a list invented here). Its concept_kind becomes
--      `organization`, which `list_assertions`' kind allowlist withholds:
--      the page exit is the existing mechanism, not a new one.
--   3. **Container type is decided by its members' families**, read off
--      the relations the model itself stated:
--        - members all persons              -> group
--        - any member a group               -> organization
--        - members works/albums + persons   -> collection (work/album)
--        - members works/albums + a group   -> franchise (the true kind)
--   4. **Placement follows the type.** Groups and franchises inherit the
--      member-majority block (>= 2/3 of placeable members, ties refuse).
--      Organizations shelve: music shelf when the member majority's block
--      climbs to hub:music, else the entertainment shelf. Collections get
--      `composed_by` to their person-member when that person files under
--      classical (the composer convention), else `performed_by`.
--   5. **The filing climb learns `composed_by`** beside `performed_by`
--      (0397's shape) so a cycle reaches its composer's genre.
--
-- Dictionary rows are retyped in place (0367's precedent) and relation
-- predicates move to the typed vocabulary — three new predicates join the
-- check constraint (0371's precedent). Ontology changes land at a new
-- version, published, and per 0396's rule the publish ends with
-- `enqueue_recompute_on_analysis_change`.

begin;

-- ---------------------------------------------------------------------
-- The typed predicates join the relation vocabulary.
-- ---------------------------------------------------------------------
alter table semantic_private.presumed_term_relations
  drop constraint presumed_term_relations_predicate_check;
alter table semantic_private.presumed_term_relations
  add constraint presumed_term_relations_predicate_check
  check (predicate = any (array[
    'part_of_franchise','features','about','performed_by','composed_by',
    'recording_of','soundtrack_of','member_of_group','played_for',
    'official_channel_of','represented_team_in','located_in','broader',
    'signed_to_label','work_in_collection','platform_of']));

-- ---------------------------------------------------------------------
-- The climb learns composed_by (0397's shape, one predicate wider).
-- ---------------------------------------------------------------------
create or replace function semantic_private.concept_block(
  target_concept_id uuid, target_version_id uuid
) returns text
language sql
stable
set search_path to ''
as $function$
  with recursive blocks(block_key, priority) as (
    values
      ('genre:anime', 1), ('genre:classical', 2), ('genre:musicals', 3),
      ('genre:k_pop', 4), ('genre:j_pop', 5), ('genre:mandopop', 6),
      ('genre:cantopop', 7), ('genre:video_game', 8), ('subject:science', 9),
      ('subject:language_learning', 10), ('hub:news_current_affairs', 11),
      ('subject:travel', 12),
      ('subject:music_labels', 13), ('subject:entertainment_labels', 14),
      ('subject:content_creators', 15)
  ),
  climb(concept_id, depth) as (
    select target_concept_id, 0
    union all
    select edge.object_concept_id, climb.depth + 1
    from climb
    join ontology.concept_edges edge
      on edge.subject_concept_id = climb.concept_id
     -- 0397: a work's performer places the work. 0398: so does its
     -- composer — the classical path. Everything else is containment.
     and edge.predicate_key in ('broader', 'performed_by', 'composed_by')
     and edge.ontology_version_id = target_version_id
     and edge.status = 'active'
    where climb.depth < 8
  )
  select coalesce(
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
       join blocks b on b.block_key = c.concept_key
      order by b.priority, climb.depth, c.concept_key
      limit 1),
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
      where c.concept_key like 'genre:%'
        and c.concept_key <> 'genre:asian_music'
      order by climb.depth, c.concept_key
      limit 1),
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
      where c.concept_key like 'hub:%'
      order by climb.depth, c.concept_key
      limit 1)
  );
$function$;

-- ---------------------------------------------------------------------
-- The reconciliation.
-- ---------------------------------------------------------------------
do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  row_c record;
  typed_group integer := 0;
  typed_org integer := 0;
  typed_platform integer := 0;
  typed_collection integer := 0;
  kept_franchise integer := 0;
  classification_edges integer := 0;
  placement_edges integer := 0;
  refused_majority integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- The stuck containers: franchise-family dictionary terms promoted to a
  -- concept that files nowhere. The test is the page's own (concept_block
  -- null), so the scope is "everything the grammar lost", not a list.
  create temporary table _containers on commit drop as
  select pt.id as term_id, pt.promoted_concept_id as concept_id,
         pt.canonical_label,
         lower(btrim(pt.canonical_label)) as norm_label
    from semantic_private.presumed_terms pt
   where pt.family = 'franchise'
     and pt.promoted_concept_id is not null
     and semantic_private.concept_block(pt.promoted_concept_id, old_version_id) is null;

  -- Member evidence per container concept: every in-relation, with the
  -- member's own family and (where promoted) the member's block.
  create temporary table _members on commit drop as
  select ct.concept_id,
         r.id as relation_id,
         spt.id as member_term_id,
         spt.family as member_family,
         spt.promoted_concept_id as member_concept_id,
         case when spt.promoted_concept_id is not null
              then semantic_private.concept_block(spt.promoted_concept_id, old_version_id)
              end as member_block
    from _containers ct
    join semantic_private.presumed_terms pt on pt.promoted_concept_id = ct.concept_id
    join semantic_private.presumed_term_relations r on r.object_term_id = pt.id
    join semantic_private.presumed_terms spt on spt.id = r.subject_term_id
   where r.predicate = 'part_of_franchise';

  -- The typing verdict, one row per container.
  create temporary table _verdicts on commit drop as
  select ct.concept_id,
         min(ct.norm_label) as norm_label,
         case
           when min(ct.norm_label) in (select source_code from semantic_private.sources)
             then 'platform'
           when bool_or(m.member_family = 'group')
                and bool_or(m.member_family in ('work','music_work','album','music_recording'))
             then 'franchise'
           when bool_or(m.member_family = 'group')
             then 'organization'
           -- Persons against works is a majority question, not any-work-wins:
           -- a group's own song points into the group (KiiiKiii), and one
           -- song must not turn a girl group into a collection.
           when count(m.relation_id) filter (where m.member_family = 'person')
                > count(m.relation_id) filter (where m.member_family in
                    ('work','music_work','album','music_recording'))
                and count(m.relation_id) filter (where m.member_family = 'person') > 0
             then 'group'
           when bool_or(m.member_family in ('work','music_work','album','music_recording'))
             then 'collection'
           else 'held'
         end as verdict
    from _containers ct
    left join _members m on m.concept_id = ct.concept_id
   group by ct.concept_id;

  -- The member-majority block per container: >= 2/3 of placeable members.
  create temporary table _majorities on commit drop as
  select concept_id, member_block as majority_block
    from (
      select m.concept_id, m.member_block,
             count(distinct m.member_concept_id) as votes,
             sum(count(distinct m.member_concept_id))
               over (partition by m.concept_id) as total,
             row_number() over (partition by m.concept_id
               order by count(distinct m.member_concept_id) desc, m.member_block) as rn
        from _members m
       where m.member_block is not null
       group by m.concept_id, m.member_block
    ) t
   where rn = 1 and votes * 3 >= total * 2;

  if not exists (select 1 from _containers) then
    raise notice '0398: no stuck franchise containers stand; the rule waits';
    return;
  end if;

  -- The new version everything below writes into.
  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Container reconciliation: the franchise family stops doing five jobs.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- Rule 1 — classification objects become edges, never entities. Scope:
  -- every blockless concept (containers and persons alike) whose stated
  -- out-relation names exactly one existing genre concept.
  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select distinct new_version_id, spt.promoted_concept_id, 'broader', g.concept_id,
         0.9, 'learned',
         jsonb_build_object('rule', '0398 classification object',
                            'stated', opt.canonical_label),
         'active'
    from semantic_private.presumed_term_relations r
    join semantic_private.presumed_terms spt on spt.id = r.subject_term_id
    join semantic_private.presumed_terms opt on opt.id = r.object_term_id
    join lateral (
      select l.concept_id
        from ontology.concept_labels l
        join ontology.concepts gc on gc.id = l.concept_id
       where l.ontology_version_id = new_version_id and l.status = 'active'
         -- 0379's normalization folds hyphens to spaces; the match folds
         -- the same way or "K-Pop" misses the label stored as "k pop".
         and l.normalized_label in (lower(btrim(opt.canonical_label)),
               replace(lower(btrim(opt.canonical_label)), '-', ' '))
         and gc.concept_key like 'genre:%'
       group by l.concept_id
      having count(*) >= 1
    ) g on true
   where spt.promoted_concept_id is not null
     and semantic_private.concept_block(spt.promoted_concept_id, old_version_id) is null
     and (select count(distinct l2.concept_id) from ontology.concept_labels l2
           join ontology.concepts gc2 on gc2.id = l2.concept_id
          where l2.ontology_version_id = new_version_id and l2.status = 'active'
            and l2.normalized_label in (lower(btrim(opt.canonical_label)),
                  replace(lower(btrim(opt.canonical_label)), '-', ' '))
            and gc2.concept_key like 'genre:%') = 1
  on conflict do nothing;
  get diagnostics classification_edges = row_count;

  -- Rules 2-4, per container.
  for row_c in
    select v.concept_id, v.norm_label, v.verdict, mj.majority_block
      from _verdicts v
      left join _majorities mj on mj.concept_id = v.concept_id
  loop
    if row_c.verdict = 'platform' then
      update ontology.concept_revisions
         set concept_kind = 'organization'
       where ontology_version_id = new_version_id
         and concept_id = row_c.concept_id and status = 'active';
      update semantic_private.presumed_terms
         set family = 'platform'
       where promoted_concept_id = row_c.concept_id and family = 'franchise';
      typed_platform := typed_platform + 1;
      raise notice '0398: % is the platform itself — withheld by kind', row_c.norm_label;

    elsif row_c.verdict = 'group' then
      update semantic_private.presumed_terms
         set family = 'group'
       where promoted_concept_id = row_c.concept_id and family = 'franchise';
      -- Person-members join the group; a work pointing into its group is
      -- the group performing it — two facts, two predicates.
      update semantic_private.presumed_term_relations r
         set predicate = 'member_of_group'
        from semantic_private.presumed_terms pt, semantic_private.presumed_terms s
       where pt.promoted_concept_id = row_c.concept_id
         and r.object_term_id = pt.id and r.predicate = 'part_of_franchise'
         and s.id = r.subject_term_id and s.family = 'person';
      update semantic_private.presumed_term_relations r
         set predicate = 'performed_by'
        from semantic_private.presumed_terms pt, semantic_private.presumed_terms s
       where pt.promoted_concept_id = row_c.concept_id
         and r.object_term_id = pt.id and r.predicate = 'part_of_franchise'
         and s.id = r.subject_term_id
         and s.family in ('work','music_work','album','music_recording');
      typed_group := typed_group + 1;
      if row_c.majority_block is not null then
        insert into ontology.concept_edges (
          ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
          confidence, provenance_type, provenance, status)
        select new_version_id, row_c.concept_id, 'broader', c.id, 0.85, 'learned',
               jsonb_build_object('rule', '0398 member majority'), 'active'
          from ontology.concepts c where c.concept_key = row_c.majority_block
        on conflict do nothing;
        placement_edges := placement_edges + 1;
      else
        refused_majority := refused_majority + 1;
        raise notice '0398: group % has no member majority — held', row_c.norm_label;
      end if;

    elsif row_c.verdict = 'organization' then
      update semantic_private.presumed_terms
         set family = 'organization'
       where promoted_concept_id = row_c.concept_id and family = 'franchise';
      update semantic_private.presumed_term_relations r
         set predicate = 'signed_to_label'
        from semantic_private.presumed_terms pt
       where pt.promoted_concept_id = row_c.concept_id
         and r.object_term_id = pt.id and r.predicate = 'part_of_franchise';
      typed_org := typed_org + 1;
      -- The shelf: music when the member majority's block climbs to
      -- hub:music, else entertainment — derived, not chosen per name.
      insert into ontology.concept_edges (
        ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
        confidence, provenance_type, provenance, status)
      select new_version_id, row_c.concept_id, 'broader', shelf.id, 0.85, 'learned',
             jsonb_build_object('rule', '0398 organization shelves'), 'active'
        from ontology.concepts shelf
       where shelf.concept_key = case
               when row_c.majority_block is not null and exists (
                 select 1 from ontology.concepts gb
                  where gb.concept_key = row_c.majority_block
                    and semantic_private.concept_block(gb.id, new_version_id) is not null
                    and exists (
                      with recursive up(cid, d) as (
                        select gb.id, 0
                        union all
                        select e.object_concept_id, up.d + 1
                          from up join ontology.concept_edges e
                            on e.subject_concept_id = up.cid
                           and e.predicate_key = 'broader'
                           and e.ontology_version_id = new_version_id
                           and e.status = 'active'
                         where up.d < 8)
                      select 1 from up join ontology.concepts hc on hc.id = up.cid
                       where hc.concept_key = 'hub:music'))
               then 'subject:music_labels'
               else 'subject:entertainment_labels' end
      on conflict do nothing;
      placement_edges := placement_edges + 1;

    elsif row_c.verdict = 'collection' then
      update semantic_private.presumed_terms
         set family = case when exists (
                select 1 from _members m where m.concept_id = row_c.concept_id
                  and m.member_family = 'album')
              then 'album' else 'work' end
       where promoted_concept_id = row_c.concept_id and family = 'franchise';
      update semantic_private.presumed_term_relations r
         set predicate = 'work_in_collection'
        from semantic_private.presumed_terms pt, semantic_private.presumed_terms s
       where pt.promoted_concept_id = row_c.concept_id
         and r.object_term_id = pt.id and r.predicate = 'part_of_franchise'
         and s.id = r.subject_term_id
         and s.family in ('work','music_work','album','music_recording');
      typed_collection := typed_collection + 1;
      -- The person-member is the collection's author: composed_by when
      -- that person files under classical (the composer convention),
      -- performed_by otherwise. One person concept, or refuse.
      insert into ontology.concept_edges (
        ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
        confidence, provenance_type, provenance, status)
      select new_version_id, row_c.concept_id,
             case when m.member_block = 'genre:classical'
                  then 'composed_by' else 'performed_by' end,
             m.member_concept_id, 0.85, 'learned',
             jsonb_build_object('rule', '0398 collection author'), 'active'
        from (select distinct member_concept_id, member_block
                from _members
               where concept_id = row_c.concept_id
                 and member_family = 'person'
                 and member_concept_id is not null) m
       where (select count(distinct member_concept_id) from _members
               where concept_id = row_c.concept_id
                 and member_family = 'person'
                 and member_concept_id is not null) = 1
      on conflict do nothing;
      if found then placement_edges := placement_edges + 1;
      else
        refused_majority := refused_majority + 1;
        raise notice '0398: collection % names no single author — held', row_c.norm_label;
      end if;

    elsif row_c.verdict = 'franchise' then
      kept_franchise := kept_franchise + 1;
      if row_c.majority_block is not null then
        insert into ontology.concept_edges (
          ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
          confidence, provenance_type, provenance, status)
        select new_version_id, row_c.concept_id, 'broader', c.id, 0.85, 'learned',
               jsonb_build_object('rule', '0398 franchise member majority'), 'active'
          from ontology.concepts c where c.concept_key = row_c.majority_block
        on conflict do nothing;
        placement_edges := placement_edges + 1;
      else
        refused_majority := refused_majority + 1;
        raise notice '0398: franchise % has no member majority — held', row_c.norm_label;
      end if;

    else
      raise notice '0398: % held — no member evidence decides its type', row_c.norm_label;
    end if;
  end loop;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': container reconciliation — '
    || typed_group || ' group(s), ' || typed_org || ' organization(s), '
    || typed_collection || ' collection(s), ' || typed_platform || ' platform(s), '
    || kept_franchise || ' franchise(s) kept, '
    || classification_edges || ' classification edge(s), '
    || placement_edges || ' placement edge(s), '
    || refused_majority || ' held');
  raise notice '0398: % published', next_version;
end;
$$;

commit;
