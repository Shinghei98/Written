-- 0395 — a second sighting is not a second identity.
--
-- **The owner's re-run of the worker stages failed on a duplicate key:**
-- `provisional_entities_live_identity_idx`, key ("again ep", album). The
-- rule it violated is the one 0233's index comment states in so many
-- words — *"Any upsert must repeat this predicate exactly"* — and
-- `provision_exact_misses` no longer does: its `on conflict` target
-- drifted to the fingerprint index (0295's cardinal rework put the root
-- inside the fingerprint), so a mention whose (user, label, family)
-- identity already lives but whose fingerprint differs — the model now
-- names a cardinal the first sighting lacked — matches neither the
-- conflict target nor nothing, and the identity index raises. The stage
-- dies, and everything behind it in the run never executes.
--
-- The repair is not to widen the conflict clause (Postgres accepts one
-- target) but to stop proposing the row at all: a live identity already
-- standing means the mint is not needed — the second half of the same
-- function already joins resolutions to the existing provisional by
-- identity, which is the deterministic re-resolution the Qwen rule
-- demands ("future occurrences resolve to it deterministically without a
-- second provisional"). The fingerprint conflict target stays for what it
-- still catches: two families sharing a fingerprint within one batch.
--
-- Everything else in the function is 0295's text, verbatim.

begin;

create or replace function semantic_private.provision_exact_misses(p_user_id uuid, p_version uuid)
returns table(minted integer, provisioned integer)
language plpgsql
set search_path to ''
as $function$
declare
  exact_route  constant text := 'exact_label';
  fallback     constant text := 'projection_personal_v1';
  minted_rows  integer := 0;
  written_rows integer := 0;
begin
  -- Identities first, verdicts second — unchanged from 0234, and for the
  -- same reasons (the conflict target is the point; ids are resolved by
  -- lookup, not from `returning`).
  --
  -- **The family now depends on the door the mention came through.** A
  -- projection mention's family is what the role catalog says, exactly as
  -- 0234 built it. A model mention's family is its own `type_hint`: the
  -- grammar constrained it to the mention family enum at generation time,
  -- and a role-keyed catalog cannot speak for a role that spans works,
  -- people and groups at once. The lateral emits zero rows when neither door
  -- answers, which keeps the fail-closed property: an unmappable mention is
  -- still dropped, but now only when it is genuinely unmappable rather than
  -- merely model-shaped.
  insert into semantic_private.provisional_entities
    (scope, user_id, canonical_label, normalized_label, family,
     cardinal_root_id, fingerprint)
  select distinct on (m.user_id, m.normalized_text, f.family)
         'user', m.user_id, m.mention_text, m.normalized_text, f.family,
         coalesce('cardinal:' || m.model_cardinal,
           (select rm.root_id from ontology.cardinal_root_map rm
             where rm.concept_kind = f.family)),
         extensions.uuid_generate_v5('3dbea9ee-fc4e-539d-87b3-65b9baa53ac7'::uuid,
           '["prov-fp-v1","' || m.user_id::text || '","und","default","'
           || replace(m.normalized_text, '"', '\"') || '","'
           || coalesce('cardinal:' || m.model_cardinal,
                     (select rm.root_id from ontology.cardinal_root_map rm
                       where rm.concept_kind = f.family), 'unknown')
           || '",""]')
    from semantic_private.current_mention_resolutions r
    join semantic_private.observation_mentions m
      on m.id = r.mention_id and m.user_id = r.user_id
    join semantic_private.observations o
      on o.id = m.observation_id and o.user_id = m.user_id
    join lateral (
      select f0.family
        from semantic_private.provisional_projection_families f0
       where f0.mention_role = m.mention_role
         and m.extraction_method not in ('model_proposed', 'model_inferred')
      union all
      select m.type_hint
       where m.extraction_method in ('model_proposed', 'model_inferred')
         and m.type_hint is not null
    ) f on true
   where r.user_id = p_user_id
     and r.route_id = exact_route
     and r.resolution = 'unresolved'
     and r.evaluated_ontology_version_id = p_version
     and o.lifecycle_state = 'active'
     and o.action_weight > 0
     and m.extraction_method in ('projection_field', 'model_proposed', 'model_inferred')
     and length(btrim(m.normalized_text)) > 0
     -- 0395: a live identity already standing is this mention's answer,
     -- not a row to mint. The predicate repeats
     -- provisional_entities_live_identity_idx exactly, as 0233 requires.
     and not exists (
       select 1 from semantic_private.provisional_entities pe
        where pe.user_id = m.user_id
          and pe.normalized_label = m.normalized_text
          and pe.family = f.family
          and pe.scope = 'user'
          and pe.identity_state <> 'quarantined'
          and pe.redirect_concept_id is null)
   order by m.user_id, m.normalized_text, f.family, m.mention_text
  on conflict (fingerprint)
    where fingerprint is not null
      and identity_state <> 'quarantined'
      and redirect_concept_id is null
  do nothing;
  get diagnostics minted_rows = row_count;

  insert into semantic_private.mention_resolutions
    (user_id, mention_id, resolution, ontology_version_id, concept_id,
     provisional_entity_id, route_id, resolver_version, confidence,
     evaluated_ontology_version_id)
  select m.user_id, m.id, 'personal_provisional', null, null,
         p.id, fallback, fallback, 0.0, p_version
    from semantic_private.current_mention_resolutions r
    join semantic_private.observation_mentions m
      on m.id = r.mention_id and m.user_id = r.user_id
    join semantic_private.observations o
      on o.id = m.observation_id and o.user_id = m.user_id
    join lateral (
      select f0.family
        from semantic_private.provisional_projection_families f0
       where f0.mention_role = m.mention_role
         and m.extraction_method not in ('model_proposed', 'model_inferred')
      union all
      select m.type_hint
       where m.extraction_method in ('model_proposed', 'model_inferred')
         and m.type_hint is not null
    ) f on true
    join semantic_private.provisional_entities p
      on p.user_id = m.user_id
     and p.normalized_label = m.normalized_text
     and p.family = f.family
     and p.scope = 'user'
     and p.identity_state <> 'quarantined'
     and p.redirect_concept_id is null
   where r.user_id = p_user_id
     and r.route_id = exact_route
     and r.resolution = 'unresolved'
     and r.evaluated_ontology_version_id = p_version
     and o.lifecycle_state = 'active'
     and o.action_weight > 0
     and m.extraction_method in ('projection_field', 'model_proposed', 'model_inferred')
     and length(btrim(m.normalized_text)) > 0
  on conflict do nothing;
  get diagnostics written_rows = row_count;

  minted := minted_rows;
  provisioned := written_rows;
  return next;
end;
$function$;

commit;
