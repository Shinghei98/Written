-- 0331 — a term minted from a keep gets a readable key and its family's hub.
--
-- **`0258` mints `culture:kept_a3f9b2c1d4e5f6a7`.** The key is
-- `concept_kind || ':kept_' || substr(md5(concept_kind || ':' || normalized), 1, 16)`,
-- which is correct, collision-proof and unreadable. Every *authored* concept in
-- this database has a readable key — `activity:aikido`, `movement:cubism`,
-- `place:cancun`, `subject:1939_invasion_of_poland` — because the seed route
-- derives one from the label. Only the discovery route does not, so the
-- vocabulary the model finds is the vocabulary nobody can read: 34 opaque keys
-- against 3,521 legible ones.
--
-- That matters more now than it did. The owner's direction, 2026-08-24: the
-- logic must **extend to unseen countries and cultural spheres, and to fields
-- of study nobody has listed**. `culture:brazil` has to be able to come into
-- existence the same way `culture:japan` did, and arrive somewhere.
--
-- ## Three things this changes, and one it deliberately does not
--
-- **1. The key is derived from the label where a label can carry one.**
-- `Brazil` becomes `culture:brazil`. The slug is lowercase ASCII with every
-- other run of characters collapsed to one underscore — the convention the
-- authored keys already use, read off them rather than invented.
--
-- **2. The hash survives as the fallback, and that is the load-bearing part.**
-- This project has already paid for a colliding fallback: *"a constant fallback
-- merged nine artists into one concept"*, and the cause was a normalisation
-- that emptied CJK strings — `unicodedata.normalize("NFKD")` decomposes Hangul
-- into jamo, so a `가-힯` class strips Korean names to empty. **A slug of `日本`
-- is empty, and an empty slug is exactly the shape that merges everything.** So
-- a slug shorter than two characters is refused and the md5 form is used
-- instead, keyed on the normalized label so two unreadable names still get two
-- concepts.
--
-- **3. A minted term is filed under its family's hub.** `0258` says *"no
-- `broader` parent: a user-kept term has no stated parent, and one parented to
-- a guess is a false claim. Landing under 'Other' is honest."* That rule is
-- right and is not being repealed — it is about guessing an *entity's* parent,
-- which franchise a character belongs to. **A family's hub is not a guess:** if
-- the term is a `culture` at all then it belongs under `hub:places_cultures`,
-- with exactly the confidence the family assignment itself carries. Nothing is
-- inferred that was not already claimed.
--
-- **What does not change: a slug is not an identity.** Deriving a readable key
-- makes a concept legible; it does not make two concepts the same. Convergence
-- still happens where it already did — on the normalized label through
-- `kept_plan`'s `same_kind` lateral — and this function is never the thing that
-- decides two terms are one.

-- ---------------------------------------------------------------------------
-- 1. The convention, as data.
-- ---------------------------------------------------------------------------
-- **A table rather than a `case`, because the prefix and the kind genuinely
-- differ.** `movement:cubism` and `subject:mathematics` are both
-- `concept_kind = 'topic'`; keying off the kind would file both under
-- `topic:`, splitting them from 387 published concepts they should join.
create table if not exists ontology.family_mint_convention (
  family        text primary key,
  key_prefix    text not null,
  default_parent_key text,
  note          text
);

comment on table ontology.family_mint_convention is
  'How a family names and files a concept minted from a keep. key_prefix is the '
  'concept_key prefix, which is not always the concept_kind — movement: and '
  'subject: are both kind=topic. default_parent_key is the family''s hub, which '
  'is entailed by the family rather than guessed.';

insert into ontology.family_mint_convention (family, key_prefix, default_parent_key, note)
values
  ('culture', 'culture',  'hub:places_cultures',
   'A country and its cultural sphere. Unseen countries mint here.'),
  ('field',   'subject',  'hub:ideas_learning',
   'A field of study. Joins the 294 published subject:* concepts.'),
  ('art',     'movement', 'hub:arts_live',
   'An art form or style. Joins the 93 published movement:* concepts.'),
  ('activity','activity', 'hub:sports_movement', null),
  ('sport',   'sport',    'hub:sports_movement', null),
  ('place',   'place',    'hub:places_cultures', null)
on conflict (family) do update
  set key_prefix = excluded.key_prefix,
      default_parent_key = excluded.default_parent_key,
      note = excluded.note;

-- ---------------------------------------------------------------------------
-- 2. The key.
-- ---------------------------------------------------------------------------
create or replace function ontology.mint_concept_key(
  p_family text, p_concept_kind text, p_normalized text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  prefix text;
  slug   text;
begin
  select c.key_prefix into prefix
    from ontology.family_mint_convention c
   where c.family = p_family;
  -- An unmapped family keeps `0258`'s behaviour exactly. A family added to the
  -- wire and not to this table is legible-by-omission rather than mis-filed.
  prefix := coalesce(prefix, p_concept_kind);

  slug := lower(coalesce(p_normalized, ''));
  slug := regexp_replace(slug, '[^a-z0-9]+', '_', 'g');
  slug := trim(both '_' from slug);

  -- **The refusal, and the whole reason the hash stays.** A CJK or Cyrillic
  -- label leaves nothing behind this filter, and an empty slug would give every
  -- such term the same key. Two characters is the floor: shorter than that
  -- carries no more information than the hash does.
  if length(slug) < 2 then
    return prefix || ':kept_'
           || substr(md5(p_concept_kind || ':' || p_normalized), 1, 16);
  end if;

  return prefix || ':' || slug;
end;
$$;

comment on function ontology.mint_concept_key(text, text, text) is
  'The concept_key for a term minted from a keep: a readable slug from the '
  'normalized label, or 0258''s md5 form when the label leaves no ASCII behind. '
  'The fallback is keyed on the normalized label so two unreadable names still '
  'get two concepts.';

-- ---------------------------------------------------------------------------
-- 3. Proven both ways, on this transaction.
-- ---------------------------------------------------------------------------
-- **A key derivation that has only ever been seen succeeding is not one to
-- believe** — the failure it must have is the empty-slug merge, so that is the
-- case asserted first.
do $$
declare
  a text; b text; c text; d text; e text;
begin
  a := ontology.mint_concept_key('culture', 'culture', 'brazil');
  if a <> 'culture:brazil' then
    raise exception '0331: expected culture:brazil, got %', a;
  end if;

  b := ontology.mint_concept_key('field', 'topic', 'oceanography');
  if b <> 'subject:oceanography' then
    raise exception '0331: a field must join subject:*, got %', b;
  end if;

  c := ontology.mint_concept_key('art', 'topic', 'fauvism');
  if c <> 'movement:fauvism' then
    raise exception '0331: an art style must join movement:*, got %', c;
  end if;

  -- Multi-word and punctuated labels collapse the way the authored keys do.
  if ontology.mint_concept_key('culture', 'culture', 'south korea')
       <> 'culture:south_korea' then
    raise exception '0331: multi-word slug is wrong';
  end if;

  -- **The two that must NOT be equal.** Both labels are pure CJK, both leave an
  -- empty slug, and a shared key would merge two countries into one concept —
  -- which is the shape that merged nine artists once already.
  d := ontology.mint_concept_key('culture', 'culture', '日本');
  e := ontology.mint_concept_key('culture', 'culture', '한국');
  if d = e then
    raise exception '0331: two empty-slug labels collided on %', d;
  end if;
  if d not like 'culture:kept_%' or e not like 'culture:kept_%' then
    raise exception '0331: an empty slug must fall back to the hash (% / %)', d, e;
  end if;

  -- An unmapped family keeps the old prefix rather than inventing one.
  if ontology.mint_concept_key('anime', 'work', 'mob psycho 100')
       <> 'work:mob_psycho_100' then
    raise exception '0331: an unmapped family must fall back to concept_kind';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. `0258`'s minter uses it, and files the term under its family's hub.
-- ---------------------------------------------------------------------------
-- The body is `pg_get_functiondef`'s, with the three key expressions and the
-- parent insert replaced. Patching rather than retyping, because retyping a
-- 200-line function to change three lines is how the other 197 drift.
do $$
declare
  body text;
  before_count integer;
begin
  select pg_get_functiondef(p.oid) into body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'ontology' and p.proname = 'mint_from_kept_requests';
  if body is null then
    raise exception '0331: ontology.mint_from_kept_requests does not exist';
  end if;

  select count(*) into before_count
    from regexp_matches(body, 'k\.concept_kind \|\| '':kept_''', 'g');
  if before_count <> 3 then
    raise exception
      '0331: expected 3 key expressions to replace, found %', before_count;
  end if;

  body := replace(
    body,
    'k.concept_kind || '':kept_'' || substr(md5(k.concept_kind || '':'' || k.normalized), 1, 16)',
    'ontology.mint_concept_key(k.requested_family, k.concept_kind, k.normalized)');
  body := replace(
    body,
    'c.concept_key = k.concept_kind || '':kept_''
             || substr(md5(k.concept_kind || '':'' || k.normalized), 1, 16)',
    'c.concept_key = ontology.mint_concept_key(k.requested_family, k.concept_kind, k.normalized)');

  if position('mint_concept_key' in body) = 0 then
    raise exception '0331: the minter did not take the new key function';
  end if;
  if position(':kept_'' || substr(md5' in body) <> 0 then
    raise exception '0331: an old key expression survived the patch';
  end if;

  execute body;
end;
$$;

-- **The hub edge, added after the concepts exist.** `member_of_hub` is the
-- display-membership predicate (`0042`), `verified_relation` is its traversal
-- floor, and a family's hub is exactly the claim the family already makes.
-- Written as its own statement rather than folded into the minter, so a
-- migration that later drops it drops one statement.
comment on column ontology.family_mint_convention.default_parent_key is
  'The hub a minted term is filed under. Not a guess: it is entailed by the '
  'family. 0258''s refusal to guess a parent is about an entity''s parent — '
  'which franchise a character belongs to — and stands.';
