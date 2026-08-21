-- 0291 — the eight immutable cardinal roots, and every concept knows its own.
--
-- Cardinal Ontology specification (owner, 2026-08-21, binding), workstream 1.
-- A cardinal root is the top-level ontological kind: person, group,
-- organization, work, franchise, activity, concept, event. Roots are schema
-- constants, never vocabulary — Qwen selects from the registry and can no
-- more invent a ninth than rename the eighth, and a root change is a schema
-- migration outside the model path by construction.
--
-- **Overlay, not rebuild.** The versioned ontology — 154k edges, seventeen
-- concept kinds, every guard and reader keyed on them — is not replaced; the
-- roots are laid over it. `concept_kind` keeps meaning what it means (the
-- spec's own migration table says to preserve the former type as subtype
-- metadata), and each concept *additionally* knows its cardinal root, stored
-- per revision so a root correction is an ordinary revision act. The kind→root
-- map is data with a stated default per kind, because seventeen kinds do not
-- decide sixteen thousand terms: `creator` defaults to person and a band is
-- corrected per-term, which the spec's own sports-collective test demands
-- (never persist an either/or as a root value).

create table if not exists ontology.cardinal_roots (
  root_id text primary key check (root_id like 'cardinal:%'),
  label text not null,
  definition text not null,
  schema_version text not null default 'cardinal-v2',
  immutable boolean not null default true check (immutable)
);

insert into ontology.cardinal_roots (root_id, label, definition) values
  ('cardinal:person', 'Person', 'A natural individual.'),
  ('cardinal:group', 'Group',
   'A named collective whose collective identity or membership matters.'),
  ('cardinal:organization', 'Organization',
   'A durable institutional, legal, commercial, educational, or governing body.'),
  ('cardinal:work', 'Work',
   'A bounded authored, recorded, published, designed, or released creation.'),
  ('cardinal:franchise', 'Franchise',
   'A persistent intellectual-property, continuity, or branded universe spanning one or more works.'),
  ('cardinal:activity', 'Activity',
   'A repeatable human practice, skill, hobby, sport, or mode of doing.'),
  ('cardinal:concept', 'Concept',
   'An abstract subject, discipline, method, theory, style, movement, or idea.'),
  ('cardinal:event', 'Event',
   'A time-bounded public occurrence or eligible public occurrence identity.')
on conflict (root_id) do nothing;

-- **Exactly eight, forever.** Insert and delete both raise; the check above
-- already refuses un-immutable rows.
create or replace function ontology.cardinal_roots_are_immutable()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  raise exception 'the eight cardinal roots are schema constants; a change is a migration, not a write';
end;
$$;

drop trigger if exists cardinal_roots_immutable on ontology.cardinal_roots;
create trigger cardinal_roots_immutable
  before insert or update or delete on ontology.cardinal_roots
  for each row execute function ontology.cardinal_roots_are_immutable();

-- ---------------------------------------------------------------------------
-- The kind → root map: data, with the spec's own migration table as content.
-- ---------------------------------------------------------------------------

create table if not exists ontology.cardinal_root_map (
  concept_kind text primary key,
  root_id text references ontology.cardinal_roots(root_id),
  -- Why this kind maps where it does, or why it deliberately maps nowhere.
  rationale text not null
);

insert into ontology.cardinal_root_map (concept_kind, root_id, rationale) values
  ('creator', 'cardinal:person',
   'Backfill default; a creator that is a band or collective is corrected to group per term, never per kind.'),
  ('work', 'cardinal:work', 'Direct.'),
  ('event', 'cardinal:event', 'Direct.'),
  ('organization', 'cardinal:organization', 'Direct.'),
  ('activity', 'cardinal:activity', 'Direct.'),
  ('sport', 'cardinal:activity', 'Spec 2.2: sport is activity, with sport as a middle parent.'),
  ('routine', 'cardinal:activity', 'A repeatable practice derived from behaviour.'),
  ('topic', 'cardinal:concept', 'An abstract subject.'),
  ('genre', 'cardinal:concept', 'Spec 2.2: genre is a reusable conceptual parent.'),
  ('culture', 'cardinal:concept', 'Spec 2.2.'),
  ('language', 'cardinal:concept', 'An abstract subject, not a place or a people.'),
  ('cuisine', 'cardinal:concept', 'An abstract subject.'),
  ('medium', 'cardinal:concept', 'A mode or form, conceptually held.'),
  ('hub', null,
   'Structural navigation, not vocabulary; spec 2.2 keeps it as parent or metadata.'),
  ('place', null,
   'Spec 2.2: no Release A cardinal coercion; structured location attributes stay attributes.'),
  ('affinity', null, 'An internal scoring kind, not a term anyone is shown.'),
  ('identity', null, 'Internal.'),
  ('quantitative_feature', null, 'Internal.')
on conflict (concept_kind) do nothing;

-- ---------------------------------------------------------------------------
-- Every concept knows its root, in an unversioned overlay.
-- ---------------------------------------------------------------------------
--
-- The first draft added a column to `concept_revisions` and the immutability
-- guard refused the backfill, correctly: published revisions never change.
-- The root is not versioned vocabulary — it is closer to identity, the same
-- distinction `identity is not vocabulary` already draws for the external
-- registry. A term's root assignment survives every ontology version, and
-- correcting it is an explicit act on this table with the spec's
-- wrong_cardinal semantics, never a silent revision edit.

create table if not exists ontology.concept_cardinal_roots (
  concept_id uuid primary key references ontology.concepts(id) on delete cascade,
  root_id text not null references ontology.cardinal_roots(root_id),
  -- 'kind_default' for the backfill; a per-term correction records its actor.
  assigned_by text not null default 'kind_default',
  assigned_at timestamptz not null default now()
);

insert into ontology.concept_cardinal_roots (concept_id, root_id)
select distinct on (cr.concept_id) cr.concept_id, m.root_id
  from ontology.concept_revisions cr
  join ontology.versions v on v.id = cr.ontology_version_id
  join ontology.cardinal_root_map m on m.concept_kind = cr.concept_kind
 where m.root_id is not null
 order by cr.concept_id, v.created_at desc
on conflict (concept_id) do nothing;

grant select on ontology.concept_cardinal_roots to semantic_worker;

-- ---------------------------------------------------------------------------
-- The predicate registry gains the spec''s propagation columns.
-- ---------------------------------------------------------------------------
--
-- `relation_types` already holds the closed registry; the spec adds what
-- propagation needs: λ, reverse λ, the authority floor, the relation-
-- confidence floor, and which user predicates an edge may nominate. Defaults
-- are the conservative reading — λ 0 propagates nothing, which is exactly
-- right for every predicate the spec does not name.

alter table ontology.relation_types
  add column if not exists propagation_weight numeric not null default 0
    check (propagation_weight between 0 and 1),
  add column if not exists reverse_propagation_weight numeric not null default 0
    check (reverse_propagation_weight between 0 and 1),
  add column if not exists minimum_propagation_authority text not null default 'verified'
    check (minimum_propagation_authority in
           ('proposed', 'displayable', 'supported', 'verified')),
  add column if not exists minimum_relation_confidence numeric not null default 0.65
    check (minimum_relation_confidence between 0 and 1),
  add column if not exists may_propagate_user_predicates text[] not null
    default '{}'::text[],
  add column if not exists registry_version text not null default 'predicate-v1';

-- The spec''s Table 1 semantic predicates, inserted where missing and λ-set
-- where present. Domain/range live in the grammar sheet and the proposal
-- table''s check; here the registry carries the propagation contract.
insert into ontology.relation_types
  (predicate_key, relation_class, is_symmetric, transitive_for_inference,
   max_inference_hops, assertion_safe, description,
   propagation_weight, minimum_propagation_authority, registry_version,
   may_propagate_user_predicates)
values
  ('part_of_franchise', 'descriptive', false, false, 1, false,
   'A work or event belongs to a persistent IP universe (Cardinal spec Table 1).',
   0.45, 'supported', 'predicate-v2.0', array['interested_in']),
  ('exemplifies', 'descriptive', false, false, 1, false,
   'A work exemplifies a concept, style, or movement.',
   0.40, 'supported', 'predicate-v2.0', array['interested_in']),
  ('draws_on', 'descriptive', false, false, 1, false,
   'A concept, work, or activity draws on a concept. Directional; no reverse propagation.',
   0.20, 'supported', 'predicate-v2.0', array['interested_in']),
  ('recording_of', 'descriptive', false, false, 1, false,
   'A recording realizes a composition.',
   0.55, 'verified', 'predicate-v2.0', array['interested_in']),
  ('soundtrack_of', 'descriptive', false, false, 1, false,
   'A work is the soundtrack of another work or franchise. Never implies watched or played.',
   0.25, 'supported', 'predicate-v2.0', array['interested_in']),
  ('member_of_group', 'descriptive', false, false, 1, false,
   'A person belongs to a named collective, time-scoped.',
   0.25, 'supported', 'predicate-v2.0', array['interested_in']),
  ('played_for', 'descriptive', false, false, 1, false,
   'A person played for an organization or group, time-scoped.',
   0.25, 'supported', 'predicate-v2.0', array['interested_in']),
  ('represented_team_in', 'descriptive', false, false, 1, false,
   'A person or group represented a side in an event.',
   0.25, 'supported', 'predicate-v2.0', array['interested_in']),
  ('official_channel_of', 'descriptive', false, false, 0, false,
   'A source channel is the official channel of a term. Evidence-class link.',
   0.00, 'verified', 'predicate-v2.0', '{}'::text[]),
  ('composed_by', 'descriptive', false, false, 1, false,
   'A work was composed by a person.',
   0.30, 'supported', 'predicate-v2.0', array['interested_in']),
  ('interested_in', 'user_claim', false, false, 0, true,
   'The generic, source-agnostic user affinity; the safest default candidate.',
   0.00, 'verified', 'predicate-v2.0', '{}'::text[]),
  ('practices', 'user_claim', false, false, 0, true,
   'The user does the activity. Requires explicit confirmation or genuine doing evidence.',
   0.00, 'verified', 'predicate-v2.0', '{}'::text[]),
  ('studies', 'user_claim', false, false, 0, true,
   'The user formally studies the concept. Interest is not study.',
   0.00, 'verified', 'predicate-v2.0', '{}'::text[]),
  ('creates', 'user_claim', false, false, 0, true,
   'The user authors works. Never inferred from consumption.',
   0.00, 'verified', 'predicate-v2.0', '{}'::text[]),
  ('played', 'user_claim', false, false, 0, false,
   'A true timestamped provider play or explicit confirmation; snapshots and counters are insufficient.',
   0.00, 'verified', 'predicate-v2.0', '{}'::text[])
on conflict (predicate_key) do nothing;

-- λ for predicates that already existed and the spec prices.
update ontology.relation_types set
  propagation_weight = v.lambda,
  minimum_propagation_authority = v.floor_authority,
  registry_version = 'predicate-v2.0',
  may_propagate_user_predicates = array['interested_in']
from (values
  ('about', 0.35, 'proposed'),
  ('features', 0.35, 'supported'),
  ('created_by', 0.35, 'supported'),
  ('performed_by', 0.30, 'supported')
) as v(key, lambda, floor_authority)
where relation_types.predicate_key = v.key;

-- Taxonomy coefficients, as configuration beside the parameters 0257 seeded:
-- λ_parent for a non-root edge, λ_root for the terminal cardinal edge.
insert into semantic_private.calibration_parameters
  (version, alpha, beta, min_distinct_users, min_multiplier, max_multiplier,
   backoff_order)
select 'cardinal_v2', 4, 4, 5, 0.5, 1.5,
       array['target_domain,source_code,action_type,mention_family,mention_role,cardinal,user_predicate',
             'target_domain,source_code,action_type,cardinal,mention_role,user_predicate',
             'target_domain,source_code,cardinal,user_predicate',
             'target_domain,cardinal,user_predicate']
where not exists (select 1 from semantic_private.calibration_parameters
                   where version = 'cardinal_v2');

-- ---------------------------------------------------------------------------
-- Stable provisional fingerprints (spec 6.6).
-- ---------------------------------------------------------------------------
--
-- The fingerprint is UUIDv5 over (scope, language, namespace, normalized
-- label, root-or-unknown, sense-key-or-empty) — parent, lane, evidence and
-- model versions excluded, so the same validated unknown reuses one
-- provisional across YouTube, Music, Events, retries and model upgrades, and
-- a wrong-parent edit reclassifies the same identity. Computed in the worker
-- (Python owns the normalisation) and stored here; unique among live rows so
-- two lanes racing on one noun meet one row.

alter table semantic_private.provisional_entities
  add column if not exists fingerprint uuid;

create unique index if not exists provisional_entities_fingerprint_live_idx
  on semantic_private.provisional_entities (fingerprint)
  where fingerprint is not null
    and identity_state <> 'quarantined'
    and redirect_concept_id is null;

comment on column semantic_private.provisional_entities.fingerprint is
  'UUIDv5 over (prov-fp-v1, scope, language, namespace, normalized_label, '
  'root-or-unknown, sense-key-or-empty), spec 6.6. Lane, parent and model '
  'versions are excluded so identity survives all of them (0291).';

-- ---------------------------------------------------------------------------
-- Both ways.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
begin
  select count(*) into n from ontology.cardinal_roots;
  if n <> 8 then
    raise exception '0291: % cardinal roots; the spec says exactly eight', n;
  end if;

  begin
    insert into ontology.cardinal_roots (root_id, label, definition)
    values ('cardinal:vibes', 'Vibes', 'Not a root.');
    raise exception '0291: a ninth root was admitted';
  exception when raise_exception then
    if position('schema constants' in sqlerrm) = 0 then raise; end if;
  end;

  -- Every kind the revisions actually use is mapped — deliberately to a root
  -- or deliberately to null — so a new kind added later without a mapping
  -- fails here rather than silently shipping unrooted terms.
  select count(*) into n
    from (select distinct concept_kind from ontology.concept_revisions) k
   where not exists (select 1 from ontology.cardinal_root_map m
                      where m.concept_kind = k.concept_kind);
  if n > 0 then
    raise exception '0291: % concept kind(s) have no cardinal mapping', n;
  end if;

  -- And every concept whose newest kind maps to a root carries one.
  select count(*) into n
    from (select distinct on (cr.concept_id) cr.concept_id, cr.concept_kind
            from ontology.concept_revisions cr
            join ontology.versions v on v.id = cr.ontology_version_id
           order by cr.concept_id, v.created_at desc) latest
    join ontology.cardinal_root_map m on m.concept_kind = latest.concept_kind
   where m.root_id is not null
     and not exists (select 1 from ontology.concept_cardinal_roots r
                      where r.concept_id = latest.concept_id);
  if n > 0 then
    raise exception '0291: % concept(s) of rooted kinds carry no root', n;
  end if;

  -- The registry prices the spec's semantic predicates.
  select count(*) into n from ontology.relation_types
   where registry_version = 'predicate-v2.0' and propagation_weight > 0;
  if n < 10 then
    raise exception '0291: only % priced predicates; Table 1 names more', n;
  end if;
end;
$$;
