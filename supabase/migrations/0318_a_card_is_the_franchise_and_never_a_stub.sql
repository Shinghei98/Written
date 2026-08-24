-- 0318 — a card is the franchise, and a stub is never a card.
--
-- Two rules join `review_item_is_coarse`, which `0302` last wrote. Both are
-- about what reaches the review surface; neither changes what is stored, what
-- is scored, or what any other lane may read.
--
-- **A term nothing named is not a card.** `0284`'s `origin` distinguishes a
-- term somebody's library attested (`extracted`) from one inferred as the
-- object of a relation (`inferred`) — a franchise known only because a
-- character of it was seen. The RIS load minted every relation object
-- `extracted`, so 693 unlabelled `franchise` rows and 1,465 unlabelled
-- `person` rows became cards showing raw text. `0317` fixes the origin going
-- forward; this refuses the card regardless, so a stub arriving by any route
-- stays out.
--
-- **A character's card is its franchise.** The standing rule is "One Piece not
-- Luffy, Final Fantasy not FF VI", and the owner restated it directly: a
-- character is a `person`, that person is a character in a franchise, and the
-- card shows the franchise only. So a candidate whose term has a
-- `part_of_franchise` edge to a franchise that is itself card-worthy is
-- suppressed, and the franchise's own card carries the evidence.
--
-- **This is the first thing ever to read `presumed_term_relations`, and that
-- is a deliberate amendment to `0306`.** That migration built the table inert
-- and said its safety rested on nothing reading it. What is licensed here is
-- exactly and only this: **one hop, for display, to decide whether a card is
-- drawn.** Not traversal, not propagation, not inference — nothing here
-- promotes a relation into the ontology, changes a score, or makes an edge
-- traversable for any other purpose. The `0306` invariant otherwise stands.
--
-- **Three properties the edges lack, and how each is handled.** They have no
-- version pin, no cycle guard beyond self-edges, and no single-parent
-- guarantee. One hop needs no cycle guard and no tie-break: the question is
-- only *does a qualifying parent exist*, which is a boolean and cannot loop.
-- The version pin is answered by the qualification test below rather than by a
-- snapshot.
--
-- **What qualifies a franchise, and why "has a label" does not.** `k-pop` has
-- 226 distinct subjects, `classical` 142, `pop` 54 — the model uses
-- `part_of_franchise` for genres as readily as for franchises, and every one
-- of those is labelled. The test is that the object must not be an **axis**:
-- a genre, era, sphere or scene. Those already exist as ontology vocabulary
-- with reserved key prefixes, and `score.py`'s `NEVER_ASSERTED_KEY_PREFIXES`
-- and `0197`'s allowlist both say the same thing from their own side — an era
-- is an axis, a scene is a claim, and neither is a thing a card is about.
-- **And the vocabulary was already there.** The first reading of this was that
-- `k-pop` and `music` needed adding as concepts — a new ontology version for
-- two rows. They exist: `genre:k_pop` carries `k pop` and `kpop`, and `music`
-- is `hub:music`. What was missing is that the two vocabularies normalise
-- differently, `k-pop` against `k pop`. Folding hyphens on both sides answers
-- all seven containers this corpus surfaced — k-pop, classical, mandopop,
-- pop, cantopop, anime, music — and publishes nothing.

create or replace function semantic_private.review_item_is_coarse(p_candidate_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce((
    select case
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
                  -- the corpus — 226 subjects — read as a franchise, and it
                  -- would have been answered by publishing a new ontology
                  -- version for vocabulary that already existed.
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

  -- The branches 0283 and 0302 put here must survive every later edit; each
  -- one silently widens the surface if it is lost, and a card that should not
  -- have been drawn raises nothing.
  if body not like '%canonical_term_id is not null%' then
    raise exception '0318: the variant branch is gone';
  end if;
  if body not like '%music_work%' then
    raise exception '0318: the granular-family branch is gone';
  end if;
  if body not like '%origin = ''inferred''%' then
    raise exception '0318: the stub branch this migration adds is not there';
  end if;
  if body not like '%part_of_franchise%' then
    raise exception '0318: the franchise branch this migration adds is not there';
  end if;
  if body not like '%(genre|era|sphere|scene|hub):%' then
    raise exception '0318: the axis exclusion is gone, so a genre could be a franchise';
  end if;
  if body not like '%translate(%' then
    raise exception
      '0318: the axis comparison stopped folding hyphens, so k-pop reads as a franchise';
  end if;

  raise notice '0318: a stub is not a card, and a character shows its franchise';
end;
$$;
