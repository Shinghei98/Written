-- 0272 — a kept term reaches the genre its evidence states.
--
-- Every term the owner kept landed under "Other" at the bottom of Memories.
-- The keep path is the only minting path in this repository that writes a
-- concept, a revision and labels and then stops: `concept_block` climbs
-- `broader` to find a section, and with no edge it answers null and the client
-- calls that group "Other". Nine kept concepts, zero edges between them.
--
-- `0258:216` made that deliberate: *"a user-kept term has no stated parent,
-- and one parented to a guess is a false claim."* The sentence is right and
-- its premise is wrong. **Apple states the genre on the very observations that
-- attest the term** — `normalized_payload -> 'genres'`, present on 3,778 of
-- one account's 4,285 apple_music rows — and reading it is the same act the
-- genre rollup already calls `provider_metadata` (`0220`). There is no guess
-- to make when the row carries the answer. Measured over the nine: four state
-- `Classical`, four `Soundtrack`, one `K-Pop`, and each names a genre concept
-- that already exists.
--
-- **Where the parent comes from, and what is not added.** The worker resolves
-- it and passes it in: stated string -> `english_genre` -> `normalize_text` ->
-- the resolver's own `SELECT_GENRE_CONCEPTS` join, the most specific of several
-- read off the graph by depth, `mint_genres_from_stated_strings` (`0191`) for a
-- string the vocabulary cannot yet name, and the source's own hub as the floor.
-- **No label-to-genre table exists anywhere in that chain and none is created
-- here.** The fold is in Python because `normalize_text` is a Unicode-category
-- operation Postgres cannot reproduce — the reason `catalogue.py` already
-- normalises there and joins on the stored value. This function still performs
-- every write: the trusted catalogue layer allocates identities, and nothing
-- upstream of it chooses an id.
--
-- **Patched from the deployed definition rather than restated.** The body is
-- two hundred lines that `0258` and `0260` between them got right; a hand-typed
-- copy drifts, and the first draft of this migration proved it by quietly
-- changing two clauses. Every replacement below is anchored on text asserted to
-- exist, and the signature change is why it is `drop` and `execute` rather than
-- `create or replace` — that would overload, and an ambiguity Postgres refuses
-- with 42725 from inside the worker fails the mint rather than the call.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.mint_from_kept_requests()'::regprocedure);

  -- 1. The signature gains the resolved parents.
  patched := replace(body,
    'FUNCTION semantic_private.mint_from_kept_requests()',
    'FUNCTION semantic_private.mint_from_kept_requests(p_parents jsonb default ''{}''::jsonb)');
  if patched = body then
    raise exception '0272: the mint signature is not the one 0260 published';
  end if;
  body := patched;

  -- 2. A counter for the assertion at the end.
  patched := replace(body, E'  kept record;\n', E'  kept record;\n  unparented integer := 0;\n');
  if patched = body then
    raise exception '0272: the declare block is not the one 0260 published';
  end if;
  body := patched;

  -- 3. Each pending request carries the parent its evidence named. Null where
  --    the source said nothing this vocabulary can name — reported by the
  --    assertion below rather than left to float silently.
  patched := replace(body,
    E'      from semantic_private.mint_requests r\n',
    E'           , nullif(p_parents ->> r.id::text, '''')::uuid as parent_concept_id\n'
    || E'      from semantic_private.mint_requests r\n');
  if patched = body then
    raise exception '0272: the requests CTE is not the one 0260 published';
  end if;
  body := patched;

  -- 4. The edge that stops it floating, written in the same version as the
  --    concept. `provider`, because the genre is Apple's statement about the
  --    material rather than anything this system worked out; the provenance
  --    names the request, so a reader can trace a section to the row behind it.
  patched := replace(body,
    E'    perform ontology.publish_version(new_version_id);\n',
    E'    insert into ontology.concept_edges (\n'
    || E'      ontology_version_id, subject_concept_id, predicate_key, object_concept_id,\n'
    || E'      confidence, provenance_type, provenance, status)\n'
    || E'    select distinct on (c.id)\n'
    || E'           new_version_id, c.id, ''broader'', k.parent_concept_id,\n'
    || E'           1.0, ''provider'',\n'
    || E'           jsonb_build_object(''source'', ''0272_kept_term_parent'',\n'
    || E'                              ''mint_request_id'', k.request_id),\n'
    || E'           ''active''\n'
    || E'      from kept_plan k\n'
    || E'      join ontology.concepts c\n'
    || E'        on c.concept_key = k.concept_kind || '':kept_''\n'
    || E'             || substr(md5(k.concept_kind || '':'' || k.normalized), 1, 16)\n'
    || E'     where k.disposition = ''mint''\n'
    || E'       and k.parent_concept_id is not null\n'
    || E'    on conflict do nothing;\n\n'
    || E'    perform ontology.publish_version(new_version_id);\n\n'
    || E'    select count(*) into unparented\n'
    || E'      from kept_plan k\n'
    || E'      join ontology.concepts c\n'
    || E'        on c.concept_key = k.concept_kind || '':kept_''\n'
    || E'             || substr(md5(k.concept_kind || '':'' || k.normalized), 1, 16)\n'
    || E'     where k.disposition = ''mint''\n'
    || E'       and semantic_private.concept_block(c.id, new_version_id) is null;\n'
    || E'    if unparented > 0 then\n'
    || E'      raise exception\n'
    || E'        ''mint_from_kept_requests: % kept concept(s) reach no block and would land under Other'',\n'
    || E'        unparented;\n'
    || E'    end if;\n');
  if patched = body then
    raise exception '0272: the publish step is not where 0260 put it';
  end if;
  body := patched;

  drop function semantic_private.mint_from_kept_requests();
  execute body;
end;
$$;

revoke all on function semantic_private.mint_from_kept_requests(jsonb) from public;
grant execute on function semantic_private.mint_from_kept_requests(jsonb)
  to semantic_worker;

do $$
declare
  definition text;
  n integer;
begin
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'semantic_private' and p.proname = 'mint_from_kept_requests';
  if n <> 1 then
    raise exception '0272: % mint functions exist; an overload raises 42725 at call time', n;
  end if;

  definition := regexp_replace(
    pg_get_functiondef('semantic_private.mint_from_kept_requests(jsonb)'::regprocedure),
    '--[^\n]*', '', 'g');
  if position('concept_edges' in definition) = 0 then
    raise exception '0272: the mint still writes no parent edge';
  end if;
  if position('reach no block' in definition) = 0 then
    raise exception '0272: the mint does not assert its concepts reach a block';
  end if;
  if position('p_parents' in definition) = 0 then
    raise exception '0272: the mint does not read the parents it is given';
  end if;
end;
$$;

-- **The ones already minted are repaired through the same derivation**, not by
-- a hand-written edge list and not by reopening their requests — a completed
-- mint request is immutable by trigger (`0257`), which is right: a person's
-- decision is history, and rewriting it to re-run a side effect would make the
-- ledger describe something that did not happen.
--
-- So the repair is its own function, taking parents resolved by exactly the
-- code that resolves them for a fresh keep. It touches only concepts that
-- reach no block, so it is a no-op the moment there are none — the same answer
-- on an empty replay database and on production once it has run.

create or replace function semantic_private.attach_kept_concept_parents(
  p_parents jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  current_version text;
  next_version    text;
  new_version_id  uuid;
  attached integer := 0;
  still_floating integer := 0;
begin
  if p_parents is null or p_parents = '{}'::jsonb then
    return jsonb_build_object('status', 'no_op', 'updated_count', 0);
  end if;

  select version into current_version
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception 'attach_kept_concept_parents: no published ontology version';
  end if;

  next_version := semantic_private.next_ontology_version(current_version);
  insert into ontology.versions (version, status, notes)
  values (next_version, 'draft', 'kept-term parents, derived from stated genre')
  returning id into new_version_id;

  perform ontology.copy_forward_version(
    (select id from ontology.versions where version = current_version),
    new_version_id);

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, (entry.key)::uuid, 'broader', (entry.value #>> '{}')::uuid,
         1.0, 'provider',
         jsonb_build_object('source', '0272_kept_term_parent_backfill'),
         'active'
    from jsonb_each(p_parents) as entry
   where not exists (
     select 1 from ontology.concept_edges held
      where held.ontology_version_id = new_version_id
        and held.subject_concept_id = (entry.key)::uuid
        and held.predicate_key = 'broader'
        and held.status = 'active')
  on conflict do nothing;
  get diagnostics attached = row_count;

  perform ontology.publish_version(new_version_id);

  select count(*) into still_floating
    from jsonb_each(p_parents) as entry
   where semantic_private.concept_block((entry.key)::uuid, new_version_id) is null;
  if still_floating > 0 then
    raise exception
      'attach_kept_concept_parents: % concept(s) still reach no block', still_floating;
  end if;

  return jsonb_build_object('status', 'succeeded', 'updated_count', attached);
end;
$function$;

revoke all on function semantic_private.attach_kept_concept_parents(jsonb) from public;
grant execute on function semantic_private.attach_kept_concept_parents(jsonb)
  to semantic_worker;

select semantic_private.enqueue_recompute_on_analysis_change('0272_kept_term_parent');
