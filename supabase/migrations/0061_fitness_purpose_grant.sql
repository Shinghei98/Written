-- 0061 — somewhere for a person to say yes to fitness capture.
--
-- **HealthKit is fail-closed and nothing could open it.**
-- `guard_raw_healthkit_grant` refuses an active HealthKit row unless
-- `semantic_private.healthkit_use_grants` holds an active grant for that
-- person; `authenticated` has no access to `semantic_private`; and no RPC
-- anywhere writes one. So the source could be enabled and every batch would be
-- refused — and because the client drops a permanent refusal, the data would
-- disappear quietly rather than failing loudly. That guard is right and this is
-- the door it was waiting for.
--
-- **In `public`, not `api`, and that is a deployment fact rather than a
-- preference.** The `api` schema is deliberately not in the project's exposed
-- schemas, so PostgREST cannot reach it and a client-callable function there
-- would be unreachable. `public.match_profile` (`0037`) is the shape this
-- follows: `security definer`, subject taken from `auth.uid()` and never from
-- an argument, pinned `search_path`.
--
-- **The subject is `auth.uid()` and there is no parameter for it.** A grant is
-- a consent decision; a function that let a caller name whose consent it was
-- recording would be a function for forging consent.
--
-- **Capture needs only that a grant exists.** `healthkit_grant_allows` answers
-- true for `memories` unconditionally, so the four booleans below gate the
-- *surfaces* — matching, bios, icebreakers — and not the retention. Phase 1
-- asks for none of them, and the client sends all four false: "keep and use my
-- activity to describe me to myself, and not for anything else." Widening that
-- later is a new consent question, not a default to be flipped.
--
-- Ships no product behaviour on its own: nothing calls this until the app does.

begin;

/*
 * Record, or update, this person's fitness-capture consent.
 *
 * Idempotent by design: re-consenting is not an error, and the `updated_at`
 * moves so a support question about when somebody agreed has an answer.
 * Re-granting after a revocation clears `revoked_at`, which the table's own
 * check requires — `active` with a revocation time is not a state.
 */
create or replace function public.record_fitness_grant(
    allow_fitness_matching boolean default false,
    allow_bio_naming boolean default false,
    allow_icebreaker_naming boolean default false,
    allow_controlled_explanation boolean default false,
    consent_version text default 'fitness-v1'
)
returns timestamptz
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    me uuid := auth.uid();
    recorded timestamptz;
begin
    if me is null then
        raise exception 'not signed in' using errcode = 'insufficient_privilege';
    end if;
    if consent_version is null or consent_version !~ '^[a-z0-9][a-z0-9_.-]{0,63}$' then
        raise exception 'a grant must name the consent version it was given under'
            using errcode = 'invalid_parameter_value';
    end if;

    insert into semantic_private.healthkit_use_grants as g (
        user_id, data_use_purpose, grant_state,
        allow_fitness_matching, allow_bio_naming,
        allow_icebreaker_naming, allow_controlled_explanation,
        consent_version, granted_at, updated_at
    )
    values (
        me, 'fitness_connection', 'active',
        allow_fitness_matching, allow_bio_naming,
        allow_icebreaker_naming, allow_controlled_explanation,
        consent_version, now(), now()
    )
    -- The primary key is `user_id` alone — one grant per person, and
    -- `data_use_purpose` is pinned to `fitness_connection` by a check. Naming
    -- the pair here would name no unique index and fail at runtime.
    on conflict (user_id) do update
    set grant_state = 'active',
        revoked_at = null,
        allow_fitness_matching = excluded.allow_fitness_matching,
        allow_bio_naming = excluded.allow_bio_naming,
        allow_icebreaker_naming = excluded.allow_icebreaker_naming,
        allow_controlled_explanation = excluded.allow_controlled_explanation,
        consent_version = excluded.consent_version,
        updated_at = now()
    returning g.granted_at into recorded;

    return recorded;
end;
$$;

/*
 * Whether this person has an active grant, for the client to read on launch.
 *
 * **Needed because the client must not send HealthKit rows without one.** A
 * batch for somebody with no grant is refused, and `SemanticIngestionService`
 * treats a refusal as permanent and drops it — so asking first is the
 * difference between not sending and losing.
 *
 * Returns only a boolean. Which surfaces somebody permitted is not the client's
 * business yet, and a reader that returned the whole row would be a reader
 * somebody would eventually branch on.
 */
create or replace function public.has_fitness_grant()
returns boolean
language sql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
    select exists (
        select 1
        from semantic_private.healthkit_use_grants
        where user_id = auth.uid()
          and data_use_purpose = 'fitness_connection'
          and grant_state = 'active'
    );
$$;

revoke all on function public.record_fitness_grant(
    boolean, boolean, boolean, boolean, text
) from public, anon;
revoke all on function public.has_fitness_grant() from public, anon;

grant execute on function public.record_fitness_grant(
    boolean, boolean, boolean, boolean, text
) to authenticated;
grant execute on function public.has_fitness_grant() to authenticated;

comment on function public.record_fitness_grant(boolean, boolean, boolean, boolean, text) is
    'Records this account''s fitness-capture consent. Subject is auth.uid() and '
    'cannot be named by the caller. Any active grant permits raw HealthKit '
    'retention; the booleans gate matching, bios and icebreakers.';

-- ---------------------------------------------------------------------------

-- `anon` must not reach either of these: an unauthenticated caller has no
-- consent to record and nothing to read. Checked rather than assumed, because
-- `security definer` in `public` is the one place in this schema where a wrong
-- grant would be both reachable and silent.
do $$
begin
  if pg_catalog.has_function_privilege(
       'anon', 'public.record_fitness_grant(boolean,boolean,boolean,boolean,text)', 'execute')
     or pg_catalog.has_function_privilege('anon', 'public.has_fitness_grant()', 'execute') then
    raise exception 'anon can reach the fitness grant functions';
  end if;
  if not pg_catalog.has_function_privilege(
       'authenticated', 'public.record_fitness_grant(boolean,boolean,boolean,boolean,text)', 'execute') then
    raise exception 'authenticated cannot record a fitness grant';
  end if;
end
$$;

commit;
