-- 0051 — the registry and the record must accept the same key versions.
--
-- `0050` wrote `key_version` with the pattern `^[a-z0-9][a-z0-9_.:-]{0,63}$`.
-- `0046` wrote `raw_source_records.encryption_key_version`, which *names* that
-- version, with `^[a-z0-9][a-z0-9_.-]{0,63}$`. The difference is one character:
-- the registry accepts a colon and the record does not.
--
-- Measured rather than reasoned about, against production:
--
--     candidate     registry (0050)   record (0046)
--     v1            true              true
--     v1.2          true              true
--     2026-08-10    true              true
--     v1:2026       true              **false**
--
-- So a key could be created, used to encrypt, and then be unstorable on the
-- very row that has to name it — and the refusal would arrive at ingestion
-- time, one layer and one service away from the mistake. This is the codebase's
-- own "two columns that accept the same words" defect with the sign flipped:
-- two columns that must accept the same words accepting different ones.
--
-- **`0046` wins, and that direction is not arbitrary.** It is an adapted
-- reference migration; widening its vocabulary to admit a colon would diverge
-- from the contract to accommodate a character nothing needs. `0050` was the
-- one that invented something.
--
-- Safe to do at all only because of a fact that expires: `user_encryption_keys`
-- is empty, in production and everywhere else, and nothing writes it yet. The
-- day Phase 1's ingestion Lambda writes the first row, tightening a constraint
-- stops being free.
--
-- Ships no product behaviour.

begin;

-- The table is empty, so this validates against nothing and cannot fail on
-- data. Dropped and recreated rather than altered because a check constraint
-- has no in-place edit.
alter table semantic_private.user_encryption_keys
  drop constraint if exists user_encryption_keys_version_v031_check;

alter table semantic_private.user_encryption_keys
  add constraint user_encryption_keys_version_v031_check
  check (key_version ~ '^[a-z0-9][a-z0-9_.-]{0,63}$');

-- A belt-and-braces assertion that the two patterns now agree, run at migration
-- time against the catalog rather than trusted from the text above. If somebody
-- later edits one of the two, this migration replayed will say so.
--
-- Compares the *rendered* constraint bodies for the substring each pattern
-- occupies, which is the only place the vocabulary is written down.
do $$
declare
  registry_pattern text;
  record_pattern text;
begin
  select substring(pg_get_constraintdef(oid) from '~ ''(\^\[a-z0-9\][^'']*)''')
    into registry_pattern
    from pg_constraint
   where conname = 'user_encryption_keys_version_v031_check'
     and conrelid = 'semantic_private.user_encryption_keys'::regclass;

  select substring(pg_get_constraintdef(oid) from
           'encryption_key_version ~ ''(\^\[a-z0-9\][^'']*)''')
    into record_pattern
    from pg_constraint
   where conname = 'raw_source_records_token_fields_check'
     and conrelid = 'semantic_private.raw_source_records'::regclass;

  if registry_pattern is null or record_pattern is null then
    raise exception
      'could not read both key-version patterns (registry=%, record=%)',
      registry_pattern, record_pattern;
  end if;

  if registry_pattern is distinct from record_pattern then
    raise exception
      'key-version vocabularies disagree: registry % vs record %',
      registry_pattern, record_pattern;
  end if;
end
$$;

commit;
