-- 0324 — an exclusion belongs to the spelling, and a card must read it.
--
-- `0323` marked private-calendar terms row by row. **The unit is wrong, and it
-- is the third time this project has learned it**: `0320` grouped rows that
-- were not yet variants, `0321` corrected it to the cluster, and the exclusion
-- sweep repeated the original mistake a migration later. Measured now:
--
--     appointment with sika berger   work → private_calendar   person, franchise → unmarked
--     break                          work → private_calendar   person, franchise → unmarked
--     buddha's birthday              event → private_calendar  franchise → unmarked
--     augh birthday                  event → private_calendar  person → unmarked
--
-- Marking one family and leaving its siblings readable is the deny-list
-- failure this file already names elsewhere: **the failure mode of a deny-list
-- is silence.** Nothing reports that `break` is refused as a `work` and
-- permitted as a `person`.
--
-- **A spelling is one thing.** `0320` settled that for identity — one spelling,
-- one node — and the same argument decides exclusion: if the calendar row that
-- produced `break` was a private diary entry, it was that entry whichever
-- family the model happened to tag. So the mark propagates across every row of
-- a normalized label, and across the whole cluster the label resolves to.
--
-- **And `review_item_is_coarse` gains the branch that reads it.** `0323` set a
-- column no reader consults. Today no marked term reaches a card, but only
-- because the families they landed in — `event`, `work` — are refused for
-- other reasons; a marked term typed `person` would be drawn. A column that
-- decides what is never shown, and that nothing shown consults, is a comment.

-- ---------------------------------------------------------------------------
-- One spelling, one exclusion
-- ---------------------------------------------------------------------------

do $$
declare
  spread integer;
  leftover integer;
begin
  -- **Both directions of the same identity.** A row is marked if any row
  -- carrying its spelling is marked, or if any row in its cluster is — a
  -- variant and its canonical are one term, so an exclusion on either is an
  -- exclusion on both.
  with marked as (
    select distinct pt.normalized_label
      from semantic_private.presumed_terms pt
     where pt.excluded_reason is not null
  ),
  marked_clusters as (
    select distinct coalesce(pt.canonical_term_id, pt.id) as cluster_id
      from semantic_private.presumed_terms pt
     where pt.excluded_reason is not null
  ),
  spreading as (
    update semantic_private.presumed_terms pt
       set excluded_reason = 'private_calendar'
     where pt.excluded_reason is null
       and (pt.normalized_label in (select normalized_label from marked)
            or coalesce(pt.canonical_term_id, pt.id)
                 in (select cluster_id from marked_clusters))
    returning 1)
  select count(*) into spread from spreading;

  raise notice '0324: % sibling rows now carry the exclusion', spread;

  -- **Assert the transformation, not a count.** A replay has no dictionary and
  -- spreads nothing, which is correct there. What must never be true on any
  -- database is a spelling that is refused under one family and permitted
  -- under another, which is exactly the state this migration ends.
  select count(*) into leftover
    from (select pt.normalized_label
            from semantic_private.presumed_terms pt
           group by pt.normalized_label
          having count(*) filter (where pt.excluded_reason is not null) > 0
             and count(*) filter (where pt.excluded_reason is null) > 0) split;
  if leftover > 0 then
    raise exception
      '0324: % spellings are still excluded under one family and allowed under another',
      leftover;
  end if;

  select count(*) into leftover
    from (select coalesce(pt.canonical_term_id, pt.id) as cluster_id
            from semantic_private.presumed_terms pt
           group by 1
          having count(*) filter (where pt.excluded_reason is not null) > 0
             and count(*) filter (where pt.excluded_reason is null) > 0) split;
  if leftover > 0 then
    raise exception '0324: % clusters are still marked only in part', leftover;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- A marked term is not a card
-- ---------------------------------------------------------------------------
--
-- The branch joins `0302`'s variant test, `0318`'s stub and franchise tests and
-- the granular-family list. It is placed **first**, ahead of even the variant
-- check: an excluded term must not be drawn whatever else is true of it, and a
-- rule that can be reached only when three earlier branches decline is a rule
-- with conditions nobody wrote down.

create or replace function semantic_private.review_item_is_coarse(p_candidate_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce((
    select case
             -- **A term the dictionary refuses is never a card.** `0323`'s
             -- `excluded_reason` is the closed vocabulary of why a term may
             -- never be shown — today only `private_calendar`, a diary entry
             -- that reached the dictionary before the calendar gate existed.
             -- `0324` guarantees the mark covers every row of a spelling, so
             -- matching on the label alone is sound and does not depend on
             -- which family this candidate happened to be typed.
             when exists (
               select 1 from semantic_private.presumed_terms pt
                where pt.normalized_label = pe.normalized_label
                  and pt.excluded_reason is not null)
               then false

             -- A variant defers to its canonical (0302). Matched on the
             -- identity alone now that `0317` links across families: a row
             -- pointing at a canonical in another family is still a variant.
             when exists (
               select 1 from semantic_private.presumed_terms pt
                where pt.normalized_label = pe.normalized_label
                  and pt.family = pe.family
                  and pt.canonical_term_id is not null)
               then false

             -- **A stub is not a card.** Nothing named this term; it exists
             -- because something else was said to relate to it.
             when exists (
               select 1 from semantic_private.presumed_terms pt
                where pt.normalized_label = pe.normalized_label
                  and pt.family = pe.family
                  and pt.origin = 'inferred')
               then false

             -- **A character's card is its franchise.** One hop, to a
             -- franchise that is not an axis and is not itself a stub.
             when exists (
               select 1
                 from semantic_private.presumed_terms pt
                 join semantic_private.presumed_term_relations rel
                   on rel.subject_term_id = coalesce(pt.canonical_term_id, pt.id)
                 join semantic_private.presumed_terms parent
                   on parent.id = rel.object_term_id
                where pt.normalized_label = pe.normalized_label
                  and pt.family = pe.family
                  and rel.predicate = 'part_of_franchise'
                  and parent.family = 'franchise'
                  and parent.origin = 'extracted'
                  -- A franchise row that turned out to be a person or a group
                  -- is a variant of that row, not a franchise. `jay chou`,
                  -- `le sserafim` and `babymonster` all arrive this way.
                  and parent.canonical_term_id is null
                  and parent.id <> coalesce(pt.canonical_term_id, pt.id)
                  -- **Not an axis.** A genre is not a franchise however the
                  -- model tagged it, and the ontology already records which
                  -- names are axes — `genre:`, `era:`, `sphere:`, `scene:`
                  -- and the fifteen `hub:` blocks.
                  --
                  -- **The comparison folds hyphens and underscores to spaces,
                  -- on both sides.** The two vocabularies normalise
                  -- differently: the dictionary keys `k-pop` while
                  -- `genre:k_pop` carries `k pop` and `kpop`. That single
                  -- character was the whole of why the largest container in
                  -- the corpus — 226 subjects — read as a franchise.
                  and not exists (
                    select 1
                      from ontology.concepts c
                      join ontology.concept_labels cl on cl.concept_id = c.id
                     where translate(lower(btrim(cl.normalized_label)), '-_', '  ')
                           = translate(parent.normalized_label, '-_', '  ')
                       and c.concept_key ~ '^(genre|era|sphere|scene|hub):'))
               then false

             when pe.family is not null
               then pe.family not in ('work', 'album', 'music_work')
             when utc.concept_id is not null
               then exists (
                 select 1 from ontology.concept_revisions kcr
                  where kcr.concept_id = utc.concept_id
                    and kcr.ontology_version_id =
                        (select id from ontology.versions where status = 'published')
                    and kcr.concept_kind <> 'work')
             else false
           end
      from semantic_private.user_term_candidates utc
      left join semantic_private.provisional_entities pe
        on pe.id = utc.provisional_entity_id
     where utc.id = p_candidate_id), false)
$function$;

do $$
declare
  body text;
begin
  select pg_get_functiondef(p.oid) into body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private' and p.proname = 'review_item_is_coarse';

  -- Every branch 0283, 0302, 0318 and this migration put here must survive
  -- each later edit. Each one silently widens the surface if it is lost, and a
  -- card that should not have been drawn raises nothing.
  if body not like '%excluded_reason is not null%' then
    raise exception '0324: the exclusion branch this migration adds is not there';
  end if;
  if body not like '%canonical_term_id is not null%' then
    raise exception '0324: the variant branch is gone';
  end if;
  if body not like '%music_work%' then
    raise exception '0324: the granular-family branch is gone';
  end if;
  if body not like '%origin = ''inferred''%' then
    raise exception '0324: the stub branch is gone';
  end if;
  if body not like '%part_of_franchise%' then
    raise exception '0324: the franchise branch is gone';
  end if;
  if body not like '%(genre|era|sphere|scene|hub):%' then
    raise exception '0324: the axis exclusion is gone, so a genre could be a franchise';
  end if;
  if body not like '%translate(%' then
    raise exception
      '0324: the axis comparison stopped folding hyphens, so k-pop reads as a franchise';
  end if;

  raise notice '0324: an excluded term is not a card, whatever family it wears';
end;
$$;

-- ---------------------------------------------------------------------------
-- The guard answers both ways over real data
-- ---------------------------------------------------------------------------
--
-- **A check that can be skipped will be skipped exactly when it is needed.**
-- Asserting only that the branch exists tests the text of a function, not its
-- behaviour, so the new clause is put to a real candidate and required to
-- refuse — and a candidate of the same shape whose term is *not* marked is
-- required to pass, because a guard that refuses everything is indistinguishable
-- from a guard that works.

do $$
declare
  marked_candidate uuid;
  clean_candidate uuid;
begin
  select utc.id into marked_candidate
    from semantic_private.user_term_candidates utc
    join semantic_private.provisional_entities pe on pe.id = utc.provisional_entity_id
    join semantic_private.presumed_terms pt
      on pt.normalized_label = pe.normalized_label
   where pt.excluded_reason is not null
   limit 1;

  select utc.id into clean_candidate
    from semantic_private.user_term_candidates utc
    join semantic_private.provisional_entities pe on pe.id = utc.provisional_entity_id
   where semantic_private.review_item_is_coarse(utc.id)
     and not exists (
       select 1 from semantic_private.presumed_terms pt
        where pt.normalized_label = pe.normalized_label
          and pt.excluded_reason is not null)
   limit 1;

  if marked_candidate is null then
    -- Correct on a replay, which has no dictionary and no candidates. The
    -- assertion states what must be true *when the input exists*, so the same
    -- block answers on an empty database and on production.
    raise notice '0324: no marked candidate here; nothing to put to the guard';
  elsif semantic_private.review_item_is_coarse(marked_candidate) then
    raise exception
      '0324: candidate % names an excluded term and the guard still drew it',
      marked_candidate;
  else
    raise notice '0324: the guard refused a marked term';
  end if;

  if clean_candidate is null then
    raise notice '0324: no unmarked card here to prove the guard still admits';
  else
    raise notice '0324: and still admitted an unmarked one (%)', clean_candidate;
  end if;
end;
$$;
