-- 0321 — one spelling, one cluster.
--
-- `0320` grouped rows that were *not yet variants*, and that is the wrong unit.
-- `海賊王` has two rows: the `franchise` one already points at `one piece`, so
-- it was excluded from the grouping, leaving `海賊王/work` alone in a group of
-- one and untouched. Same for `路人超能100/anime`, whose `franchise` sibling had
-- already merged into `mob psycho 100`. Both still rendered raw.
--
-- **The unit is the cluster, not the row.** A spelling is settled when every
-- row carrying it resolves to one `coalesce(canonical_term_id, id)`. Where a
-- spelling resolves to two or more, the smaller clusters point at the best of
-- them — and because `0301`'s trigger re-points followers, a whole cluster
-- moves when its head does.
--
-- The choice among cluster heads is `0320`'s and unchanged: a row somebody's
-- library named, then one carrying an English label, then family rank, then
-- the family name so a replay chooses identically. Not highest-family, which
-- picks the stub a relation object minted.

do $$
declare
  linked integer := 0;
  leftover integer;
begin
  with clusters as (
    select pt.normalized_label,
           coalesce(pt.canonical_term_id, pt.id) as cluster_id
      from semantic_private.presumed_terms pt
     group by 1, 2),
  split as (
    select normalized_label from clusters group by 1 having count(*) > 1),
  best as (
    select distinct on (c.normalized_label)
           c.normalized_label, c.cluster_id
      from clusters c
      join split s on s.normalized_label = c.normalized_label
      join semantic_private.presumed_terms head on head.id = c.cluster_id
     order by c.normalized_label,
              case when head.origin = 'extracted' then 0 else 1 end,
              case when head.english_label is not null then 0 else 1 end,
              case head.family
                when 'person' then 0 when 'group' then 0
                when 'franchise' then 1 when 'organization' then 1
                when 'event' then 2 when 'activity' then 3
                when 'anime' then 4 when 'book' then 4
                when 'game' then 4 when 'work' then 5
                when 'music_work' then 6 when 'album' then 7
                else 8 end,
              head.family),
  written as (
    insert into semantic_private.presumed_term_links
      (variant_term_id, canonical_term_id, basis, evidence)
    select pt.id, b.cluster_id, 'authored',
           jsonb_build_object('source', '0321', 'rule', 'one spelling one cluster')
      from semantic_private.presumed_terms pt
      join best b on b.normalized_label = pt.normalized_label
     -- Only a row whose cluster differs, and never the head itself: the
     -- trigger refuses a self-link as a sever, which would undo the merge
     -- this is making.
     where coalesce(pt.canonical_term_id, pt.id) <> b.cluster_id
       and pt.id <> b.cluster_id
    returning 1)
  select count(*) into linked from written;

  raise notice '0321: % rows moved onto their spelling''s cluster', linked;

  -- **Assert the transformation.** A replay has no dictionary and settles
  -- nothing, which is correct; what must not survive is a spelling that still
  -- resolves two ways, since that is exactly the state `路人超能100` was in.
  select count(*) into leftover
    from (select pt.normalized_label
            from semantic_private.presumed_terms pt
           group by pt.normalized_label
          having count(distinct coalesce(pt.canonical_term_id, pt.id)) > 1) x;
  if leftover > 0 then
    raise exception '0321: % spellings still resolve more than one way', leftover;
  end if;
end;
$$;
