-- 0233 — a provisional needs an identity, and a strike has to survive becoming one.
--
-- Nothing writes `semantic_private.provisional_entities` yet. That is why this
-- lands now: every defect below is latent while the table is empty and immediate
-- the moment a sink fills it, and two of them lose somebody's answer about
-- themselves rather than merely misbehaving.
--
-- ## 1. There is no natural identity
--
-- The table has `provisional_entities_lookup_idx` on `(normalized_label,
-- family)` and it is **not unique**. Two concurrent resolutions of the same
-- string would mint two identities for one noun, and a retry would mint a third.
-- Worse, there is no `on conflict` target to upsert against, so the sink has no
-- way to converge that is not a read-then-write race.
--
-- The key is `(user_id, normalized_label, family)` over the rows that are still
-- a live identity, and the three exclusions are decisions rather than tidying:
--
-- - **`scope = 'user'`.** A shared provisional carries a stable external
--   identifier and is a different question; it is not one person's unresolved
--   noun and must not collide with one.
-- - **`identity_state <> 'quarantined'`.** Quarantine is what `api.forget_distillation`
--   does — the row survives because `mention_resolutions` references it, but the
--   person asked for the data to be gone. A later distillation must be able to
--   mint the same label again; blocking it would make an erasure permanent in
--   the one direction the person did not ask for.
-- - **`redirect_concept_id is null`.** A redirected provisional has become a
--   concept and is history. It must not block, and it must not be revived.
--
-- **The predicate is repeated exactly in whatever upserts against it.** A
-- partial index whose predicate the writer restates loosely is an index the
-- writer does not actually use.
--
-- ## 2. A strike does not survive the merge
--
-- `0229` carries `user_term_suppressions` across a redirect — *may this be
-- reviewed again* — and stops there. `0230` established that
-- `api.list_assertions` reads `user_suppressions` instead, and that the
-- calibration strike writes both. But a **provisional** strike writes only the
-- first, because there is no concept to name in the second, and `0230`'s write
-- is gated on `row_item.concept_id is not null`.
--
-- So: strike a provisional, let it later resolve to a canonical concept, and the
-- assertion on that concept is drawn on the person's Memories page. The guard
-- keeps it out of `eligible` and `list_assertions` admits `candidate` too, which
-- `0230:46-48` already says is not enough on its own.
--
-- The redirect is the moment the concept first exists, so it is the moment the
-- second record can be written, and this teaches the trigger to write it.
--
-- **It fails closed on a suppression with no strike behind it.** `user_suppressions.source_feedback_event_id`
-- is `not null` and means *which feedback caused this* — `0231` is the migration
-- that had to supply it — so a suppression the trigger cannot attribute is not
-- one to invent a Memories record for. Carrying it silently would hide a claim
-- for a reason nobody could later read; skipping it silently would show one. It
-- raises instead.
--
-- Nothing here writes a provisional. The sink is the next commit; this is the
-- floor it stands on.

-- ---------------------------------------------------------------------------
-- 1. One live identity per person, label and family.
-- ---------------------------------------------------------------------------

create unique index if not exists provisional_entities_live_identity_idx
  on semantic_private.provisional_entities (user_id, normalized_label, family)
  where scope = 'user'
    and identity_state <> 'quarantined'
    and redirect_concept_id is null;

comment on index semantic_private.provisional_entities_live_identity_idx is
  'One live user-scoped identity per (user, normalized label, family). '
  'Quarantined and redirected rows are history and deliberately excluded: an '
  'erasure must not permanently prevent re-minting, and a merged provisional '
  'must not be revived. Any upsert must repeat this predicate exactly.';

-- ---------------------------------------------------------------------------
-- 2. The merge carries both records, or refuses.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.transfer_suppression_on_redirect()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  standing integer;
  attributable integer;
begin
  if new.redirect_concept_id is null
     or new.redirect_concept_id is not distinct from old.redirect_concept_id then
    return new;
  end if;

  -- **What the overlay reads: may this be reviewed again.** Unchanged from
  -- `0229`.
  insert into semantic_private.user_term_suppressions
    (user_id, concept_id, provisional_entity_id, user_facing_predicate,
     active, source_review_item_id, source_review_epoch)
  select s.user_id, new.redirect_concept_id, null, s.user_facing_predicate,
         true, s.source_review_item_id, s.source_review_epoch
    from semantic_private.user_term_suppressions s
   where s.provisional_entity_id = new.id
     and s.active
  on conflict do nothing;

  -- **And what `list_assertions` reads: may this be shown as a claim.** The
  -- provisional strike could not write this one, having no concept to name.
  -- The redirect is where the concept first exists.
  select count(*) into standing
    from semantic_private.user_term_suppressions s
   where s.provisional_entity_id = new.id and s.active;

  if standing = 0 then
    return new;
  end if;

  select count(*) into attributable
    from semantic_private.user_term_suppressions s
    join semantic_private.review_events e
      on e.review_item_id = s.source_review_item_id
     and e.user_id = s.user_id
     and e.action = 'strike_off'
   where s.provisional_entity_id = new.id and s.active;

  -- Refusing costs a merge; accepting either way costs somebody's answer. A
  -- suppression that cannot name the strike behind it is not one to invent a
  -- Memories record for, and it is not one to drop either.
  if attributable < standing then
    raise exception
      'redirect would lose a strike: % of % standing suppressions on provisional % name no strike event',
      standing - attributable, standing, new.id;
  end if;

  insert into semantic_private.user_suppressions
    (user_id, concept_id, predicate_key, surface, active,
     source_feedback_event_id)
  select distinct on (s.user_id, s.user_facing_predicate)
         s.user_id, new.redirect_concept_id, s.user_facing_predicate,
         'memories', true, e.id
    from semantic_private.user_term_suppressions s
    join semantic_private.review_events e
      on e.review_item_id = s.source_review_item_id
     and e.user_id = s.user_id
     and e.action = 'strike_off'
   where s.provisional_entity_id = new.id
     and s.active
   order by s.user_id, s.user_facing_predicate, e.created_at desc
  on conflict do nothing;

  return new;
end;
$$;

-- The trigger itself is unchanged; `0229` created it and the body is replaced
-- in place.

-- ---------------------------------------------------------------------------
-- 3. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  n     integer;
  stray text;
begin
  select count(*) into n
    from pg_indexes
   where schemaname = 'semantic_private'
     and indexname = 'provisional_entities_live_identity_idx';
  if n <> 1 then
    raise exception '0233: the live-identity index did not take';
  end if;

  -- Stated over the suppressions that exist, so an empty database answers it
  -- and production answers it. A provisional suppression that names no strike
  -- is what the trigger now refuses to merge; if one already existed the
  -- refusal would arrive at somebody's merge instead of here.
  select count(*) into n
    from semantic_private.user_term_suppressions s
   where s.provisional_entity_id is not null
     and s.active
     and not exists (
       select 1 from semantic_private.review_events e
        where e.review_item_id = s.source_review_item_id
          and e.user_id = s.user_id
          and e.action = 'strike_off');
  if n > 0 then
    raise exception
      '0233: % active provisional suppressions already name no strike event', n;
  end if;

  -- `user_suppressions.predicate_key` carries a foreign key to
  -- `ontology.relation_types` and `user_term_suppressions.user_facing_predicate`
  -- does not. The trigger now crosses that seam, so the vocabularies have to
  -- agree or a merge raises on the foreign key rather than on the rule.
  select string_agg(distinct s.user_facing_predicate, ', ') into stray
    from semantic_private.user_term_suppressions s
   where not exists (select 1 from ontology.relation_types rt
                      where rt.predicate_key = s.user_facing_predicate);
  if stray is not null then
    raise exception
      '0233: suppression predicates absent from ontology.relation_types: %', stray;
  end if;
end;
$$;
