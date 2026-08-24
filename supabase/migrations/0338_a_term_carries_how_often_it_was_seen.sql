-- 0338 — the dictionary records its own evidence.
--
-- **The emitter has always counted and never written the number.**
-- `ris_emit_dictionary.py` keeps `record["mentions"]` while it reads the corpus
-- and then discards it: `presumed_terms` has eighteen columns and not one of
-- them says how often a term was seen. `presumed_term_relations` has
-- `observed_count`; the table it points into has no equivalent.
--
-- **So the database cannot tell these apart**, measured on David's run:
--
--     LE SSERAFIM   group 154   franchise   3
--     BABYMONSTER   group 102   franchise  14
--     Jay Chou      person 11   group       1
--     JO YURI       person 31   work        1
--
-- Two rows each, equal standing, and **903 of 1,382 rows (65%) rest on a single
-- mention.** While nothing promoted that was untidy. The owner's direction of
-- 2026-08-24 makes discovery mint into the global catalogue, and untidy becomes
-- permanent: a stray `group` reading of a solo artist would be vocabulary every
-- future user resolves against.
--
-- ## Two counts, because they answer different questions
--
-- **`mention_support` is how many times the model said it. `entry_support` is
-- how many library items said it**, and the second is the one the owner
-- specified: *"For each entry (1 music entry, 1 youtube entry) dedup is applied
-- so Jay Chou and hair white like snow are only each tallied once."*
--
-- They differ, and the difference is exactly the noise: **260 of 3,728
-- (term, item) pairs are tallied more than once within a single item** — the
-- model emitting one surface twice from one title, which is also how
-- `Jay Chou/group` came to exist at all. Counting mentions rewards a model that
-- repeats itself; counting entries counts the library.
--
-- ## `family_support_share` is derived, and stored anyway
--
-- This row's entries as a fraction of every entry naming the same normalized
-- label, across families. `LE SSERAFIM/franchise` reads about 0.02; a term with
-- one uncontested family reads 1.0. It could be computed on read, and is stored
-- because **the load that wrote it is the only thing that saw the whole corpus**
-- — a later reader sees the dictionary after other loads have merged into it,
-- and would compute a different number from the same rows.
--
-- **Nothing is gated on it here.** This migration makes the evidence legible;
-- what refuses to mint on thin evidence is a separate decision with its own
-- migration, and stating a threshold in the same change that first measures it
-- is how a bar gets fitted to its own library.

alter table semantic_private.presumed_terms
  add column if not exists mention_support integer not null default 0
    check (mention_support >= 0),
  add column if not exists entry_support integer not null default 0
    check (entry_support >= 0),
  add column if not exists family_support_share numeric
    check (family_support_share is null
           or family_support_share between 0 and 1);

comment on column semantic_private.presumed_terms.mention_support is
  'How many mentions across every load named this (label, family). Counts the '
  'model''s repetitions: 260 of 3,728 term-item pairs in the RIS v17 corpus '
  'were emitted twice from one item.';

comment on column semantic_private.presumed_terms.entry_support is
  'How many distinct library items named it — deduped per entry, which is the '
  'count the owner specified on 2026-08-24. This is the evidence figure; '
  'mention_support is kept beside it because their divergence measures how '
  'much the model repeats itself.';

comment on column semantic_private.presumed_terms.family_support_share is
  'This row''s entries over all entries naming the same normalized label in any '
  'family, as the writing load saw it. Stored rather than derived because only '
  'the load that wrote it saw the whole corpus at once.';

-- **A partial index on the thin rows, because they are what a mint gate will
-- ask for**, and 65% of the table qualifies today.
create index if not exists presumed_terms_thin_evidence_idx
  on semantic_private.presumed_terms (family, entry_support)
  where entry_support <= 1;

-- ---------------------------------------------------------------------------
-- Proven both ways
-- ---------------------------------------------------------------------------
-- **The bound is the only rule here, so it is the one made to answer twice.**
-- The probe rolls back by raising rather than by deleting: `presumed_terms` is
-- append-only by trigger, and a probe that tidies up against
-- `presumed_terms_no_delete` fails for a reason that has nothing to do with
-- what it was testing.
do $$
declare
  accepted boolean := false;
  refused  boolean := false;
begin
  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin,
       mention_support, entry_support, family_support_share)
    values ('0338 probe ok', '0338 probe ok', 'person', 'extracted',
            12, 11, 0.9167);
    accepted := true;
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then null;
    when check_violation then
      raise exception '0338: a valid support row was refused';
  end;

  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin,
       mention_support, entry_support, family_support_share)
    values ('0338 probe bad', '0338 probe bad', 'person', 'extracted',
            12, 11, 1.4);
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when check_violation then refused := true;
    when sqlstate 'P0001' then null;
  end;

  if not accepted then
    raise exception '0338: the support columns rejected a valid row';
  end if;
  if not refused then
    raise exception '0338: a family share above 1 was accepted';
  end if;

  -- **A negative count must be refused too**, since the emitter will write
  -- these from arithmetic and a subtraction that goes wrong should stop at the
  -- door rather than read as a term nobody has ever seen.
  refused := false;
  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin, entry_support)
    values ('0338 probe neg', '0338 probe neg', 'person', 'extracted', -1);
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when check_violation then refused := true;
    when sqlstate 'P0001' then null;
  end;
  if not refused then
    raise exception '0338: a negative entry_support was accepted';
  end if;
end;
$$;

-- **The existing 10,578 rows keep 0, and that is a true statement rather than a
-- backfill.** Nothing recorded how often those terms were seen, so no number
-- can be recovered for them; the next emission of the same corpus writes the
-- real figure. Defaulting them to 1 would have invented evidence, which is the
-- failure this column exists to prevent.
do $$
declare
  n integer;
begin
  select count(*) into n from semantic_private.presumed_terms
   where entry_support = 0;
  raise notice
    '0338: % rows carry no support yet; re-emission fills them, backfill would invent them', n;
end;
$$;
