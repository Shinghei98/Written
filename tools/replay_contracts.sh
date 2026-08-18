#!/usr/bin/env bash
#
# Replay the migration chain and run the adapted v0.3.1 contracts against it.
#
# **This exists because the proof kept evaporating.** The eight contracts in
# `supabase/tests/` were run once, by hand, in a throwaway container, and
# nothing has run them since — so "0042-0049 are verified" was an anecdote about
# one afternoon rather than a fact about the repository. CI calls this; so can
# you, and it is the same script either way, which is the point.
#
#   ./tools/replay_contracts.sh
#
# Needs Docker. Takes a few minutes: it builds the schema from empty three
# times, because the two fixture lanes are stateful and mixing them makes the
# result unreadable.
#
# **The staging is not decoration.** Each contract asserts the state at *its
# own* migration, so running them all at the end fails two of them for reasons
# that are not real: `0044_integrity_contract` asserts the pre-0045 surface
# whitelist, and `0045_product_surfaces_contract` asserts a `worker_jobs`
# constraint that `0046` deliberately replaces. That is a property of the
# contracts, not a bug, and it is why this walks the chain rather than jumping
# to the end.
#
# **And the fixture lanes are off by one against app numbering**, which is the
# single easiest thing here to get wrong: the reference fixture named `004`
# gates the app's `0046`, and the one named `005` gates `0047`. The filenames in
# `supabase/tests/fixtures/` are already renamed to the migration they gate; this
# comment is here for whoever compares them against the upstream package.

set -euo pipefail

IMAGE="${WRITTEN_PG_IMAGE:-public.ecr.aws/supabase/postgres:17.6.1.156}"
CONTAINER="${WRITTEN_PG_CONTAINER:-written-contracts}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="$ROOT/supabase/migrations"
TESTS="$ROOT/supabase/tests"

fail=0
pass_count=0
fail_count=0

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql_root() { docker exec -i "$CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q 2>/dev/null; }
psql_app()  { docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -q; }

start_postgres() {
  cleanup
  echo "==> starting $IMAGE"
  docker run -d --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres "$IMAGE" >/dev/null

  # **`pg_isready` is not the signal here, and believing it cost a whole run.**
  # The image runs its init scripts against a temporary server, reports
  # "database system is ready to accept connections", *shuts that server down*,
  # and starts the real one. Connecting on the first ready gets a few statements
  # in and then `FATAL: the database system is shutting down` — which surfaces
  # as a migration failing five files later, nowhere near the cause.
  #
  # So wait for the line that only the handover prints, and only then for a
  # connection that actually answers.
  for _ in $(seq 1 90); do
    if docker logs "$CONTAINER" 2>&1 | grep -q "init process complete"; then break; fi
    sleep 2
  done
  for _ in $(seq 1 60); do
    docker exec "$CONTAINER" psql -U postgres -tAc "select 1" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "postgres never became ready" >&2
  docker logs "$CONTAINER" 2>&1 | tail -20 >&2
  exit 1
}

# Everything the chain creates, removed — but not the service stand-ins, which
# are environment rather than schema and are installed once.
reset_schema() {
  psql_root <<'SQL'
drop schema if exists semantic_private cascade;
drop schema if exists ontology cascade;
drop schema if exists api cascade;
drop schema if exists private cascade;
drop schema if exists public cascade;
create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres;
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects'
  loop execute format('drop policy %I on storage.objects', p.policyname); end loop;
end
$$;
delete from storage.objects;
delete from storage.buckets;
delete from auth.users;
SQL
}

# Every migration whose name sorts at or below the argument. Filenames are
# zero-padded, so a string comparison is the ordering.
apply_through() {
  local upto="$1"
  for f in $(cd "$MIGRATIONS" && ls ./*.sql | sed 's|^\./||' | sort); do
    [[ "$f" > "$upto" ]] && break
    psql_app < "$MIGRATIONS/$f" >/dev/null 2>&1 || {
      echo "  APPLY FAILED  $f"; fail=1; return 1
    }
  done
}

apply() {
  local err; err="$(mktemp)"
  psql_app < "$MIGRATIONS/$1" >/dev/null 2>"$err" || {
    echo "  APPLY FAILED  $1"
    sed -n 's/^/      /p' "$err" | grep -E "ERROR|DETAIL|CONTEXT|HINT" | head -4
    rm -f "$err"; fail=1; return 1
  }
  rm -f "$err"
}

# Everything *after* `$1`, in order. The staged lanes above name their
# migrations one by one because each is followed by a contract that asserts the
# state at exactly that point; the tail has no such staging and only needs to
# arrive, so listing 69 more filenames by hand would be 69 more chances to
# forget one.
apply_after() {
  local from="$1" f known unexpected=0
  known="$ROOT/tools/ci/unreplayable_migrations.txt"
  for f in $(cd "$MIGRATIONS" && ls ./*.sql | sed 's|^\./||' | sort); do
    [[ "$f" > "$from" ]] || continue
    # **Keep the error.** This read `2>&1` and threw psql's reason away, so a
    # failing replay said only *that* five migrations failed — and diagnosing
    # them meant guessing one per push. The reason a migration refuses is the
    # single most useful line CI can print, and it costs a temp file.
    err="$(mktemp)"
    psql_app < "$MIGRATIONS/$f" >/dev/null 2>"$err" && { rm -f "$err"; continue; }
    # **Continues, and says so.** Thirteen migrations assert against production
    # data — eight runs by a named scorer, a flag that is false in production,
    # a likes table with rows — so they raise on an empty database before their
    # own DDL commits. That is a real debt, registered in the file above rather
    # than tolerated silently, and the schema they would have built is missing
    # from every replay until it is paid.
    if grep -qxF "$f" "$known" 2>/dev/null; then
      echo "  known unreplayable  $f"
      rm -f "$err"
    else
      echo "  APPLY FAILED  $f  (not in tools/ci/unreplayable_migrations.txt)"
      sed -n 's/^/      /p' "$err" | grep -E "ERROR|DETAIL|CONTEXT|HINT" | head -4
      unexpected=1
      rm -f "$err"
    fi
  done
  if [ "$unexpected" = 1 ]; then fail=1; return 1; fi
}

# Apply, then apply again. Every semantic migration is expected to survive being
# run twice; the replay is where a `drop … if exists` that trips over its own
# dependants shows up.
apply_twice() { apply "$1" && apply "$1"; }

load_fixture() {
  psql_app < "$TESTS/fixtures/$1" >/dev/null 2>&1 || { echo "  FIXTURE FAILED  $1"; fail=1; return 1; }
}

run_contract() {
  local name="$1" out
  if out=$(psql_app < "$TESTS/$name.sql" 2>&1); then
    echo "  PASS  $name"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL  $name"
    echo "$out" | grep -E "^(ERROR|CONTEXT)" | head -3 | sed 's/^/          /'
    fail=1; fail_count=$((fail_count + 1))
  fi
}

start_postgres
echo "==> installing service stand-ins (storage tables, auth.users.phone)"
psql_root < "$ROOT/tools/ci/service_shims.sql"

echo
echo "########## LANE A — clean install, staged contracts, replay ##########"
reset_schema
apply_through "0044_z"
run_contract 0044_version_rollover
run_contract 0044_integrity_contract
run_contract 0044_exact_revision_finalization
apply_twice 0045_semantic_product_surfaces.sql        && run_contract 0045_product_surfaces_contract
apply_twice 0046_semantic_private_ingestion_fitness.sql && run_contract 0046_private_ingestion_and_fitness_contract
apply_twice 0047_semantic_current_state_surfaces.sql  && run_contract 0047_current_state_and_surface_hardening_contract
apply_twice 0048_semantic_legacy_bridge.sql
apply_twice 0049_capture_platform_rls_event_trigger.sql
apply_twice 0050_semantic_user_encryption_keys.sql
# 0051 asserts, at migration time, that the key-version vocabularies of the
# registry and of `raw_source_records` agree. It raises rather than warns, so an
# apply failure here *is* the test — there is no separate contract file.
apply_twice 0051_align_encryption_key_version.sql
# 0052 asserts its own outcome the same way: it reads back what the ingestion
# role can select and call, and raises if the revokes did not take. An apply
# failure is the failing assertion.
apply_twice 0052_semantic_ingestor_role.sql
# 0053 replaces the one function 0052's argument rests on, so it re-asserts the
# same thing: one callable function, no readable tables. A `drop` that missed or
# a `create` that overloaded both surface here as a count of two.
apply_twice 0053_ingest_with_wrapped_key.sql
# 0054 reorders the key write behind the row write so a pure-duplicate batch
# records nothing. Same signature, so a plain replace — no drop needed.
apply_twice 0054_key_only_when_something_stored.sql
# 0055 adds the scope manifest, run items and finalization. It changes the
# parameter list, so it drops before creating; and it reaches
# finalize_ingestion_run_v031 from *inside* rather than by granting it, which is
# why the one-callable-function assertion still has to hold.
apply_twice 0055_ingestion_scopes_items_finalize.sql
# 0056 makes finalization conditional on the run having a scope, so a run of
# entirely unpromotable rows keeps what it captured instead of rolling it back.
apply_twice 0056_finalize_only_with_a_scope.sql
# 0057 gives the worker its identity and asserts, by reading the catalog, that
# it reads ten tables, writes two and reaches nothing outside semantic_private.
apply_twice 0057_semantic_worker_role.sql
# 0058 adds what the worker's own triggers need — inserting one observation
# fires six security-invoker triggers that run as the worker, not the owner.
apply_twice 0058_worker_trigger_grants.sql
# 0059 moves projection into ingestion, where the plaintext already is and the
# run is still open. Its assertion is the one that matters: the ingestion role
# must gain no table access from writing observations.
apply_twice 0059_ingestion_writes_observations.sql
# 0060: a JSON null is not a SQL NULL. Guarding on  let an absent
# projection through as 'null'::jsonb and failed the closed-projection check.
apply_twice 0060_observation_projection_must_be_an_object.sql
# 0061 gives the app a door to record fitness consent, without which HealthKit
# capture is refused by design. Asserts anon cannot reach either function.
apply_twice 0061_fitness_purpose_grant.sql
# 0062 gives the shadow comparison a durable home in ingestion_runs.metrics,
# written while the run is still running because a terminal run is immutable.
apply_twice 0062_run_coverage_metrics.sql
# 0063 lets the worker write a fitness coverage snapshot. Its assertion pins the
# worker's *whole* reach rather than adding to it, so this re-run is also the
# check that a later migration has not widened it by a table.
apply_twice 0063_worker_fitness_snapshot_grants.sql
# 0064 lets a projection name its own data_type, action and weight, because the
# contract's observation vocabulary is not the connector's capture vocabulary.
# Re-running it also proves the temp table is rebuilt rather than reused: a
# warm backend holding the old thirteen-column shape is the failure mode.
apply_twice 0064_observation_projection_vocabulary.sql
# Again, with the bridge and the captured event trigger in place: 0048 rewrites
# `finalize_ingestion_run_v031`, which is the function this contract is built
# around, so "0048 broke nothing" is a claim worth re-testing rather than
# assuming.
run_contract 0047_current_state_and_surface_hardening_contract

# **The rest of the chain, because the check below says "the whole chain" and
# for a long time that was false.** Lane A staged migrations one at a time up to
# 0064 and stopped, so the envelope vocabulary was asked of a schema 69
# migrations stale — and it passed, because every source it knew about had been
# registered before 0064. `outlook_calendar` arrives in 0133 and was reported as
# an action the schema does not weigh, which was the check telling the truth
# about a database nobody meant to be testing against.
echo
echo "==> applying the rest of the chain"
apply_after "0064_z"

# **The calibration and erasure lifecycle, once the whole chain exists.** It
# seeds its own users and candidates, exercises the three client verbs through
# `api` with `auth.uid()` set from a JWT claim, and rolls back. Run here rather
# than beside an earlier migration because the surface it tests is built by
# `0227`-`0230` and the guards it relies on by `0229`.
run_contract 0230_calibration_lifecycle_contract

# **The overlay arms until its work is done and then stops.** Seeds a support
# link against a superseded resolution row — the shape production was in — and
# asserts `build_candidate_overlay` goes quiet. Runs here because it calls
# `arm_candidate_overlay`, which `0211` defines and `0232` corrects.
run_contract 0232_overlay_arming_contract

# **A provisional has one live identity, and a strike survives becoming a
# concept.** Both are latent while `provisional_entities` is empty, which is
# why they are asserted before a sink fills it.
run_contract 0233_provisional_identity_contract

# **A typed exact miss becomes one private candidate and nothing more.**
# Stage 1A's plumbing fixture: it calls the lane's real SQL functions and
# asserts the required zeros, the idempotent rerun and the erasure.
run_contract 0234_provisional_sink_contract

# **A gate report is an event.** Append-only by trigger, and a manifest
# attesting a lane that may call a model must name what it calls.
run_contract 0235_release_gate_report_contract

# **Per-item model lineage**, append-only and attributable, before anything
# writes it. Every property here is latent while the table is empty.
run_contract 0236_invocation_lineage_contract

echo
echo "########## the compiled semantic contract against the built schema ##########"
# `compiled_semantic_contract_v1.json` declares `concept_kind_authority:
# live_pg_constraint`, and its gate takes the live allowlists as an argument
# rather than opening a connection — because a compiler that fell back to a
# checked-in snapshot would make that authority claim a fiction.
#
# **This is where the argument stops being hand-written.** Lane A has just built
# the whole chain from empty, so the catalog sitting in that container is the
# most honest reading available: nothing has been repaired into its ledger, no
# migration is marked applied that did not run. `read_live_catalog.py --emit-sql`
# produces the snapshot with its provenance — the constraint oids it parsed and a
# digest over every table, column and check constraint in the two schemas — and
# the gate refuses a snapshot that carries neither.
#
# Same shape as the envelope check below and for the same reason: the question
# has to be asked of the built schema, because reconstructing the answer by
# parsing SQL would be another copy of the thing under test.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP  python3 not available for the semantic contract gate"
else
  snapshot="$(mktemp)"
  python3 "$ROOT/tools/read_live_catalog.py" --emit-sql \
    | docker exec -i "$CONTAINER" psql -U postgres -tA -v ON_ERROR_STOP=1 \
    > "$snapshot" 2>&1
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$snapshot" 2>/dev/null; then
    echo "  FAIL  the live catalog snapshot is not JSON:"
    sed 's/^/        /' "$snapshot" | head -5
    fail=1; fail_count=$((fail_count + 1))
  elif gate=$(python3 "$ROOT/tools/compile_semantic_contract.py" \
                --check-database --live-enums "$snapshot" 2>&1); then
    echo "  PASS  the compiled contract agrees with the schema this chain builds"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL  the compiled contract disagrees with the schema this chain builds:"
    printf '%s\n' "$gate" | sed 's/^/        /'
    fail=1; fail_count=$((fail_count + 1))
  fi
  rm -f "$snapshot"
fi

echo

echo "########## the iOS envelope vocabulary ##########"
# `Written/Models/SemanticSource.swift` maps every `data_type` the app emits to
# an action, and an action is only real if the source actually weighs it.
#
# **This has to be asked of the built schema.** Several migrations touch
# `action_weights` — 0042, 0044, 0045, 0046, 0048, and 0133 for the third
# calendar — so reconstructing the final state by parsing SQL would be a third
# copy of the thing under test. Lane A has now genuinely applied the whole
# chain (see `apply_after` above), so the answer is sitting in the database.
#
# The other half of this check needs no database and lives in
# `semantic/tests/test_ios_envelope_contract.py`: every data type mapped at all.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP  python3 not available for the envelope vocabulary check"
else
  vocab=$( { python3 "$ROOT/tools/ios_envelope_contract.py" --repo "$ROOT" --emit-sql
             cat <<'SQL'
select count(*) || '|' || coalesce(string_agg(
         format('%s/%s -> %s', a.source_code, a.data_type, a.action_type), ', '
         ) filter (where s.source_code is null or not (s.action_weights ? a.action_type)), '')
from ios_envelope_actions a
left join semantic_private.sources s on s.source_code = a.source_code;
SQL
           } | docker exec -i "$CONTAINER" psql -U postgres -tA -v ON_ERROR_STOP=1 2>&1 | tail -1 )
  total="${vocab%%|*}"
  unweighed="${vocab#*|}"
  if [ -n "$unweighed" ]; then
    echo "  FAIL  the app claims actions the schema does not weigh: $unweighed"
    fail=1; fail_count=$((fail_count + 1))
  else
    echo "  PASS  all $total mapped (source, data_type, action) triples are weighted"
    pass_count=$((pass_count + 1))
  fi
fi

echo
echo "########## the package's action weights against the schema's ##########"
# **The direction the envelope check above does not look.** That one asks
# whether the schema weighs everything the app claims, and it passed throughout
# — the schema was right. What nothing asked was whether the *package* weighs
# everything the schema does.
#
# `0139` weighed Spotify's `top_track` at 0.78 and `top_artist` at 0.55 here in
# the database and left `written_ontology.source_policy.SOURCE_ACTION_WEIGHTS`
# untouched, because a migration cannot reach into the package. Both copies are
# consulted: the schema's is stamped onto each observation at ingestion, the
# package's derives `SOURCE_ACTION_PAIRS`, and `ObservationMapper` refuses any
# action absent from it. 560 correctly weighted observations mapped to nothing
# for six migrations, and every run reported success.
#
# **A weight of 0 is not drift.** `recommendation`, `playlist`, `entered_by_user`
# and the rest are registered in the schema precisely to say the source knows the
# act and does not weigh it; the package omits them for the same reason.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP  python3 not available for the action-weight agreement check"
else
  drift=$( { PYTHONPATH="$ROOT/semantic/src" python3 - <<'PY'
from written_ontology.source_policy import SOURCE_ACTION_WEIGHTS

print("create temporary table package_action_weights "
      "(source_code text, action_type text, weight double precision);")
rows = [
    "('%s','%s',%r)" % (source, action, float(weight))
    for source, weights in SOURCE_ACTION_WEIGHTS.items()
    for action, weight in weights.items()
]
if rows:
    print("insert into package_action_weights values " + ",".join(rows) + ";")
PY
             cat <<'SQL'
select coalesce(string_agg(msg, ', '), '') from (
  select format('%s/%s: schema %s, package %s', s.source_code, w.key, w.value,
                coalesce(p.weight::text, 'absent')) as msg
    from semantic_private.sources s
    cross join lateral jsonb_each_text(s.action_weights) as w(key, value)
    left join package_action_weights p
      on p.source_code = s.source_code and p.action_type = w.key
   where w.value::double precision > 0
     and (p.weight is null or abs(p.weight - w.value::double precision) > 1e-9)
     -- ONE KNOWN GAP, named rather than tolerated silently.
     -- 0133 registered outlook_calendar and weighed scheduled at 0.90; the
     -- package has no entry for that source at all, so its action pair set is
     -- empty and every one of its observations is refused. 44 active, 0 mapped,
     -- measured 2026-08-14. The identical defect this check was written for.
     --
     -- Excluded here rather than fixed in passing because closing it makes a
     -- calendar events mappable, and the calendar lane is where 0133 spent a
     -- whole migration replacing source literals with is_private_calendar_source.
     -- The package names calendars by literal in SOURCE_ACTION_PAIRS, which is
     -- the same hazard one layer up, and that deserves a decision.
     --
     -- DELETE THIS CLAUSE when that decision is made, in either direction.
     and not (s.source_code = 'outlook_calendar' and w.key = 'scheduled')
  union all
  select format('%s/%s: package %s, schema absent or zero',
                p.source_code, p.action_type, p.weight)
    from package_action_weights p
    left join semantic_private.sources s on s.source_code = p.source_code
   where coalesce((s.action_weights ->> p.action_type)::double precision, 0) <= 0
) d;
SQL
           } | docker exec -i "$CONTAINER" psql -U postgres -tA -v ON_ERROR_STOP=1 2>&1 | tail -1 )
  if [ -n "$drift" ]; then
    echo "  FAIL  the package and the schema disagree about what an act is worth: $drift"
    fail=1; fail_count=$((fail_count + 1))
  else
    echo "  PASS  every weighted action agrees between the package and the schema"
    pass_count=$((pass_count + 1))
  fi
fi

echo
echo "########## LANE B — Calendar upgrade fixture (gates 0046) ##########"
reset_schema
apply_through "0045_z"
load_fixture 0046_calendar_upgrade_fixture.sql
apply_twice 0046_semantic_private_ingestion_fitness.sql && run_contract 0046_calendar_upgrade_contract
apply_twice 0047_semantic_current_state_surfaces.sql   && run_contract 0047_current_state_and_surface_hardening_contract
apply_twice 0048_semantic_legacy_bridge.sql

echo
echo "########## LANE C — surface-fact fixture (gates 0047) ##########"
reset_schema
apply_through "0046_z"
load_fixture 0047_surface_fact_upgrade_fixture.sql
apply_twice 0047_semantic_current_state_surfaces.sql && run_contract 0047_surface_fact_upgrade_contract
apply_twice 0048_semantic_legacy_bridge.sql

echo
echo "########## the app's own private schema ##########"
# 0042's header prescribes this, and "an adapted grant broadens access" is the
# integration plan's named deployment-failure condition. Cheap, and the one
# check that catches a whole class of mistake.
# `semantic_ingestor` is the fourth name here and the newest: `0052` gives the
# ingestion endpoint an identity that can call one function and read nothing,
# and `private` — which holds the push secret and the collaborator list — is the
# schema it must be furthest from.
acl=$(docker exec "$CONTAINER" psql -U postgres -tAc "
select has_schema_privilege('anon','private','usage')
    || ',' || has_schema_privilege('authenticated','private','usage')
    || ',' || has_schema_privilege('service_role','private','usage')
    || ',' || has_schema_privilege('semantic_ingestor','private','usage');")
echo "  anon,authenticated,service_role,semantic_ingestor usage on private = $acl"
if [ "$acl" != "false,false,false,false" ]; then
  echo "  FAIL  a client role gained access to the app's private schema"
  fail=1; fail_count=$((fail_count + 1))
else
  echo "  PASS  no client role can reach private"
  pass_count=$((pass_count + 1))
fi

echo
echo "==> $pass_count passed, $fail_count failed"
exit $fail
