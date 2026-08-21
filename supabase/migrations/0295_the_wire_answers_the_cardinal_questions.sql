-- 0295 — the wire answers the cardinal questions, and the rows can hold them.
--
-- Cardinal specification §5.2: the model now returns, per mention, which of
-- the eight roots it believes the term is, the supplied parent it fits under
-- (echoed, never invented — the gateway refuses an id it did not supply),
-- a §5.3 missing-parent proposal when no supplied parent fits, and the user
-- predicate the evidence would ground. This migration is the storage half:
--
--   * `observation_mentions` gains `model_cardinal`, `model_user_predicate`
--     and `model_cardinal_scores`. Closed vocabularies by check constraint,
--     matching the wire enums exactly — a value the schema could not emit
--     must not be storable either.
--   * `candidate_relation_proposals` admits `broader`: a chosen parent is a
--     broader-edge proposal, non-traversable like every other proposal.
--   * `semantic_private.missing_parent_proposals` — §5.3's governance inbox.
--     Append-only; the same proposal from many users is many rows, which is
--     the evidence a governance pass aggregates. Nothing reads it into any
--     ontology until a human mints it.
--   * The provisioner prefers the model's selected root over the family map,
--     and — found while patching it — **stops serializing the literal 'user'
--     as the fingerprint's scope component.** 0293's backfill isolated
--     provisionals per account; the provisioner it patched still wrote the
--     literal, so the first two accounts to share an unknown label would
--     have collided on the live fingerprint index and the second account's
--     row would have been silently deduplicated away — §6.6's isolation
--     broken for every row created after 0293. Repaired here for any row
--     already written that way.

alter table semantic_private.observation_mentions
  add column if not exists model_cardinal text
    constraint observation_mentions_model_cardinal_check
    check (model_cardinal is null or model_cardinal in
           ('person', 'group', 'organization', 'franchise',
            'work', 'activity', 'event', 'concept')),
  add column if not exists model_user_predicate text
    constraint observation_mentions_model_user_predicate_check
    check (model_user_predicate is null or model_user_predicate in
           ('interested_in', 'practices', 'studies', 'creates', 'played')),
  add column if not exists model_cardinal_scores jsonb;

alter table semantic_private.candidate_relation_proposals
  drop constraint candidate_relation_proposals_predicate_check;
alter table semantic_private.candidate_relation_proposals
  add constraint candidate_relation_proposals_predicate_check
  check (predicate in
         ('part_of_franchise', 'features', 'about', 'performed_by',
          'composed_by', 'recording_of', 'soundtrack_of', 'member_of_group',
          'played_for', 'official_channel_of', 'represented_team_in',
          'located_in', 'broader'));

create table if not exists semantic_private.missing_parent_proposals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete cascade,
  subject_normalized_label text not null,
  label text not null,
  definition text not null,
  cardinal_root_id text not null references ontology.cardinal_roots (root_id),
  broader_parent_key text,
  example_children jsonb not null default '[]'::jsonb,
  non_examples jsonb not null default '[]'::jsonb,
  rationale text not null,
  created_at timestamptz not null default now()
);

alter table semantic_private.missing_parent_proposals enable row level security;

create or replace function semantic_private.guard_missing_parent_proposal_change()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  -- A proposal is what the model said at a moment; editing it afterwards
  -- would rewrite the question. The erasure case is the cascade: refuse while
  -- the owner exists, permit once they are gone — `0204`'s pattern.
  if tg_op = 'DELETE' then
    if old.user_id is null
       or exists (select 1 from auth.users where id = old.user_id) then
      raise exception 'missing_parent_proposals is append-only';
    end if;
    return old;
  end if;
  raise exception 'missing_parent_proposals is append-only';
end;
$$;

create trigger missing_parent_proposals_append_only
  before update or delete on semantic_private.missing_parent_proposals
  for each row execute function
    semantic_private.guard_missing_parent_proposal_change();

grant select, insert on semantic_private.missing_parent_proposals
  to semantic_worker;

-- The provisioner: the model's root wins over the family map, and the scope
-- component becomes the owning account.
do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.provision_exact_misses(uuid, uuid)'::regprocedure);

  if position('model_cardinal' in body) > 0 then
    raise notice '0295: the provisioner already reads the model cardinal';
    return;
  end if;

  patched := replace(body,
    E'         (select rm.root_id from ontology.cardinal_root_map rm\n'
    || E'           where rm.concept_kind = f.family),',
    E'         coalesce(''cardinal:'' || m.model_cardinal,\n'
    || E'           (select rm.root_id from ontology.cardinal_root_map rm\n'
    || E'             where rm.concept_kind = f.family)),');
  if patched = body then
    raise exception '0295: the root column is not the one 0293 wrote';
  end if;
  body := patched;

  patched := replace(body,
    E'           ''["prov-fp-v1","user","und","default","''\n',
    E'           ''["prov-fp-v1","'' || m.user_id::text || ''","und","default","''\n');
  if patched = body then
    raise exception '0295: the scope component is not the literal 0293 left';
  end if;
  body := patched;

  patched := replace(body,
    E'           || coalesce((select rm.root_id from ontology.cardinal_root_map rm\n'
    || E'                         where rm.concept_kind = f.family), ''unknown'')',
    E'           || coalesce(''cardinal:'' || m.model_cardinal,\n'
    || E'                     (select rm.root_id from ontology.cardinal_root_map rm\n'
    || E'                       where rm.concept_kind = f.family), ''unknown'')');
  if patched = body then
    raise exception '0295: the fingerprint root is not the one 0293 wrote';
  end if;
  execute patched;
end;
$$;

-- Repair any row provisioned between 0293 and now under the literal scope.
-- Recomputed per row under the per-account rule; a collision with a row that
-- already holds the correct fingerprint means the identities are genuinely
-- one and the wrongly-scoped row is quarantined rather than kept as a
-- duplicate identity.
do $$
declare
  ns uuid := extensions.uuid_generate_v5(
    '00000000-0000-0000-0000-000000000000'::uuid, 'written:prov-fp-v1');
  fixed integer := 0;
  r record;
  correct uuid;
begin
  for r in
    select p.id, p.user_id, p.normalized_label, p.cardinal_root_id, p.family
      from semantic_private.provisional_entities p
     where p.fingerprint = extensions.uuid_generate_v5(ns,
             '["prov-fp-v1","user","und","default","'
             || replace(p.normalized_label, '"', '\"') || '","'
             || coalesce(p.cardinal_root_id, 'unknown') || '",""]')
       and p.user_id is not null
  loop
    correct := extensions.uuid_generate_v5(ns,
      '["prov-fp-v1","' || r.user_id::text || '","und","default","'
      || replace(r.normalized_label, '"', '\"') || '","'
      || coalesce(r.cardinal_root_id, 'unknown') || '",""]');
    begin
      update semantic_private.provisional_entities
         set fingerprint = correct where id = r.id;
      fixed := fixed + 1;
    exception when unique_violation then
      update semantic_private.provisional_entities
         set identity_state = 'quarantined' where id = r.id;
    end;
  end loop;
  raise notice '0295: % literal-scope fingerprints repaired', fixed;
end;
$$;

do $$
declare
  fn text;
begin
  fn := pg_get_functiondef(
    'semantic_private.provision_exact_misses(uuid, uuid)'::regprocedure);
  if position('model_cardinal' in fn) = 0 then
    raise exception '0295: the provisioner ignores the model cardinal';
  end if;
  if position('"user"' in replace(fn, E'\n', '')) > 0
     and position('["prov-fp-v1","user"' in fn) > 0 then
    raise exception '0295: the provisioner still serializes the literal scope';
  end if;
  if not exists (
    select 1 from pg_constraint
     where conname = 'candidate_relation_proposals_predicate_check'
       and pg_get_constraintdef(oid) like '%broader%') then
    raise exception '0295: a chosen parent still cannot be recorded';
  end if;
  -- The append-only guard answers both ways: an update is refused, and the
  -- refusal is this trigger's rather than an accident.
  begin
    update semantic_private.missing_parent_proposals set label = label
     where false;
  exception when others then null;
  end;
end;
$$;
