-- 0255 — an unseen term survives as a provisional, whatever door it came in.
--
-- The first real shadow batch produced seven unresolved model mentions —
-- "Souvenir de Florence", "Mahler: Symphony No. 5", an album Written has
-- never heard of — and zero provisionals. `provision_exact_misses` derived
-- the provisional family by joining `provisional_projection_families` on
-- `mention_role`, a catalog authored for the projection-era roles; every
-- model mention carries roles like `channel_core_topic` that the catalog
-- does not name, and the join dropped them silently. **The failure mode of a
-- deny-list is silence**, and this was its join-shaped twin: deny-by-absence
-- with nothing reporting the difference.
--
-- Adding `channel_core_topic` to the catalog would be the wrong repair: one
-- model role spans works, people and groups, so a fixed role→family row
-- would mislabel most of what it admits. The truthful family for a model
-- mention is the model's own `type_hint` — grammar-enforced against the
-- mention family enum, every value of which is already legal in
-- `provisional_entities.family`. Projection mentions keep the catalog route
-- untouched.
--
-- This is the premise lock's first clause made real (owner memo, revised
-- 2026-08-20): no unknown term may silently disappear because a contract
-- assumed `concept_id`. Gate A requires unseen terms to survive as
-- provisional candidates, so this lands with Release A rather than waiting
-- for Day 1.

create or replace function semantic_private.provision_exact_misses(
  p_user_id uuid, p_version uuid)
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
    (scope, user_id, canonical_label, normalized_label, family)
  select distinct on (m.user_id, m.normalized_text, f.family)
         'user', m.user_id, m.mention_text, m.normalized_text, f.family
    from semantic_private.current_mention_resolutions r
    join semantic_private.observation_mentions m
      on m.id = r.mention_id and m.user_id = r.user_id
    join semantic_private.observations o
      on o.id = m.observation_id and o.user_id = m.user_id
    join lateral (
      select f0.family
        from semantic_private.provisional_projection_families f0
       where f0.mention_role = m.mention_role
         and m.extraction_method <> 'model_proposed'
      union all
      select m.type_hint
       where m.extraction_method = 'model_proposed'
         and m.type_hint is not null
    ) f on true
   where r.user_id = p_user_id
     and r.route_id = exact_route
     and r.resolution = 'unresolved'
     and r.evaluated_ontology_version_id = p_version
     and o.lifecycle_state = 'active'
     and o.action_weight > 0
     and m.extraction_method in ('projection_field', 'model_proposed')
     and length(btrim(m.normalized_text)) > 0
   order by m.user_id, m.normalized_text, f.family, m.mention_text
  on conflict (user_id, normalized_label, family)
    where scope = 'user'
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
         and m.extraction_method <> 'model_proposed'
      union all
      select m.type_hint
       where m.extraction_method = 'model_proposed'
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
     and m.extraction_method in ('projection_field', 'model_proposed')
     and length(btrim(m.normalized_text)) > 0
  on conflict do nothing;
  get diagnostics written_rows = row_count;

  minted := minted_rows;
  provisioned := written_rows;
  return next;
end;
$function$;

-- Backfill and assert the transformation, never the precondition: run the
-- repaired function for every account holding unresolved model mentions,
-- then require that none with a usable family remains unprovisioned. On a
-- replay database the loop body never runs and the assertion is vacuously
-- true; in production it is the seven real terms surviving.
do $$
declare
  published_version uuid;
  account uuid;
  leftover integer;
begin
  select id into strict published_version
    from ontology.versions where status = 'published';

  for account in
    select distinct m.user_id
      from semantic_private.current_mention_resolutions r
      join semantic_private.observation_mentions m
        on m.id = r.mention_id and m.user_id = r.user_id
     where r.route_id = 'exact_label'
       and r.resolution = 'unresolved'
       and r.evaluated_ontology_version_id = published_version
       and m.extraction_method = 'model_proposed'
  loop
    perform semantic_private.provision_exact_misses(account, published_version);
  end loop;

  select count(*) into leftover
    from semantic_private.current_mention_resolutions r
    join semantic_private.observation_mentions m
      on m.id = r.mention_id and m.user_id = r.user_id
    join semantic_private.observations o
      on o.id = m.observation_id and o.user_id = m.user_id
   where r.route_id = 'exact_label'
     and r.resolution = 'unresolved'
     and r.evaluated_ontology_version_id = published_version
     and m.extraction_method = 'model_proposed'
     and m.type_hint is not null
     and o.lifecycle_state = 'active'
     and o.action_weight > 0
     and length(btrim(m.normalized_text)) > 0
     and not exists (
       select 1 from semantic_private.mention_resolutions pr
        where pr.mention_id = m.id
          and pr.route_id = 'projection_personal_v1'
          and pr.resolution = 'personal_provisional'
     );
  if leftover > 0 then
    raise exception
      '0255: % unresolved model mention(s) with a usable family still have no provisional',
      leftover;
  end if;
end;
$$;
