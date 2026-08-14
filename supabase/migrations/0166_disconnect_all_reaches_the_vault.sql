-- Disconnect all reaches the vault, which it never had
--
-- **The bug, reported 2026-08-14.** *Settings → Disconnect all* emptied the
-- legacy tables and the terms stayed on Memories. They had to: the button calls
-- `SyncService.deleteEverything`, which deletes `distilled_records`,
-- `source_connections`, `health_signals` and `health_sports` — four tables in
-- `public`, none of them the one Memories reads. The blocks on that page are
-- `semantic_private.user_assertions` through `api.list_assertions`, and nothing
-- in the disconnect path had ever named them.
--
-- So the control deleted the copy the user could see and kept the one they
-- could not, which is the worst arrangement of the two and reads as the button
-- not working.
--
-- **What this deletes, and what it deliberately does not.** The owner's
-- decision of 2026-08-14, taken against the alternative of erasing the whole
-- distillation subtree: *retire the claims, keep the vault*. The reasoning is
-- the standing collaborator rule — everything the development team has given
-- must stay stored and re-usable for training and testing "without asking an
-- additional involvement from them", and a disconnect that erased the vault
-- would destroy exactly that, irreversibly, from a button pressed while
-- testing. Losing a distillation is losing a person's afternoon.
--
-- The claims are what a person sees and what other people are matched on, so
-- retiring them is the whole of what *Disconnect all* means to the user; the
-- encrypted capture behind them is inert until something scores it again.
--
-- **`web/en-us/privacy/` moves in the same commit**, because it currently says
-- *Disconnect all* "deletes everything read through them" and after this that
-- sentence is false of the vault. A page that overstates a deletion is worse
-- than one that describes a narrower one accurately.
--
-- **YouTube is the exception, and it is an obligation rather than a
-- preference.** The Developer Policies give 30 days for ordinary retention —
-- met by `0016`'s daily sweep, which already covers `raw_source_records` — but
-- **7 days for a revocation made in the client**, and that is precisely what
-- this button is. A sweep on a 30-day clock cannot meet a 7-day deadline, which
-- is why CLAUDE.md names *Disconnect all* as the mechanism for it.
--
-- **And the two decisions do not collide.** YouTube data is excluded from the
-- training corpus already — III.E.4.h forbids ingesting it into a model and
-- IV.2.5 says a user's consent does not cure that — so the corpus query at the
-- foot of `0041` never reads these rows. Deleting them costs the training set
-- nothing at all, which is what makes "keep the vault" and "delete YouTube"
-- both true at once rather than a compromise between them.
--
-- **Retirement is `inactive`, not deletion, and it is reversible.** That is the
-- state the scorer already demotes into, and `UPDATE_ASSERTION` in `score.py`
-- writes whichever state a run computes — so reconnecting a source and
-- distilling revives the term rather than needing a repair. "Collected then
-- struck off" and "never collected" stay different facts, which is the same
-- reasoning `markedRemoved` carries in the legacy path.
--
-- **`explicit_addition` survives, and it is the same line the legacy path
-- draws.** `deleteEverything` keeps `source = 'user'` rows because they are
-- what somebody typed rather than what was read off their phone; an assertion
-- the person added by hand in Memories is that same fact in the new schema. A
-- disconnect that deleted it would sign somebody out of their own answers.
--
-- **Not gated on `assert_surface_allowed`.** Every other function in `api` is,
-- and this one must not be: the memories flag is §9's rollback contract, and a
-- kill switch that also disabled somebody's erasure would turn a read control
-- into a retention decision. A deletion has to work on the worst day.
--
-- **The revision is not touched.** Retirement takes effect through
-- `machine_state`, which `api.list_assertions` filters on directly, so nothing
-- here needs the currency machinery — and the revision is monotonic and never
-- walked back.

begin;

create or replace function api.forget_distillation()
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  me uuid := auth.uid();
  retired integer := 0;
  youtube_observations integer := 0;
  youtube_raw integer := 0;
begin
  -- **No parameter for whose.** Every function in this schema is scoped to
  -- `auth.uid()` and takes no user id, so a caller cannot ask about — or here,
  -- act on — anybody but themselves.
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;

  -- 1. The claims. Inferred only: see the header on `explicit_addition`.
  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where user_id = me
     and assertion_origin = 'inferred'
     and machine_state <> 'inactive';
  get diagnostics retired = row_count;

  -- 2. YouTube, in foreign-key order, leaves first.
  --
  -- **Every one of these is a `no action` reference**, so the order is forced
  -- rather than chosen — `ingestion_run_items` and `current_source_items` both
  -- point at observations *and* raw records, and `source_state_heads` points at
  -- the scopes. Nothing here relies on "no trigger fires on delete", which is
  -- true and is not the constraint; foreign keys are.
  delete from semantic_private.ingestion_run_items
   where user_id = me and source_code = 'youtube';
  delete from semantic_private.current_source_items
   where user_id = me and source_code = 'youtube';
  delete from semantic_private.source_state_heads
   where user_id = me and source_code = 'youtube';

  -- Cascades take `observation_mappings`, `observation_mentions`,
  -- `youtube_observation_channels`, `legacy_record_links` and
  -- `mapping_feedback_labels` with it, and `assertion_evidence` and
  -- `motif_support` behind the mappings.
  delete from semantic_private.observations
   where user_id = me and source_code = 'youtube';
  get diagnostics youtube_observations = row_count;

  delete from semantic_private.raw_source_records
   where user_id = me and source_code = 'youtube';
  get diagnostics youtube_raw = row_count;

  delete from semantic_private.ingestion_run_scopes
   where user_id = me and source_code = 'youtube';
  delete from semantic_private.source_coverage
   where user_id = me and source_code = 'youtube';
  -- Last, because everything above referenced it. `legacy_ingestion_runs`
  -- cascades from here.
  delete from semantic_private.ingestion_runs
   where user_id = me and source_code = 'youtube';

  -- 3. The vault's own connection rows, for every source — this is
  -- *Disconnect all*, and `public.source_connections` is cleared by the caller.
  delete from semantic_private.source_connections
   where user_id = me;

  -- **A receipt, because the caller must not have to guess.** The legacy half
  -- of this control reports a reason on failure and the app draws it; an
  -- erasure that answers `void` would make "the terms are still there" and "the
  -- call never ran" the same observation from the client's side.
  return jsonb_build_object(
    'assertions_retired', retired,
    'youtube_observations_deleted', youtube_observations,
    'youtube_raw_records_deleted', youtube_raw
  );
end;
$$;

-- **`anon` by name.** Supabase installs default privileges that grant a new
-- function to `anon` and `authenticated` directly, and `revoke … from public`
-- names the pseudo-role, leaving that direct grant untouched. `0009` records
-- the same trap on table privileges.
revoke all on function api.forget_distillation() from public, anon;
grant execute on function api.forget_distillation() to authenticated;

commit;
