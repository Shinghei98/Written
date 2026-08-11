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
  psql_app < "$MIGRATIONS/$1" >/dev/null 2>&1 || { echo "  APPLY FAILED  $1"; fail=1; return 1; }
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
# Again, with the bridge and the captured event trigger in place: 0048 rewrites
# `finalize_ingestion_run_v031`, which is the function this contract is built
# around, so "0048 broke nothing" is a claim worth re-testing rather than
# assuming.
run_contract 0047_current_state_and_surface_hardening_contract

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
acl=$(docker exec "$CONTAINER" psql -U postgres -tAc "
select has_schema_privilege('anon','private','usage')
    || ',' || has_schema_privilege('authenticated','private','usage')
    || ',' || has_schema_privilege('service_role','private','usage');")
echo "  anon,authenticated,service_role usage on private = $acl"
if [ "$acl" != "false,false,false" ]; then
  echo "  FAIL  a client role gained access to the app's private schema"
  fail=1; fail_count=$((fail_count + 1))
else
  echo "  PASS  no client role can reach private"
  pass_count=$((pass_count + 1))
fi

echo
echo "==> $pass_count passed, $fail_count failed"
exit $fail
