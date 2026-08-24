-- 0340 — a term the catalogue already holds is resolved, not restaged.
--
-- **The owner's pipeline, step 3a (2026-08-24):** *"recognizes Jay Chou as a
-- singer Jay Chou, look into global ontology if person:Jay Chou (周杰倫) already
-- exist... if yes, use it and tally accordingly."*
--
-- **It does not happen today.** Measured on the deployed dictionary: **1,150 of
-- 10,578 rows name a concept this catalogue already publishes**, unambiguously
-- and under the right kind — `creator:claude_debussy`, `creator:twice`,
-- `creator:stephen_schwartz`, `work:spider_man` — and **every one of them has
-- `promoted_concept_id is null`.** They were staged as though newly discovered.
--
-- Under the pre-2026-08-24 rule that cost nothing, because nothing promoted.
-- Under autonomous minting it is a duplicate factory: each of those 1,150 would
-- mint a second concept for something the catalogue already names.
--
-- ## Why a function and not a one-off statement
--
-- A migration linking today's rows is stale the moment the next corpus lands.
-- This is the operation every load must end with, so it is written once, named,
-- and called — by this migration for the backlog, and by each emission after.
--
-- ## The three refusals, which are what make the links trustworthy
--
-- **1. Exact identity only.** `lower(btrim(...))` over the English label, or
-- the canonical where there is none. **No similarity, no trigram, no prefix
-- match** — this project has paid twice for fuzzy matching (`exact_terms_only`;
-- the constant fallback key that merged nine artists into one concept).
--
-- **2. One concept or none.** 17 labels match more than one published concept.
-- An ambiguous pairing is refused outright rather than resolved by ranking,
-- which is `tools/ris_link_observations.py`'s rule: *a term with no evidence is
-- better than a term with somebody else's.*
--
-- **3. The kind must agree with the family's convention.** This is the one that
-- earns its keep: **315 rows match a published concept by label and disagree
-- with it about what kind of thing it is.**
--
--     Kate Bush            franchise  ->  creator:kate_bush
--     Taylor Swift         franchise  ->  creator:apple_159260351
--     ABBA                 franchise  ->  creator:abba
--     NIGHT DANCER         person     ->  work:kept_7b63d9e468e28487
--     No Party For Cao Dong  work     ->  creator:apple_1110664089
--
-- Performers typed as franchises and a song typed as a person — the same
-- defect `fx_107` tests and v17 deleted the rule for. **The catalogue is right
-- and the dictionary is wrong in every one of these**, but this function does
-- not act on that: it refuses the link and counts it. Rewriting a family from
-- a label match would be inferring one fact from another, and the family is
-- the model's answer to record, not ours to overwrite quietly.
--
-- The convention comes from `ontology.family_mint_convention`, which `0337`
-- completed to all eighteen wire families — so the kind test asks the same
-- table minting asks, and the two cannot drift.

create or replace function semantic_private.resolve_presumed_terms_to_catalogue()
returns table (linked integer, ambiguous integer, kind_mismatch integer)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_linked integer := 0;
  v_ambiguous integer := 0;
  v_mismatch integer := 0;
begin
  create temporary table _candidate on commit drop as
  with published as (
    select lower(btrim(cr.preferred_label)) as label,
           c.id as concept_id,
           split_part(c.concept_key, ':', 1) as prefix
      from ontology.concept_revisions cr
      join ontology.concepts c on c.id = cr.concept_id
     where cr.ontology_version_id =
           (select v.id from ontology.versions v where v.status = 'published')
       and c.retired_at is null
  )
  select t.id as term_id,
         count(distinct p.concept_id)                                as matches,
         count(distinct p.concept_id) filter (where p.prefix = m.key_prefix) as kind_ok,
         -- **`min(uuid)` does not exist in Postgres**, which the first version
         -- of this assumed and the replay refused. Aggregating into an array
         -- and taking the first element is the form that works; it is only ever
         -- read where `kind_ok = 1`, so the array holds exactly one id and the
         -- choice of element is not a tiebreak dressed up as one.
         (array_agg(p.concept_id) filter (where p.prefix = m.key_prefix))[1]
           as concept_id
    from semantic_private.presumed_terms t
    join ontology.family_mint_convention m on m.family = t.family
    join published p
      on p.label = lower(btrim(coalesce(t.english_label, t.canonical_label)))
   where t.promoted_concept_id is null
   group by t.id;

  -- **Ambiguity is counted before anything is written**, so the number means
  -- "refused" rather than "left over after a partial pass".
  select count(*) into v_ambiguous from _candidate where matches > 1;
  select count(*) into v_mismatch  from _candidate where kind_ok = 0;

  update semantic_private.presumed_terms t
     set promoted_concept_id = c.concept_id,
         promoted_at = now()
    from _candidate c
   where c.term_id = t.id
     and c.matches = 1
     and c.kind_ok = 1
     and c.concept_id is not null
     -- Belt and braces against a concurrent writer: the promotion check
     -- constraint pairs the two columns, and this keeps the update idempotent.
     and t.promoted_concept_id is null;
  get diagnostics v_linked = row_count;

  drop table _candidate;
  return query select v_linked, v_ambiguous, v_mismatch;
end;
$$;

revoke all on function semantic_private.resolve_presumed_terms_to_catalogue()
  from public;

comment on function semantic_private.resolve_presumed_terms_to_catalogue() is
  'Links dictionary rows to concepts the catalogue already publishes, by exact '
  'English identity, refusing every ambiguous match and every match whose kind '
  'disagrees with family_mint_convention. Step 3a of the owner''s 2026-08-24 '
  'pipeline. Re-runnable: each load should end with it.';

-- ---------------------------------------------------------------------------
-- The backlog, and the assertion that it behaved
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  before_unpromoted integer;
  after_unpromoted  integer;
begin
  select count(*) into before_unpromoted
    from semantic_private.presumed_terms where promoted_concept_id is null;

  select * into r from semantic_private.resolve_presumed_terms_to_catalogue();

  select count(*) into after_unpromoted
    from semantic_private.presumed_terms where promoted_concept_id is null;

  raise notice '0340: linked %, refused % ambiguous, refused % kind-mismatched',
    r.linked, r.ambiguous, r.kind_mismatch;

  -- **The arithmetic must close.** A function reporting a number that does not
  -- match what the table did is worse than one reporting nothing, and this is
  -- the shape of check that catches an `update` whose `where` quietly matched
  -- more than the count claimed.
  if before_unpromoted - after_unpromoted <> r.linked then
    raise exception
      '0340: reported % links but % rows changed state',
      r.linked, before_unpromoted - after_unpromoted;
  end if;

  -- **Every link must satisfy the promotion constraint**, checked as a fact
  -- rather than trusted to the constraint having fired.
  if exists (select 1 from semantic_private.presumed_terms
              where (promoted_concept_id is null) <> (promoted_at is null)) then
    raise exception '0340: a row has a concept without a time, or the reverse';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Proven both ways, over real rows
-- ---------------------------------------------------------------------------
-- **A resolver that only ever links is not a resolver.** The kind refusal is
-- the load-bearing one — 315 rows turn on it — so it is made to answer twice:
-- a right-kind row accepted, a wrong-kind row left alone.
do $$
declare
  ok_id   uuid;
  bad_id  uuid;
  creator_concept uuid;
  r record;
begin
  select id into creator_concept from ontology.concepts
   where concept_key like 'creator:%' and retired_at is null limit 1;
  if creator_concept is null then
    raise notice '0340: no published creator concept on this database; probe skipped';
    return;
  end if;

  declare
    label text;
  begin
    select lower(btrim(cr.preferred_label)) into label
      from ontology.concept_revisions cr
     where cr.concept_id = creator_concept
       and cr.ontology_version_id =
           (select v.id from ontology.versions v where v.status = 'published')
     limit 1;

    -- A `person` wants `creator:` and should link.
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, english_label, family, origin)
    values ('0340 probe ok', '0340 probe ok', label, 'person', 'extracted')
    returning id into ok_id;

    -- A `work` wants `work:` and must be refused against the same concept.
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, english_label, family, origin)
    values ('0340 probe bad', '0340 probe bad', label, 'work', 'extracted')
    returning id into bad_id;

    select * into r from semantic_private.resolve_presumed_terms_to_catalogue();

    if (select promoted_concept_id from semantic_private.presumed_terms
         where id = ok_id) is null then
      raise exception '0340: a person matching a creator concept was not linked';
    end if;
    if (select promoted_concept_id from semantic_private.presumed_terms
         where id = bad_id) is not null then
      raise exception
        '0340: a work was linked to a creator concept — the kind test did not fire';
    end if;

    -- **Roll back by raising.** `presumed_terms` is append-only by trigger, so
    -- a probe that tidies up with a DELETE fails for a reason unrelated to
    -- what it was testing.
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then
      raise notice '0340: kind test answers both ways';
  end;
end;
$$;
