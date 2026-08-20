-- 0284 — every term enters the dictionary, and nothing ever leaves it.
--
-- The owner's directive: **we are dictionary building.** Every term the model
-- proposes — extracted from the text or inferred from what it knows — is a
-- *presumed* term. It is created once, globally, validated by users, and never
-- deleted; its confidence rises as more people allow it and falls as more
-- strike it. Luffy enters the dictionary, One Piece enters the dictionary, and
-- the relation between them is recorded rather than guessed at later.
--
-- ## Why a new table rather than a wider `provisional_entities`
--
-- `provisional_entities` looks like it could hold a global row —
-- `scope in ('user','shared')` and the check is a biconditional, so
-- `('shared', null)` passes. It cannot, and the reason is four tables away:
-- `mention_resolutions`, `user_term_candidates`, `user_term_suppressions` and
-- one more all reference it by the composite key `(id, user_id)`, which is the
-- pattern this schema uses to *prove* a child belongs to the same account as
-- its parent. A row with `user_id is null` satisfies none of them, and
-- `provisional_entities_live_identity_idx` is `where scope = 'user'`, so a
-- global row would also have no identity at all. Relaxing four composite keys
-- to buy one column is the wrong trade: the per-user provisional stays exactly
-- as it is, and points at its dictionary entry.
--
-- ## What a presumed term is, and is not
--
-- It is **vocabulary**: a name, a family, and how to say it in English. That is
-- the thing `2026-08-13` settled is not API Data, which is what lets a term
-- first seen in one person's library be a word the dictionary knows. It is
-- **not evidence**: no observation, no user, no source row hangs off it. Who
-- saw it stays in `provisional_entities`, per user, under that source's own
-- retention and display rules, exactly as before.
--
-- ## English first, original beside it
--
-- `english_label` and `original_label` are separate columns rather than one
-- formatted string, because "Jay Chou (周杰倫)" is a rendering and renderings
-- belong where something is drawn. Storing the join would make the two
-- unrecoverable from each other the first time a surface wanted them apart.

create table if not exists semantic_private.presumed_terms (
  id uuid primary key default extensions.gen_random_uuid(),

  -- The identity. `normalize_text`'s fold, produced in Python and stored, for
  -- the same reason `catalogue.py` normalises there: Postgres cannot reproduce
  -- a Unicode-category fold.
  normalized_label text not null check (length(btrim(normalized_label)) > 0),
  family text not null check (family in (
    'activity','album','anime','book','channel','culture','event','event_type',
    'franchise','game','game_category','group','hub','idea','music_recording',
    'music_work','organization','person','place','platform','sport','tour','work'
  )),

  -- What to call it. `canonical_label` is the form first seen;
  -- `english_label` is the English name and `original_label` the
  -- original-language one, either of which may be absent until a model call
  -- supplies it.
  canonical_label text not null check (length(btrim(canonical_label)) > 0),
  english_label text,
  original_label text,
  locale text not null default 'und',

  -- **Extracted or inferred, recorded rather than inferred later.** An
  -- extracted term was a substring of the source; an inferred one is the
  -- model's own knowledge. Both are presumed and both are kept, but a reader
  -- must be able to tell them apart — a dictionary that forgets which of its
  -- entries were read and which were recalled cannot be audited.
  origin text not null check (origin in ('extracted', 'inferred')),

  -- Where it has been seen. An array because the same word arrives from more
  -- than one lane and the dictionary holds one entry, not one per source.
  source_lanes text[] not null default '{}',

  -- Null until the term's weight clears the bar and it becomes shared
  -- vocabulary. The owner's decision: a keep gives that person their Memory at
  -- once, and the ontology reflects agreement rather than one voice.
  promoted_concept_id uuid references ontology.concepts(id) on delete restrict,
  promoted_at timestamptz,

  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),

  constraint presumed_terms_promotion_check
    check ((promoted_concept_id is null) = (promoted_at is null))
);

-- **One entry per name and family.** Two people meeting the same word meet the
-- same row, which is the whole of what makes a cross-user weight possible.
create unique index if not exists presumed_terms_identity_idx
  on semantic_private.presumed_terms (normalized_label, family);

create index if not exists presumed_terms_unpromoted_idx
  on semantic_private.presumed_terms (family)
  where promoted_concept_id is null;

comment on table semantic_private.presumed_terms is
  'The dictionary. Every model-proposed term, extracted or inferred, global, '
  'never deleted, weighted by the users who keep and strike it (0284).';

-- **Never deleted, and the trigger is the only thing that can say so.** There
-- is no account to cascade from — a presumed term belongs to nobody — so
-- unlike `mint_requests` this needs no erasure exception. A term whose only
-- sightings are erased keeps its entry and loses its evidence, which is the
-- correct shape: the word was still a word.
create or replace function semantic_private.presumed_terms_no_delete()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  raise exception 'presumed terms are a dictionary; weight one down, never delete it';
end;
$$;

drop trigger if exists presumed_terms_no_delete on semantic_private.presumed_terms;
create trigger presumed_terms_no_delete
  before delete on semantic_private.presumed_terms
  for each row execute function semantic_private.presumed_terms_no_delete();

alter table semantic_private.presumed_terms enable row level security;

grant select, insert, update on semantic_private.presumed_terms to semantic_worker;
revoke all on semantic_private.presumed_terms from anon, authenticated, semantic_ingestor;

-- ---------------------------------------------------------------------------
-- The per-user provisional points at its dictionary entry.
-- ---------------------------------------------------------------------------
--
-- Nothing about `provisional_entities` changes but this column: its scope, its
-- identity index and all four composite foreign keys stay exactly as they are.
-- The per-user row remains what it always was — this person's unresolved noun
-- — and now names the global word it is an instance of.

alter table semantic_private.provisional_entities
  add column if not exists presumed_term_id uuid
    references semantic_private.presumed_terms(id) on delete restrict;

create index if not exists provisional_entities_presumed_term_idx
  on semantic_private.provisional_entities (presumed_term_id)
  where presumed_term_id is not null;

-- **The 991 already here enter the dictionary too**, because "every term
-- enters the internal table" is not a rule that starts today. 850 distinct
-- labels across two accounts, none of them shared — so this creates 850-odd
-- entries and proves nothing about agreement yet, which is the honest state.
do $$
declare
  created integer;
  linked integer;
begin
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, origin, source_lanes, first_seen_at)
  select p.normalized_label, p.family,
         min(p.canonical_label),
         -- Everything that exists today was a substring of its source: the
         -- validator has never permitted anything else.
         'extracted',
         '{}'::text[],
         min(p.created_at)
    from semantic_private.provisional_entities p
   group by p.normalized_label, p.family
  on conflict (normalized_label, family) do nothing;
  get diagnostics created = row_count;

  update semantic_private.provisional_entities p
     set presumed_term_id = t.id
    from semantic_private.presumed_terms t
   where t.normalized_label = p.normalized_label
     and t.family = p.family
     and p.presumed_term_id is null;
  get diagnostics linked = row_count;

  raise notice '0284: % dictionary entries, % provisionals linked', created, linked;
end;
$$;

do $$
declare
  orphaned integer;
begin
  -- Every provisional now names a dictionary entry, or the backfill missed a
  -- shape and the next one would inherit the gap silently.
  select count(*) into orphaned
    from semantic_private.provisional_entities where presumed_term_id is null;
  if orphaned > 0 then
    raise exception '0284: % provisional(s) reached no dictionary entry', orphaned;
  end if;

  -- And the dictionary refuses deletion, over a real row when one exists.
  if exists (select 1 from semantic_private.presumed_terms) then
    begin
      delete from semantic_private.presumed_terms
       where id = (select id from semantic_private.presumed_terms limit 1);
      raise exception '0284: a dictionary entry was deleted';
    exception when raise_exception then
      if position('never delete it' in sqlerrm) = 0 then
        raise;
      end if;
    end;
  end if;
end;
$$;
