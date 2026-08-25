-- 0342 — every person is one kind of person, or is not minted.
--
-- **The owner's rule, 2026-08-25:** an accepted person maps onto exactly one
-- of a closed subtype list — most representative wins where several fit — and
-- a person fitting none is not minted. Twelve subtypes, amended by the owner
-- from the original nine to cover lanes the wire already has (books, art
-- movements) and the Cao Cao case already in the corpus.
--
-- **Why a closed enum and not another rule.** The occupation-soup measured on
-- the v19 proposal pass — "Singers", "Musicians", "Chinese actors",
-- "K-pop artists", ~14 of 39 would-mint headings — exists because occupation
-- has nowhere to live, so the model smuggles it out as fake parent headings.
-- This session's evidence on the mechanism is one-sided: every
-- enum-constrained choice held (families, the 15-hub enum, candidate ids)
-- and every free-text instruction failed, five separate times. The subtype is
-- grammar, not nouns — the same closed-grammar/open-nouns rule that produced
-- the 18 families.
--
-- **What the subtype is not.** Not a family (the wire's 18 stand), and never
-- a parent: Jay Chou stays under `genre:mandopop` with `music_performer` as a
-- facet beside the parent. A `broader` edge to an occupation would be exactly
-- the heading-soup this closes.
--
-- **Null is the held-pending state, and the keep route is not gated.** A
-- person fitting no subtype keeps a null and is excluded from any autonomous
-- mint — counted, never silently dropped, and mintable without re-extraction
-- if the list later grows. A human's explicit keep outranks a model's missing
-- subtype per the Qwen-lane authority order, so `mint_from_kept_requests`
-- is deliberately untouched.

alter table semantic_private.presumed_terms
  add column if not exists person_subtype text
    check (person_subtype is null or person_subtype in (
      'actor',            -- film / TV / stage
      'music_performer',  -- singers, idols, instrumentalists, conductors
      'composer',         -- writes the music, whoever performs it
      'director',         -- film / TV / stage direction
      'streamer',         -- live platforms
      'content_creator',  -- YouTube / Instagram / TikTok
      'athlete',
      'comedian',
      'character',        -- a person from a created piece; not a real human
      'author',           -- book / audiobook / blog
      'artist',           -- visual art: the Monet case
      'historical_figure' -- the Cao Cao case
    )),
  add column if not exists person_subtype_source text
    check (person_subtype_source is null
           or person_subtype_source in ('model_pass', 'authored'));

-- **The pair moves together.** A subtype with no source is a claim nobody
-- made; a source with no subtype is a record of nothing.
alter table semantic_private.presumed_terms
  add constraint presumed_terms_subtype_pair_check
  check ((person_subtype is null) = (person_subtype_source is null));

comment on column semantic_private.presumed_terms.person_subtype is
  'Exactly one of the owner''s twelve closed person kinds (2026-08-25), or '
  'null for a person no kind fits — held unminted, not refused, so the list '
  'can grow without re-extraction. A facet beside the parent, never a parent: '
  'occupation as a heading is the soup this column exists to end.';

comment on column semantic_private.presumed_terms.person_subtype_source is
  'model_pass (the narrow enum question) or authored. The keep route stays '
  'ungated either way: a human decision outranks a missing model answer.';

-- The mint-gate's index: persons still waiting for a kind.
create index if not exists presumed_terms_person_unsubtyped_idx
  on semantic_private.presumed_terms (normalized_label)
  where family = 'person' and person_subtype is null;

-- ---------------------------------------------------------------------------
-- Proven both ways, rolled back by raising
-- ---------------------------------------------------------------------------
do $$
declare
  accepted boolean := false;
  refused  boolean := false;
begin
  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin,
       person_subtype, person_subtype_source)
    values ('0342 probe ok', '0342 probe ok', 'person', 'extracted',
            'music_performer', 'model_pass');
    accepted := true;
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then null;
    when check_violation then
      raise exception '0342: a valid subtype was refused';
  end;

  -- A subtype off the list is unwritable — "singer", the soup's favourite
  -- spelling, is deliberately the probe value.
  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin,
       person_subtype, person_subtype_source)
    values ('0342 probe bad', '0342 probe bad', 'person', 'extracted',
            'singer', 'model_pass');
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when check_violation then refused := true;
    when sqlstate 'P0001' then null;
  end;
  if not accepted then
    raise exception '0342: the subtype columns rejected a valid row';
  end if;
  if not refused then
    raise exception '0342: an off-list subtype was accepted';
  end if;

  -- And the pair rule: a subtype with no source must be refused.
  refused := false;
  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin, person_subtype)
    values ('0342 probe pair', '0342 probe pair', 'person', 'extracted',
            'composer');
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when check_violation then refused := true;
    when sqlstate 'P0001' then null;
  end;
  if not refused then
    raise exception '0342: a subtype with no source was accepted';
  end if;
end;
$$;
