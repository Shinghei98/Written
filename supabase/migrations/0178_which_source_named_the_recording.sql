-- 0178 — which source named the recording.
--
-- ## What is missing today
--
-- `0177` mints creator vocabulary from Apple's catalogue. The identifier that
-- triggers each lookup — an ISRC — comes from whichever music source the user
-- connected, and **nothing records which.** The catalogue answer is Apple's; the
-- list of what we asked about is the person's library.
--
-- ## Why it matters, and it is not mainly a legal argument
--
-- The launch plan (owner, 2026-08-14) is that Spotify is stripped until roughly
-- 250,000 active users, and that if that point is reached, vocabulary is minted
-- from Apple Music while Spotify data is only ever *read against* it — so
-- Spotify never contributes to building the shared artifact. Reading against an
-- existing vocabulary is not the restricted act; building one is.
--
-- That plan needs the system to say where each entry came from, and the
-- measurement says it will never be able to say so retroactively.
--
-- **817 distinct artists across the two accounts, 2026-08-14:**
--
-- | | artists |
-- |---|---|
-- | reachable from an Apple ISRC | 205 |
-- | reachable from a Spotify ISRC | 461 |
-- | reachable from **both** | **10** |
-- | no ISRC on either side | 141 |
--
-- **The two sets barely overlap.** Ten of 817. So an artist minted through
-- Spotify is almost never also Apple-reachable, and provenance cannot be
-- recovered later by re-deriving from Apple and seeing what matches. The answer
-- exists only at the moment of the lookup.
--
-- ## Both sources, positively — not a Spotify flag
--
-- A flag on Spotify entries answers *"was this Spotify"* and cannot answer
-- *"was this Apple"*, because an unflagged row is indistinguishable from an
-- unrecorded one. Recording both means the 205 Apple-supplied and 10
-- both-supplied artists can be positively asserted as clean, which is the
-- question the launch plan actually asks.
--
-- ## Where it is not stored, and why
--
-- Not on `ontology.external_entities`: that row is unique on
-- `(provider, external_id, payload_hash)`, so folding a source list into
-- `raw_payload` would change the hash and re-store the same catalogue answer
-- every run. `external_concept_links` has no provenance column.
--
-- **No user id.** This records that an identifier was seen in a source, not who
-- listened to it. Keeping it aggregate avoids creating a second place a person's
-- library could be reconstructed from — the whole point of the sanitised
-- projection one layer down.
--
-- The wrinkle, named rather than left to be discovered: an aggregate fact
-- derived from Spotify rows is itself the kind of derived data IV.2.5 speaks to.
-- It exists to *comply* — to make the future restriction executable — and
-- nothing reads it into a model. That is a reason, not a loophole, and it should
-- be re-read if the rule around it changes.
--
-- ## It does not change what is minted
--
-- Recording only. The mint still considers every artist whatever source named
-- them. The future restriction then becomes a `where` clause with a decision
-- behind it, rather than a question nobody can answer.
--
-- ## Its own function, not a parameter on the mint
--
-- Adding a fourth argument to `mint_vocabulary_from_catalogue` would mean either
-- reproducing its three hundred lines here — the duplication `0177`'s own header
-- argues against — or `drop function` naming the old signature in full, since
-- `create or replace` overloads rather than replaces when the signature moves
-- and leaves an ambiguity Postgres refuses with `42725` from inside a call.
--
-- Separating them is also truer: provenance is a fact about the *lookup*, and it
-- should be recorded whether or not that lookup ends in a published version.

begin;

create table if not exists ontology.external_entity_sources (
  provider      text not null,
  external_id   text not null,
  entity_kind   text not null,
  source_code   text not null,
  first_seen_at timestamptz not null default now(),
  primary key (provider, external_id, entity_kind, source_code)
);

comment on table ontology.external_entity_sources is
  'Which app source named an identifier we asked a catalogue about. Aggregate: '
  'no user id, by design. Records only; nothing filters on it yet.';

-- **No check constraint listing the sources**, and that is deliberate. A literal
-- list here would be a fifth place a source has to be registered, and the
-- failure mode of a missing entry would be a refused insert inside a worker job
-- — silence, in the shape this schema keeps paying for. The values come from
-- `observations.source_code`, which is already a foreign key to
-- `semantic_private.sources`, so the vocabulary is constrained upstream where it
-- is declared once.
create or replace function ontology.record_catalogue_provenance(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  written integer := 0;
begin
  insert into ontology.external_entity_sources (
    provider, external_id, entity_kind, source_code
  )
  select 'apple_music_catalog',
         row_in ->> 'external_id',
         row_in ->> 'entity_kind',
         row_in ->> 'source_code'
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as row_in
   where coalesce(row_in ->> 'external_id', '') <> ''
     and coalesce(row_in ->> 'entity_kind', '') <> ''
     and coalesce(row_in ->> 'source_code', '') <> ''
  on conflict do nothing;
  get diagnostics written = row_count;
  return written;
end;
$$;

revoke all on function ontology.record_catalogue_provenance(jsonb)
  from public, anon, authenticated;
grant execute on function ontology.record_catalogue_provenance(jsonb) to semantic_worker;

do $$
declare
  granted boolean;
  written integer;
begin
  select has_function_privilege('semantic_worker',
           'ontology.record_catalogue_provenance(jsonb)', 'execute') into granted;
  if not granted then
    raise exception '0178: semantic_worker cannot record provenance';
  end if;

  -- **The grant is on the function and nowhere else.** `security definer` is
  -- what lets the worker write without holding a write, and `0070` asserts it
  -- cannot publish an ontology version. Re-checked here beside the change that
  -- could have quietly undone it.
  select has_table_privilege('semantic_worker',
           'ontology.external_entity_sources', 'insert') into granted;
  if granted then
    raise exception '0178: semantic_worker gained a direct write on the provenance table';
  end if;
  select has_function_privilege('semantic_ingestor',
           'ontology.record_catalogue_provenance(jsonb)', 'execute') into granted;
  if granted then
    raise exception '0178: semantic_ingestor may record provenance';
  end if;

  -- **An identifier seen in two sources must record two rows, not one.** This is
  -- the case the ten both-supplied artists depend on, and the one a "first
  -- source wins" implementation gets wrong while looking correct — it would
  -- report every such artist as belonging to whichever source happened to be
  -- read first, and the mistake is invisible until the day the restriction is
  -- applied.
  --
  -- Rolled back through a subtransaction so a replay leaves no rows behind;
  -- PL/pgSQL variables survive it, rows do not.
  begin
    written := ontology.record_catalogue_provenance(jsonb_build_array(
      jsonb_build_object('external_id', 'PROBE0000001', 'entity_kind', 'song',
                         'source_code', 'apple_music'),
      jsonb_build_object('external_id', 'PROBE0000001', 'entity_kind', 'song',
                         'source_code', 'spotify'),
      -- The same pair again: re-seeing an identifier must be free.
      jsonb_build_object('external_id', 'PROBE0000001', 'entity_kind', 'song',
                         'source_code', 'apple_music'),
      -- And a malformed row must be skipped rather than raising inside a job.
      jsonb_build_object('external_id', '', 'entity_kind', 'song',
                         'source_code', 'spotify')
    ));
    if written <> 2 then
      raise exception '0178: expected two provenance rows, wrote %', written;
    end if;
    raise exception 'rollback_the_probe';
  exception when others then
    if sqlerrm <> 'rollback_the_probe' then
      raise;
    end if;
  end;

  raise notice '0178: provenance records both sources for one identifier, and dedupes';
end;
$$;

commit;
