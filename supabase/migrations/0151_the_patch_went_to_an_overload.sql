-- 0151 — the patch went to an overload, and the overload should not exist.
--
-- **`0150` did exactly what this codebase already has a rule against.**
-- *"`create or replace function` does not replace a function whose signature
-- changed — it overloads it."* `0064` holds an eleven-argument
-- `ingest_source_records_v031`; production runs the twelve-argument version
-- from `0062`, which carries `p_coverage`. Patching `0064`'s text therefore
-- created a second function beside the live one and put the supersede logic in
-- the copy nothing calls.
--
-- **The live path never broke**, and only because `index.mjs` passes twelve
-- explicitly cast arguments, which resolves unambiguously. An eleven-argument
-- call would have matched both and failed `42725` — from inside ingestion,
-- where the whole batch fails rather than the feature.
--
-- ## Patched from the catalog, not from a file
--
-- `0150` trusted a migration file to say what production runs, and it did not.
-- This reads `pg_get_functiondef` for the twelve-argument function, applies the
-- same five edits to *that* text, and executes the result — so the body being
-- patched is by construction the body that is live, whichever migration wrote
-- it. Every anchor is asserted present before the replacement, so a body that
-- has drifted fails here instead of silently applying four edits out of five.

begin;

-- The overload `0150` created. Named in full, because that is the only way to
-- drop one of two functions sharing a name.
drop function if exists semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, text, text, text, jsonb, jsonb, boolean);

do $migration$
declare
  src text;
  patched text;
  edits text[][] := array[
    array[
      $a$    content_lineage_hmac text
  ) on commit drop;$a$,
      $a$    content_lineage_hmac text,
    content_fingerprint text
  ) on commit drop;$a$
    ],
    array[
      $b$    element ->> 'content_lineage_hmac'
  from jsonb_array_elements(p_records) as element;$b$,
      $b$    element ->> 'content_lineage_hmac',
    element ->> 'content_fingerprint'
  from jsonb_array_elements(p_records) as element;$b$
    ],
    array[
      $c$      occurred_at, source_item_hmac, record_fingerprint,
      encryption_key_version, encrypted_payload,$c$,
      $c$      occurred_at, source_item_hmac, record_fingerprint, content_fingerprint,
      encryption_key_version, encrypted_payload,$c$
    ],
    array[
      $d$      b.record_fingerprint, p_key_version,$d$,
      $d$      b.record_fingerprint, b.content_fingerprint, p_key_version,$d$
    ],
    array[
      $e$  select count(*) into stored from inserted;$e$,
      $e$  select count(*) into stored from inserted;

  -- **A re-projection supersedes; a changed payload never does.**
  --
  -- The record fingerprint alone cannot tell the two apart, and conflating them
  -- left 550 duplicate rows nothing could safely retire: a projector bump made
  -- every re-projected row look like new data, so each inserted beside its
  -- predecessor and both stayed active.
  --
  -- The content fingerprint is the same row without the projector version, so
  -- equal content and differing record means the projection moved and the
  -- source did not. A genuine payload change moves both fingerprints, matches
  -- nothing here, and is captured beside its predecessor exactly as before.
  --
  -- Rows written before content_fingerprint existed carry null and are never
  -- matched, so nothing already stored is retired by this.
  update semantic_private.raw_source_records prior
     set lifecycle_state = 'superseded'
   where prior.user_id = p_user_id
     and prior.lifecycle_state = 'active'
     and prior.content_fingerprint is not null
     and exists (
       select 1
         from incoming_batch b
        where b.source_code = prior.source_code
          and b.source_item_hmac = prior.source_item_hmac
          and b.content_fingerprint = prior.content_fingerprint
          and b.record_fingerprint is distinct from prior.record_fingerprint
     );$e$
    ]
  ];
  edit text[];
begin
  select pg_get_functiondef(p.oid) into src
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'semantic_private'
    and p.proname = 'ingest_source_records_v031'
    and pg_get_function_arguments(p.oid) like '%p_coverage%';

  if src is null then
    raise exception 'no twelve-argument ingest_source_records_v031 to patch';
  end if;

  patched := src;
  foreach edit slice 1 in array edits loop
    -- **Asserted, not attempted.** A drifted body would otherwise take four of
    -- five edits and ship a function that reads a column it never fills.
    if position(edit[1] in patched) = 0 then
      raise exception 'anchor not found in the live body: %', left(edit[1], 60);
    end if;
    patched := replace(patched, edit[1], edit[2]);
  end loop;

  if patched = src then
    raise exception 'the patch changed nothing';
  end if;

  execute patched;
end;
$migration$;

do $$
declare
  overloads integer;
  has_supersede boolean;
begin
  select count(*) into overloads
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'semantic_private' and p.proname = 'ingest_source_records_v031';
  if overloads <> 1 then
    raise exception 'expected exactly one ingest_source_records_v031, found %', overloads;
  end if;

  select pg_get_functiondef(p.oid) like '%lifecycle_state = ''superseded''%'
    into has_supersede
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'semantic_private' and p.proname = 'ingest_source_records_v031';
  if not has_supersede then
    raise exception 'the live function does not carry the supersede';
  end if;

  raise notice '0151: one function, patched in place';
end;
$$;

commit;
