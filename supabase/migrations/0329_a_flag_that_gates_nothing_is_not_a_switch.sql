-- 0329 — `typed_ingestion` is deleted, because it decides nothing.
--
-- Seeded by `0048` with the description *"Accept typed source envelopes into
-- the private vault"*, it has read `false` since the day it was written and has
-- **never been consulted by anything**. One reference exists in the whole
-- repository — its own registry insert at `0048:1209`. No function body names
-- it, no guard calls `flag_enabled_v031` with it, no surface maps to it in
-- `assert_surface_allowed`, and neither `aws/` nor `semantic/src` mentions it.
--
-- **Meanwhile the thing it claims to gate has been running for twelve days.**
-- Measured 2026-08-23: 217 succeeded ingestion runs and 17,758 observations in
-- the vault, the most recent that same afternoon. So the flag table states that
-- typed envelopes are refused while the vault fills, and anyone auditing the
-- switches — which is what a flag table is *for* — would read the privacy
-- posture backwards.
--
-- **That is this project's standing defect in its purest form**: a call that
-- can fail, a result nobody reads, and the symptom surfacing somewhere else.
-- Here there is not even a call. The rule the file states about booleans
-- applies to rows too — a flag that no code asks about is a convention, not a
-- guard, and the honest repair is to delete it rather than to wire it to
-- something after the fact. Wiring it now would be worse: it would put a gate
-- in front of a live path on the strength of a description nobody has tested,
-- and `0231`'s lesson is that a switch which has never answered both ways is
-- not one to believe.
--
-- **What this does not touch.** The four flags that do decide something
-- (`memories_reads`, `discovery_profile_reads`, `calibration_reads`,
-- `emergency_privacy_kill_switch`) and the two that are off and enforced
-- (`icebreaker_first_exposure`, `healthkit_fitness_use`, `semantic_shadow_compute`)
-- keep their rows and their meanings. Ingestion's real controls are unchanged
-- and are not flags: `guard_invocation_item_scope`, the ES256 token the Lambda
-- demands, `guard_observation_ingestion_run`, and the per-source list in
-- `AppConfig.semanticIngestionSources`. **Deleting this row removes a claim,
-- never a control.**
--
-- `0048` is not edited. Migrations are history and are appended to, never
-- rewritten; on a replay `0048` inserts the row and this deletes it again.

do $$
declare
    wired integer;
    overridden integer;
    surviving integer;
begin
    -- **Refuse if anything has learned to consult it.** The whole argument for
    -- deleting is that no code asks, and that is a fact about the database at
    -- deploy time rather than about the repository at authoring time. If
    -- somebody wires it between this being written and this being run, the
    -- correct outcome is a failed migration, not a silently removed gate.
    -- `0226` scans `pg_get_functiondef` for the same reason: an instrument that
    -- quietly acquires a caller has stopped being one.
    --
    -- **`prokind in ('f','p')` is load-bearing, not tidiness.** Without it this
    -- raises `42809 "array_agg" is an aggregate function` before it can answer
    -- anything — `pg_get_functiondef` refuses aggregates and window functions
    -- outright, so an unfiltered scan fails on a database that merely *has*
    -- one. Found by running the guard read-only before deploying it.
    select count(*) into wired
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname not in ('pg_catalog', 'information_schema', 'extensions')
       and p.prokind in ('f', 'p')
       and pg_get_functiondef(p.oid) like '%typed_ingestion%';
    if wired <> 0 then
        raise exception
            '0329: typed_ingestion is referenced by % function(s); it now gates '
            'something and must not be deleted', wired;
    end if;

    -- **The foreign key cascades, so the delete could take a per-user override
    -- with it without saying so.** There are none today. A cascade that
    -- silently discards somebody's per-account switch is precisely the kind of
    -- quiet destruction this schema refuses everywhere else, so it is asserted
    -- rather than assumed.
    select count(*) into overridden
      from semantic_private.feature_flag_overrides
     where flag_key = 'typed_ingestion';
    if overridden <> 0 then
        raise exception
            '0329: % per-user override(s) exist for typed_ingestion; deleting '
            'the flag would cascade them away', overridden;
    end if;

    delete from semantic_private.feature_flags where flag_key = 'typed_ingestion';

    -- **Assert the transformation, not the precondition.** A count of zero
    -- before the delete is not a failure to act, and asserting one would make
    -- this unreplayable against any database that had already dropped the row.
    -- What must be true afterwards is the same on an empty database and on
    -- production: the key is gone.
    select count(*) into surviving
      from semantic_private.feature_flags where flag_key = 'typed_ingestion';
    if surviving <> 0 then
        raise exception '0329: typed_ingestion survived the delete';
    end if;
end;
$$;
