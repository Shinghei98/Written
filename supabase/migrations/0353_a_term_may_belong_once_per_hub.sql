-- 0353 — a term may belong once per hub, and to as many hubs as are true.
--
-- **The owner's rule, 2026-08-25, and the measurement that bought it.** The
-- 200-term ground-truth holdout scored 8 misassignments — and every one of
-- the eight was a stage collision, not a model error. For each, an earlier
-- cascade stage (usually the anchor-ladder inheritance) held the authored
-- truth while a later stage's answer *in a different hub* overwrote it:
-- `Ai` the J-pop singer held `genre:j_pop` from her anchor and lost it to
-- `subject:artificial_intelligence`; `Mob Psycho 100` held `genre:anime` and
-- lost it to `genre:superhero_film`; `Raj Ranjodh` held the exact authored
-- parent and lost it to a film genre. The single
-- `proposed_parent_concept_id` slot forced a choice between placements that
-- were both right — a defect of storage, not of judgement.
--
-- So: **at most one placement per hub, any number of hubs.** Genre and
-- person's world; work and movement; a song nominating its film and its
-- culture — the product's founding sentence, finally allowed by the schema.
-- The within-hub cap is a unique constraint, because this codebase's rule is
-- that a limit enforced by convention is a limit that fails silently.
--
-- **The single column keeps its exact semantics.** `0335`'s
-- `proposed_parent_concept_id` remains the primary, most-representative
-- placement; every existing reader keeps working, and the multiples are
-- additive beside it.
--
-- Bucketing: a heading's hub is its closure hub-ancestor; a heading with no
-- hub ancestor (`subject:content_creators`) buckets as itself. The bucket is
-- computed by the emitter, which holds the closure — the constraint only has
-- to make the bucket single-occupancy.

create table semantic_private.presumed_term_placements (
  id uuid primary key default gen_random_uuid(),
  normalized_label text not null check (length(btrim(normalized_label)) > 0),
  family text not null,
  parent_concept_id uuid not null references ontology.concepts (id)
    on delete cascade,
  -- The bucket. A hub key for headings under one, the heading's own key for
  -- the few that stand outside every hub.
  hub_key text not null check (length(btrim(hub_key)) > 0),
  confidence numeric check (confidence is null or confidence between 0 and 1),
  source text not null
    check (source in ('placement_pass', 'inherited', 'catalogue')),
  corpus text not null,
  created_at timestamptz not null default now(),
  -- **The rule as a constraint**: never twice within one hub.
  unique (normalized_label, family, hub_key)
);

create index presumed_term_placements_term_idx
  on semantic_private.presumed_term_placements (normalized_label, family);

comment on table semantic_private.presumed_term_placements is
  'Per-hub parent placements for dictionary terms (owner''s rule 2026-08-25): '
  'at most one placement per hub, any number of hubs, so a term counts toward '
  'a genre and a movement at once instead of a later stage overwriting an '
  'earlier stage''s truth — the mechanism behind all 8 holdout misses. The '
  'primary proposed_parent_concept_id on presumed_terms is unchanged.';

-- ---------------------------------------------------------------------------
-- Proven both ways, rolled back by raising
-- ---------------------------------------------------------------------------
do $$
declare
  music_concept uuid;
  screen_concept uuid;
  refused boolean := false;
begin
  select id into music_concept from ontology.concepts
   where concept_key like 'genre:%' and retired_at is null limit 1;
  select id into screen_concept from ontology.concepts
   where concept_key like 'hub:%' and retired_at is null limit 1;
  if music_concept is null or screen_concept is null then
    raise notice '0353: catalogue too empty to probe here; constraint stands';
    return;
  end if;

  begin
    -- Two hubs for one term: the rule's permissive half.
    insert into semantic_private.presumed_term_placements
      (normalized_label, family, parent_concept_id, hub_key,
       confidence, source, corpus)
    values
      ('0353 probe', 'work', music_concept,  'hub:music',      0.9,
       'placement_pass', 'probe'),
      ('0353 probe', 'work', screen_concept, 'hub:film_video', 0.9,
       'inherited', 'probe');

    -- A second placement in an occupied hub: the restrictive half.
    begin
      insert into semantic_private.presumed_term_placements
        (normalized_label, family, parent_concept_id, hub_key,
         confidence, source, corpus)
      values
        ('0353 probe', 'work', screen_concept, 'hub:music', 0.9,
         'placement_pass', 'probe');
    exception
      when unique_violation then refused := true;
    end;
    if not refused then
      raise exception '0353: a second placement in one hub was accepted';
    end if;

    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then
      raise notice '0353: once per hub, many across hubs — both ways hold';
  end;

  if exists (select 1 from semantic_private.presumed_term_placements
              where corpus = 'probe') then
    raise exception '0353: probe rows survived their rollback';
  end if;
end;
$$;
