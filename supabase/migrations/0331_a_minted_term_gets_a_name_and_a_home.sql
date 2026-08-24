-- 0331 — a term minted from a keep gets a readable key, in one language.
--
-- **`0258` mints `culture:kept_a3f9b2c1d4e5f6a7`.** Every *authored* concept in
-- this database has a readable key — `activity:aikido`, `movement:cubism`,
-- `place:cancun` — because the seed route derives one from the label. Only the
-- discovery route does not, so the vocabulary the model finds is the vocabulary
-- nobody can read: 34 opaque keys against 3,521 legible ones.
--
-- The owner's direction, 2026-08-24: the logic must **extend to unseen
-- countries and cultural spheres, and to fields of study nobody has listed**.
-- `culture:brazil` has to be able to come into existence the way `culture:japan`
-- did, and arrive somewhere.
--
-- ## The hard half is not the readable key
--
-- **1. One country must not become two concepts.** A slug taken from whatever
-- label happened to be kept splits every term across the languages it was seen
-- in:
--
--     Japan  -> culture:japan     日本   -> culture:kept_a9c2518d…
--     France -> culture:france    França -> culture:fran_a
--
-- The `França` case is the worse one: `fran_a` looks like a key and is wrong,
-- where the hash at least looks like a hash. So the key is taken from the
-- **English identity** where one exists — the same decision
-- `ris_emit_dictionary` already makes, keying on `english_key` because
-- *"`路人超能100`, whose English identity *is* `Mob Psycho 100`"*. That identity
-- lives on `presumed_terms.english_label`; `provisional_entities`, which the
-- minter joins, has no such column, which is why this reaches for the
-- dictionary rather than adding one.
--
-- **2. Accents fold; other scripts do not.** `normalize(…, NFKD)` separates a
-- Latin letter from its mark so the mark can be deleted, giving `franca` rather
-- than `fran_a`. It does **not** rescue CJK or Hangul, and it must not pretend
-- to: NFKD decomposes Hangul into jamo, and this project has already paid for a
-- normalisation that emptied CJK strings — *"a constant fallback merged nine
-- artists into one concept"*. Jamo and ideographs survive the fold, fail the
-- `[a-z0-9]` filter, and leave an empty slug.
--
-- **3. An empty slug is the shape that merges everything**, so it is refused. A
-- slug under two characters falls back to `0258`'s md5 form, keyed on the
-- normalized label, so two unreadable names still get two concepts.
--
-- ## And a family's hub is not a guess
--
-- `0258` says *"no `broader` parent: a user-kept term has no stated parent, and
-- one parented to a guess is a false claim."* That is about an **entity's**
-- parent — which franchise a character belongs to. A family's hub is entailed
-- by the family assignment itself: if the term is a `culture` at all it belongs
-- under `hub:places_cultures`. Nothing is inferred that was not already claimed.

-- ---------------------------------------------------------------------------
-- 1. The convention, as data.
-- ---------------------------------------------------------------------------
-- **A table rather than a `case`, because the prefix and the kind genuinely
-- differ.** `movement:cubism` and `subject:mathematics` are both
-- `concept_kind = 'topic'`; keying off the kind would file both under `topic:`,
-- splitting them from 387 published concepts they should join.
create table if not exists ontology.family_mint_convention (
  family             text primary key,
  key_prefix         text not null,
  concept_kind       text not null,
  default_parent_key text,
  note               text
);

comment on table ontology.family_mint_convention is
  'How a family names, types and files a concept minted from a keep. key_prefix '
  'is not always concept_kind — movement: and subject: are both kind=topic. '
  'default_parent_key is the family''s hub, entailed by the family rather than '
  'guessed.';

-- **No grant, and that is `cardinal_root_map`'s posture rather than an
-- omission.** That table has no grantees either: `semantic_worker` cannot read
-- it, and the only thing that needs this one is
-- `semantic_private.mint_from_kept_requests`, which is `security definer` owned
-- by `postgres`. `on all tables` binds at execution time, so a table added here
-- gets nothing unless this migration says so — and this one deliberately says
-- nothing.

insert into ontology.family_mint_convention
  (family, key_prefix, concept_kind, default_parent_key, note)
values
  ('culture', 'culture',  'topic', 'hub:places_cultures',
   'A country and its cultural sphere. Unseen countries mint here.'),
  ('field',   'subject',  'topic', 'hub:ideas_learning',
   'A field of study. Joins the 294 published subject:* concepts.'),
  ('art',     'movement', 'topic', 'hub:arts_live',
   'An art form or style. Joins the 93 published movement:* concepts.'),
  ('activity','activity', 'activity', 'hub:sports_movement', null),
  ('sport',   'sport',    'activity', 'hub:sports_movement', null),
  ('place',   'place',    'place', 'hub:places_cultures', null)
on conflict (family) do update
  set key_prefix = excluded.key_prefix,
      concept_kind = excluded.concept_kind,
      default_parent_key = excluded.default_parent_key,
      note = excluded.note;

-- ---------------------------------------------------------------------------
-- 2. The slug, and the two things it must refuse.
-- ---------------------------------------------------------------------------
create or replace function ontology.mint_slug(p_label text)
returns text
language sql
immutable
set search_path = ''
as $$
  -- Fold the mark off a Latin letter, then delete the marks, then collapse
  -- everything else. Order matters: replacing the mark instead of deleting it
  -- is what turns `França` into `fran_a`.
  select btrim(
           regexp_replace(
             regexp_replace(
               normalize(lower(coalesce(p_label, '')), NFKD),
               U&'[\0300-\036F]', '', 'g'),
             '[^a-z0-9]+', '_', 'g'),
           '_');
$$;

comment on function ontology.mint_slug(text) is
  'A readable key fragment, or something shorter than two characters when the '
  'label carries no Latin letters. Accents fold; CJK and Hangul do not, and '
  'must not — the caller treats a short slug as no slug.';

create or replace function ontology.mint_concept_key(
  p_family text, p_concept_kind text, p_normalized text,
  p_english_label text default null)
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
    from ontology.family_mint_convention c where c.family = p_family;
  -- An unmapped family keeps `0258`'s prefix exactly. A family added to the
  -- wire and not to this table is legible-by-omission rather than mis-filed.
  prefix := coalesce(prefix, p_concept_kind);

  -- **The English identity first.** `日本` and `Japan` are one country, and the
  -- key is the place that has to agree.
  slug := ontology.mint_slug(p_english_label);
  if length(slug) < 2 then
    slug := ontology.mint_slug(p_normalized);
  end if;

  -- **The refusal the fallback exists for.** An empty slug would give every
  -- CJK-labelled term the same key; the md5 form is keyed on the normalized
  -- label so two unreadable names still get two concepts.
  if length(slug) < 2 then
    return prefix || ':kept_'
           || substr(md5(p_concept_kind || ':' || p_normalized), 1, 16);
  end if;

  return prefix || ':' || slug;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Proven both ways, on this transaction.
-- ---------------------------------------------------------------------------
-- **A key derivation seen only succeeding is not one to believe.** The failure
-- it must have is the empty-slug merge, so that is asserted first.
do $$
declare d text; e text;
begin
  if ontology.mint_concept_key('culture','topic','brazil') <> 'culture:brazil' then
    raise exception '0331: culture:brazil';
  end if;
  if ontology.mint_concept_key('field','topic','oceanography') <> 'subject:oceanography' then
    raise exception '0331: a field must join subject:*';
  end if;
  if ontology.mint_concept_key('art','topic','fauvism') <> 'movement:fauvism' then
    raise exception '0331: an art style must join movement:*';
  end if;
  if ontology.mint_concept_key('culture','topic','south korea') <> 'culture:south_korea' then
    raise exception '0331: multi-word slug';
  end if;

  -- Accents fold rather than becoming separators.
  if ontology.mint_concept_key('culture','topic','frança') <> 'culture:franca' then
    raise exception '0331: França folded to %',
      ontology.mint_concept_key('culture','topic','frança');
  end if;

  -- **The English identity wins, which is what stops one country becoming two.**
  if ontology.mint_concept_key('culture','topic','日本','Japan') <> 'culture:japan' then
    raise exception '0331: the English identity did not win';
  end if;
  if ontology.mint_concept_key('culture','topic','日本','Japan')
     <> ontology.mint_concept_key('culture','topic','japan') then
    raise exception '0331: 日本 and Japan did not converge';
  end if;

  -- **And with no English identity they must still not collide.** Both labels
  -- are pure CJK and both leave an empty slug; a shared key would merge two
  -- countries, which is the shape that merged nine artists once already.
  d := ontology.mint_concept_key('culture','topic','日本');
  e := ontology.mint_concept_key('culture','topic','한국');
  if d = e then
    raise exception '0331: two empty-slug labels collided on %', d;
  end if;
  if d not like 'culture:kept_%' or e not like 'culture:kept_%' then
    raise exception '0331: an empty slug must fall back to the hash (% / %)', d, e;
  end if;

  -- An unmapped family keeps the old prefix rather than inventing one.
  if ontology.mint_concept_key('anime','work','mob psycho 100') <> 'work:mob_psycho_100' then
    raise exception '0331: an unmapped family must fall back to concept_kind';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The minter takes the key, the kind, and the English identity.
-- ---------------------------------------------------------------------------
-- The body is `pg_get_functiondef`'s with four expressions replaced. Patching
-- rather than retyping, because retyping 200 lines to change four is how the
-- other 196 drift.
do $$
declare
  body text;
  keys integer;
begin
  select pg_get_functiondef(p.oid) into body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private' and p.proname = 'mint_from_kept_requests';
  if body is null then
    raise exception '0331: semantic_private.mint_from_kept_requests does not exist';
  end if;

  select count(*) into keys
    from regexp_matches(body, 'k\.concept_kind \|\| '':kept_''', 'g');
  if keys <> 3 then
    raise exception '0331: expected 3 key expressions, found %', keys;
  end if;

  -- **The family -> kind `case` was a third statement of the family map, and it
  -- disagreed with the other two.** It still named `idea`, which no longer
  -- exists, and knew neither `art` nor `field` — so a kept art term fell to
  -- `else 'work'` and would have minted as a work. It reads the convention
  -- table now, which is the same source `mint_concept_key` uses, so the two
  -- cannot part again.
  body := replace(body,
    E'case r.requested_family\n             when ''person'' then ''creator'' when ''group'' then ''creator''\n             when ''organization'' then ''creator''\n             when ''sport'' then ''activity'' when ''activity'' then ''activity''\n             when ''idea'' then ''topic'' when ''culture'' then ''topic''\n             when ''event'' then ''topic''\n             else ''work''\n           end as concept_kind',
    E'coalesce(\n             (select fc.concept_kind from ontology.family_mint_convention fc\n               where fc.family = r.requested_family),\n             case r.requested_family\n               when ''person'' then ''creator'' when ''group'' then ''creator''\n               when ''organization'' then ''creator''\n               when ''event'' then ''topic''\n               else ''work''\n             end) as concept_kind');

  -- The English identity, from the dictionary the provisional has no column for.
  body := replace(body,
    'left join semantic_private.provisional_entities p
        on p.id = r.provisional_entity_id',
    'left join semantic_private.provisional_entities p
        on p.id = r.provisional_entity_id
      left join lateral (
        select pt.english_label
          from semantic_private.presumed_terms pt
         where pt.normalized_label = coalesce(p.normalized_label,
                 lower(regexp_replace(btrim(r.requested_label), ''\s+'', '' '', ''g'')))
           and pt.family = r.requested_family
         limit 1
      ) ident on true');

  body := replace(body, 'r.requested_label, r.requested_family, r.origin,',
                        'r.requested_label, r.requested_family, r.origin, ident.english_label,');

  body := replace(body,
    'k.concept_kind || '':kept_'' || substr(md5(k.concept_kind || '':'' || k.normalized), 1, 16)',
    'ontology.mint_concept_key(k.requested_family, k.concept_kind, k.normalized, k.english_label)');
  body := replace(body,
    'c.concept_key = k.concept_kind || '':kept_''
             || substr(md5(k.concept_kind || '':'' || k.normalized), 1, 16)',
    'c.concept_key = ontology.mint_concept_key(k.requested_family, k.concept_kind, k.normalized, k.english_label)');

  if position('mint_concept_key' in body) = 0 then
    raise exception '0331: the minter did not take the new key function';
  end if;
  if position(':kept_'' || substr(md5' in body) <> 0 then
    raise exception '0331: an old key expression survived the patch';
  end if;
  if position('family_mint_convention' in body) = 0 then
    raise exception '0331: the minter did not take the convention table';
  end if;
  if position('''idea''' in body) <> 0 then
    raise exception '0331: the minter still names idea';
  end if;

  execute body;
end;
$$;
