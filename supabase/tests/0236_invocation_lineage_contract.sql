-- 0236 — an invocation item is append-only, attributable, and cannot carry
-- mentions it did not earn.
--
-- Nothing writes these rows yet, which is why the properties are asserted now:
-- every one of them is latent while the table is empty and load-bearing the
-- moment a gateway fills it.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice   uuid := '00000000-0000-4000-8000-00000000a11c';
  call_id uuid;
  first   uuid;
  raised  boolean;
  n       integer;
  columns text;
begin
  insert into auth.users (id, email) values (alice, 'alice@example.invalid')
  on conflict (id) do nothing;

  insert into semantic_private.model_invocations
    (user_id, input_hash, model_id, model_revision, prompt_version,
     grammar_version, output_schema_hash, batch_items, status, model_lane_mode)
  values (alice, 'probe-input', 'Qwen/Qwen3.5-9B', 'probe-rev',
          'qwen_extractor_v5', 'semantic_grammar_v3', repeat('0', 64), 1,
          'succeeded', 'evaluation')
  returning id into call_id;

  -- ---------------------------------------------------------------------
  -- 1. Only a succeeded item may carry mentions
  -- ---------------------------------------------------------------------
  -- The storage half of the rule the wire validator already enforces: a
  -- structural failure is not evidence about a person, and neither is an
  -- abstention.
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, logical_extraction_key, outcome,
       mention_count)
    values (call_id, 0, alice, 'probe:timeout', 'timeout', 2);
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: a timed-out item carried mentions';
  end if;

  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, logical_extraction_key, outcome,
       mention_count)
    values (call_id, 0, alice, 'probe:abstained', 'semantic_abstention', 1);
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: an abstention carried mentions';
  end if;

  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, logical_extraction_key, outcome,
     mention_count, fingerprint_key_version, input_fingerprint)
  values (call_id, 0, alice, 'probe:work', 'succeeded', 3,
          'lineage-v1', '\x0102'::bytea)
  returning id into first;

  -- ---------------------------------------------------------------------
  -- 2. A fingerprint names the key that made it
  -- ---------------------------------------------------------------------
  -- An unsalted digest of a low-entropy title is a cross-account correlation
  -- handle. A keyed one that cannot say which key is the same thing with a
  -- longer name.
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, logical_extraction_key, outcome,
       input_fingerprint)
    values (call_id, 1, alice, 'probe:unkeyed', 'schema_invalid', '\x03'::bytea);
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: a fingerprint was stored with no key version';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. One standing success per logical extraction
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, logical_extraction_key, outcome)
    values (call_id, 2, alice, 'probe:work', 'succeeded');
  exception when unique_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: the same work succeeded twice';
  end if;

  -- A failed attempt at the same work is not a duplicate; it is what a retry
  -- ancestry is made of.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, logical_extraction_key, outcome,
     attempt, parent_item_id)
  values (call_id, 3, alice, 'probe:work', 'output_overflow', 2, first);

  -- ---------------------------------------------------------------------
  -- 4. A retry is a later attempt
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, logical_extraction_key, outcome,
       attempt, parent_item_id)
    values (call_id, 4, alice, 'probe:first-attempt', 'timeout', 1, first);
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: a first attempt claimed a parent';
  end if;

  -- ---------------------------------------------------------------------
  -- 5. An item about an observation is an item about somebody
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, observation_id, logical_extraction_key, outcome)
    values (call_id, 5, extensions.gen_random_uuid(), 'probe:ownerless', 'timeout');
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: an observation-scoped item named no user';
  end if;

  -- ---------------------------------------------------------------------
  -- 6. Append-only
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    update semantic_private.model_invocation_items
       set outcome = 'timeout' where id = first;
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: an outcome was rewritten after the fact';
  end if;

  raised := false;
  begin
    delete from semantic_private.model_invocation_items where id = first;
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: an invocation item was deleted';
  end if;

  -- ---------------------------------------------------------------------
  -- 7. No column here may hold provider text
  -- ---------------------------------------------------------------------
  -- The allowlist lives in the contract rather than the migration, because a
  -- later column is a decision somebody should have to make here — and an
  -- allowlist frozen inside an applied migration could never be updated.
  select string_agg(column_name, ', ' order by column_name) into columns
    from information_schema.columns
   where table_schema = 'semantic_private'
     and table_name = 'model_invocation_items'
     and column_name not in (
       'id', 'invocation_id', 'item_index', 'user_id', 'observation_id',
       'source_text_evidence_id', 'source_revision', 'logical_extraction_key',
       'attempt', 'parent_item_id', 'outcome', 'mention_count',
       'estimated_output_tokens', 'actual_output_tokens', 'input_fingerprint',
       'output_fingerprint', 'fingerprint_key_version', 'created_at');
  if columns is not null then
    raise exception
      '0236 contract: unreviewed columns on model_invocation_items: %. No column '
      'here may hold a prompt, title, description, response body or provider '
      'error message; if the new one cannot, add it to this allowlist.', columns;
  end if;

  -- ---------------------------------------------------------------------
  -- 8. Account deletion takes the lineage
  -- ---------------------------------------------------------------------
  -- The append-only guard permits the cascade once the owner is gone, which is
  -- 0204's shape: refuse while the owner exists, permit once they do not.
  delete from auth.users where id = alice;
  select count(*) into n from semantic_private.model_invocation_items
   where user_id = alice;
  if n <> 0 then
    raise exception '0236 contract: % invocation items survived the account', n;
  end if;

  raise notice '0236 contract: invocation lineage is append-only and attributable';
end;
$$;

rollback;
