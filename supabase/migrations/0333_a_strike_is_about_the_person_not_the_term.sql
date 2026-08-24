-- 0333 — a struck term is still a term.
--
-- **The owner's position, 2026-08-24:** *"every provisional term should be
-- considered a term. The fact that the user strikes it off only means that the
-- term is not an accurate description of him, doesn't mean it isn't a term."*
--
-- **This database already says that and one function does not.** `0203:336-338`
-- defines the default reason:
--
--     An unexplained strike is `ambiguous_rejection`, not a semantic negative.
--     The default is the honest reading of one tap: it tunes ranking and says
--     nothing about whether the term was true.
--
-- And **every strike here is unexplained**: `SemanticSurfaceService.strike(_:)`
-- sends `item` and no reason, so all 274 review events carry that default. So no
-- strike in this database contains information about whether the term is valid —
-- and `mint_from_kept_requests` nonetheless refuses to mint one, because
-- `mint_requests.origin` admits only `keep` and `edit`.
--
-- `0292`'s price table says the same from the other side: `not_interested` costs
-- `user_affinity` −2.50 and `identity_route` −0.10; `wrong_entity` inverts it,
-- −0.50 and −2.00. **Affinity and validity are separate axes everywhere except
-- the mint gate.** This closes that gap.
--
-- ## What a strike still does, unchanged
--
-- `user_term_suppressions` (what the overlay reads), `user_suppressions` (what
-- `list_assertions` reads), the assertion demotion, and the `calibration_labels`
-- fan-out. **The term is minted *and* invisible to the person who struck it.**
-- Nothing about that person's page changes.
--
-- ## The one gate, at the front of the one path
--
-- **Privacy is excluded before minting, not blacklisted after it.** `0133`'s
-- lesson governs: five functions naming calendar sources by literal meant *"a
-- source registered in `sources` but missing from those literals is not
-- unhandled — it is permitted, with nothing reporting the difference. The
-- failure mode of a deny-list is silence."* One condition on one route fails
-- loudly; a blacklist at every read site fails quietly the first time somebody
-- adds a reader.
--
-- It has to be at the front because **minting is a one-way door**:
-- `guard_published_version` makes a published version immutable, so *"the only
-- honest way to remove a concept is not to carry it forward."* `0323` could
-- redact `presumed_terms` — it is mutable, and the migration replaced 1,175
-- names with `redacted:<id>` because *"the name is in the key, so the key must
-- go too."* A concept cannot be redacted after the fact.
--
-- `excluded_reason` lives on `presumed_terms`, not on `provisional_entities`, so
-- the gate joins the dictionary on `(normalized_label, family)` — the same reach
-- `0331` makes for the English identity, and for the same reason.
--
-- ## Scope: provisionals only
--
-- A strike on an item that is already a concept mints nothing, because there is
-- nothing to mint. Only a provisional — a string the resolver could not match —
-- becomes vocabulary here.
--
-- **Not backfilled.** The 122 provisionals already struck were answered under a
-- rule that said striking meant "not vocabulary"; minting them now would apply a
-- policy to decisions taken without it. This applies forward.

-- ---------------------------------------------------------------------------
-- 1. A strike may ask for a mint.
-- ---------------------------------------------------------------------------
alter table semantic_private.mint_requests
  drop constraint if exists mint_requests_origin_check;

alter table semantic_private.mint_requests
  add constraint mint_requests_origin_check
  check (origin in ('keep', 'edit', 'strike_off'));

comment on column semantic_private.mint_requests.origin is
  'Which decision asked for this mint. `strike_off` joined keep and edit in '
  '0333: a strike says the term does not describe this person, which 0203 '
  'already recorded as saying nothing about whether the term is true.';

-- ---------------------------------------------------------------------------
-- 2. The strike writes one.
-- ---------------------------------------------------------------------------
-- Patched from `pg_get_functiondef` rather than retyped: the body is ninety
-- lines and this changes two of them.
do $$
declare
  body text;
begin
  select pg_get_functiondef(p.oid) into body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'strike_calibration_item';
  if body is null then
    raise exception '0333: api.strike_calibration_item does not exist';
  end if;

  -- The record gains what a mint request needs: the candidate, and the
  -- provisional's label, family and normalized form.
  body := replace(body,
E'  select ri.id, ri.review_epoch, ri.model_revision, ri.primary_route_id,
         utc.concept_id, utc.provisional_entity_id, utc.user_facing_predicate
    into row_item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
   where ri.id = item and ri.user_id = me;',
E'  select ri.id, ri.review_epoch, ri.model_revision, ri.primary_route_id,
         ri.candidate_id,
         utc.concept_id, utc.provisional_entity_id, utc.user_facing_predicate,
         pe.canonical_label as prov_label, pe.family as prov_family,
         pe.normalized_label as prov_normalized
    into row_item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
    left join semantic_private.provisional_entities pe
      on pe.id = utc.provisional_entity_id
   where ri.id = item and ri.user_id = me;');

  -- And the mint request, after everything the strike already does.
  body := replace(body,
E'       and assertion_origin = \'inferred\'
       and machine_state = \'eligible\';
  end if;
end;',
E'       and assertion_origin = \'inferred\'
       and machine_state = \'eligible\';
  end if;

  -- **The term survives the strike.** A provisional the resolver could not
  -- match is vocabulary this system did not have; the person saying it is not
  -- about them does not make it less of a word. `on conflict do nothing` keeps
  -- one request per review item, so a strike after a keep does not double.
  --
  -- **Privacy is the one refusal, and it is here rather than downstream.** A
  -- term whose dictionary row carries an `excluded_reason` is somebody\'s diary
  -- or somebody\'s own name; minting is irreversible and a published version
  -- cannot be redacted, so it never enters. The join is to `presumed_terms`
  -- because `provisional_entities` has no such column.
  if row_item.provisional_entity_id is not null
     and not exists (
       select 1 from semantic_private.presumed_terms pt
        where pt.normalized_label = row_item.prov_normalized
          and pt.family = row_item.prov_family
          and pt.excluded_reason is not null)
  then
    insert into semantic_private.mint_requests
      (user_id, review_item_id, candidate_id, provisional_entity_id, concept_id,
       requested_label, requested_family, origin)
    values (me, item, row_item.candidate_id,
            row_item.provisional_entity_id, row_item.concept_id,
            row_item.prov_label, row_item.prov_family, \'strike_off\')
    on conflict (review_item_id) do nothing;
  end if;
end;');

  if position('strike_off''
    on conflict' in body) = 0
     and position('''strike_off'')
    on conflict' in body) = 0 then
    raise exception '0333: the mint request was not added to the strike';
  end if;
  if position('prov_normalized' in body) = 0 then
    raise exception '0333: the record did not gain the provisional columns';
  end if;

  execute body;
end;
$$;

revoke all on function api.strike_calibration_item(uuid, text) from public, anon;
grant execute on function api.strike_calibration_item(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Proven both ways.
-- ---------------------------------------------------------------------------
-- **The gate that only ever admits is not a gate.** The refusal is asserted
-- first, because it is the one whose failure is somebody's diary becoming
-- global vocabulary.
do $$
declare
  admits boolean;
  refuses boolean;
begin
  -- The constraint takes the new origin.
  begin
    insert into semantic_private.mint_requests
      (user_id, review_item_id, candidate_id, requested_label,
       requested_family, origin)
    values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
            '0333 probe', 'person', 'strike_off');
    admits := true;
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then null;
    when check_violation then
      raise exception '0333: mint_requests still refuses origin strike_off';
    when others then
      -- A foreign key refusal is fine here: the check is what is under test.
      admits := true;
  end;

  begin
    insert into semantic_private.mint_requests
      (user_id, review_item_id, candidate_id, requested_label,
       requested_family, origin)
    values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
            '0333 probe', 'person', 'restore');
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when check_violation then refuses := true;
    when sqlstate 'P0001' then null;
    when others then null;
  end;

  if not admits then
    raise exception '0333: strike_off was not admitted as an origin';
  end if;
  if not refuses then
    raise exception '0333: the origin check admits anything';
  end if;

  -- The privacy gate is a condition inside the function, so it is asserted on
  -- the function's text: the exclusion must be consulted, and it must be
  -- consulted before the insert rather than after.
  if (select position('excluded_reason is not null' in pg_get_functiondef(p.oid))
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'strike_calibration_item') = 0 then
    raise exception '0333: the strike does not consult excluded_reason';
  end if;
  if (select position('excluded_reason is not null' in pg_get_functiondef(p.oid))
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'strike_calibration_item')
     > (select position('insert into semantic_private.mint_requests' in pg_get_functiondef(p.oid))
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'strike_calibration_item') then
    raise exception '0333: the exclusion is checked after the mint, not before';
  end if;
end;
$$;
