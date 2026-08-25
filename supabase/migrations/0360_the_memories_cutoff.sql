-- 0360 — the Memories cutoff: per user, per topical hub, versioned, v0 open.
--
-- **The owner's design, 2026-08-25.** Scoring now produces a long inferred
-- tail (0359); what reaches the Memories page for keep/strike is decided by
-- a cutoff — per (user, topical hub), because David's music-dominated terms
-- should stay a majority without flooding the page, and every user's
-- Memories should show a range of topics. Below the cutoff a term exists,
-- is scored, and is not drawn; that is the design.
--
-- **The cutoff is a display decision and a versioned release, never a
-- mutable knob.** Releases follow `calibration_parameters`' shape (0257);
-- per-user rows follow `feature_flag_overrides`' (0048). Exactly one
-- release is active, enforced by a partial unique index rather than by
-- convention. `machine_state`, the revision machinery and every append-only
-- table are untouched.
--
-- **v0 is seeded active with a cutoff of zero everywhere** — the owner's
-- bootstrap: David is shown everything, strikes against his own concept,
-- and the first per-hub cutoffs are fitted from that n=1 data (0361 holds
-- the dry-run reports).
--
-- **An exposure names the selection rule that let the row be shown.**
-- `assertion_exposures` gains `cutoff_release`, stamped server-side by
-- `record_assertion_exposure` — feedback gathered under two cutoffs would
-- otherwise be unattributable, the same failure 0257/0292 avoided by
-- versioning parameters and prices. Historical rows stay null: the
-- pre-cutoff era, honestly.
--
-- `api.list_assertions` is **fully redefined** — one migration owning the
-- whole body again instead of a third `pg_get_functiondef` patch. The body
-- below is the deployed text (0197 + 0277's published-version fallback,
-- carried verbatim) plus exactly two additions, each marked `-- 0360:`.

begin;

-- ---------------------------------------------------------------------
-- 1. Storage
-- ---------------------------------------------------------------------
create table semantic_private.memories_cutoff_releases (
  release_version text primary key,
  status text not null default 'draft'
    check (status in ('draft', 'active', 'retired')),
  default_cutoff numeric not null default 0
    check (default_cutoff between 0 and 1),
  notes text,
  created_at timestamptz not null default now()
);

-- The rule as an index: at most one active release, structurally.
create unique index memories_cutoff_one_active
  on semantic_private.memories_cutoff_releases ((true))
  where status = 'active';

create table semantic_private.memories_cutoff_values (
  id uuid primary key default gen_random_uuid(),
  release_version text not null
    references semantic_private.memories_cutoff_releases (release_version)
    on delete cascade,
  hub_key text not null check (length(btrim(hub_key)) > 0),
  -- Null means "the hub's default for every user"; a row with a user id is
  -- that person's own bar, which n=1 fitting is allowed to set without
  -- touching anybody else.
  user_id uuid,
  cutoff numeric not null check (cutoff between 0 and 1),
  unique (release_version, hub_key, user_id)
);

comment on table semantic_private.memories_cutoff_releases is
  'Versioned Memories display cutoffs (owner''s design 2026-08-25): what '
  'surfacing score a term needs, per user per topical hub, to be drawn for '
  'keep/strike. A display decision only — machine_state and the revision '
  'machinery are untouched. Exactly one active release, by partial unique '
  'index. v0 = zero everywhere (the bootstrap: show everything, fit from '
  'strikes).';

-- ---------------------------------------------------------------------
-- 2. The hub bucket: nearest hub:* ancestor, at a stated version.
--    concept_block''s 13 block keys are not hub keys, so the cutoff has
--    its own climb — same shape, hub tier only.
-- ---------------------------------------------------------------------
create or replace function semantic_private.concept_hub(
  target_concept_id uuid, target_version_id uuid
) returns text
language sql
stable
set search_path to ''
as $$
  with recursive climb as (
    select e.object_concept_id as concept_id, 1 as depth
      from ontology.concept_edges e
     where e.ontology_version_id = target_version_id
       and e.subject_concept_id = target_concept_id
       and e.predicate_key = 'broader'
       and e.status = 'active'
    union all
    select e.object_concept_id, climb.depth + 1
      from climb
      join ontology.concept_edges e
        on e.ontology_version_id = target_version_id
       and e.subject_concept_id = climb.concept_id
       and e.predicate_key = 'broader'
       and e.status = 'active'
     where climb.depth < 8
  )
  select c.concept_key
    from climb
    join ontology.concepts c on c.id = climb.concept_id
   where c.concept_key like 'hub:%'
   order by climb.depth
   limit 1
$$;

-- ---------------------------------------------------------------------
-- 3. The resolver: user's own bar, else the hub's, else the release's.
--    `stable`, never `immutable` — an immutable guard may be folded at
--    plan time, which is the assert_surface_allowed lesson.
-- ---------------------------------------------------------------------
create or replace function semantic_private.active_cutoff_release()
returns text
language sql
stable
set search_path to ''
as $$
  select release_version from semantic_private.memories_cutoff_releases
   where status = 'active'
$$;

create or replace function semantic_private.active_memories_cutoff(
  p_user uuid, p_hub text
) returns numeric
language sql
stable
set search_path to ''
as $$
  select coalesce(
    (select v.cutoff from semantic_private.memories_cutoff_values v
      join semantic_private.memories_cutoff_releases r
        on r.release_version = v.release_version and r.status = 'active'
     where v.hub_key = p_hub and v.user_id = p_user),
    (select v.cutoff from semantic_private.memories_cutoff_values v
      join semantic_private.memories_cutoff_releases r
        on r.release_version = v.release_version and r.status = 'active'
     where v.hub_key = p_hub and v.user_id is null),
    (select r.default_cutoff from semantic_private.memories_cutoff_releases r
      where r.status = 'active'),
    0)
$$;

-- ---------------------------------------------------------------------
-- 4. The exposure names the selection rule.
-- ---------------------------------------------------------------------
alter table semantic_private.assertion_exposures
  add column if not exists cutoff_release text;

comment on column semantic_private.assertion_exposures.cutoff_release is
  'The Memories cutoff release in force when this row was shown, stamped '
  'server-side. Null is the pre-cutoff era. Without it, feedback gathered '
  'under two different cutoffs is unattributable.';

-- ---------------------------------------------------------------------
-- 5. list_assertions, whole again. Deployed text plus two marked changes.
-- ---------------------------------------------------------------------
create or replace function api.list_assertions()
returns table(
  assertion_id uuid, predicate_key text, label text, origin text,
  display_state text, strength double precision, confidence double precision,
  breadth integer, stability double precision,
  surfacing_score double precision, display_payload jsonb,
  assertion_score_version_id uuid, ontology_version_id uuid,
  block_key text, block_label text
)
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select
    assertion.id,
    assertion.predicate_key,
    coalesce(revision.preferred_label, user_term.label),
    assertion.assertion_origin,
    coalesce(preference.display_state, 'default'),
    score.strength,
    score.confidence,
    score.breadth,
    score.stability,
    score.surfacing_score,
    score.display_payload,
    score.id,
    coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'), assertion.created_ontology_version_id),
    block.concept_key,
    block_revision.preferred_label
  from semantic_private.user_assertions as assertion
  left join semantic_private.assertion_preferences as preference
    on preference.assertion_id = assertion.id
   and preference.user_id = assertion.user_id
  left join semantic_private.user_terms as user_term
    on user_term.id = assertion.user_term_id
   and user_term.user_id = assertion.user_id
  left join semantic_private.assertion_current_scores as current_score
    on current_score.assertion_id = assertion.id
   and current_score.user_id = assertion.user_id
  left join semantic_private.user_state_versions as user_state
    on user_state.user_id = assertion.user_id
  left join semantic_private.semantic_runs as score_run
    on score_run.id = current_score.semantic_run_id
   and score_run.user_id = assertion.user_id
   and score_run.status = 'succeeded'
   and score_run.input_revision = coalesce(user_state.revision, 0)
  left join semantic_private.assertion_score_versions as score
    on score.id = current_score.assertion_score_version_id
   and score.user_id = current_score.user_id
   and score.assertion_id = current_score.assertion_id
   and score.semantic_run_id = score_run.id
  left join ontology.concept_revisions as revision
    on revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
   and revision.concept_id = assertion.concept_id
  -- **The concept's own key, which the filter below needs and nothing here had.**
  -- A primary-key lookup, and `left` rather than `inner` because a user's own
  -- term has no concept at all and an inner join would delete every one of them.
  left join ontology.concepts as concept
    on concept.id = assertion.concept_id
  -- The block, and its label at the same version the term is read at, so a
  -- heading can never come from a different ontology than the row under it.
  left join lateral (
    select c.id, c.concept_key
      from ontology.concepts c
     where c.concept_key = semantic_private.concept_block(
             assertion.concept_id,
             coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'),
                      assertion.created_ontology_version_id))
  ) as block on true
  left join ontology.concept_revisions as block_revision
    on block_revision.concept_id = block.id
   and block_revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
  -- 0360: the topical hub this row buckets under, for the cutoff. Null for
  -- a user's own term (no concept) and for a concept outside every hub.
  left join lateral (
    select semantic_private.concept_hub(
             assertion.concept_id,
             coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'),
                      assertion.created_ontology_version_id)) as hub_key
  ) as hub on true
  where assertion.user_id = auth.uid()
    and assertion.machine_state in ('candidate', 'eligible')
    and coalesce(preference.display_state, 'default') <> 'suppressed'
    -- Nameable things only. A term the person typed has no concept and no kind,
    -- and is always theirs to see.
    --
    -- `topic` joins the allowlist, less the three axis families: an axis is
    -- something the scorer reasons with, not a claim anybody would make about
    -- themselves, and striking one off would silently reweigh everything else.
    --
    -- 0360: `genre` and `culture` join it, and that is the owner deciding
    -- they belong (2026-08-25) — the propagated tail's whole point is that
    -- genre:pop and culture:taiwan are terms a person keeps or strikes, and
    -- an allowlist that withheld them would hide exactly what the bootstrap
    -- exists to price. The axis exclusions stand; `medium` and `hub` stay
    -- out, being structure rather than taste.
    and (
      assertion.user_term_id is not null
      or (
        revision.concept_kind in ('creator', 'work', 'activity', 'topic',
                                  'genre', 'culture')
        and concept.concept_key not like 'era:%'
        and concept.concept_key not like 'sphere:%'
        and concept.concept_key not like 'scene:%'
      )
    )
    and (
      assertion.assertion_origin <> 'inferred' or
      (
        score.id is not null
        and score_run.status = 'succeeded'
        and score_run.input_revision = coalesce(user_state.revision, 0)
      )
    )
    and not exists (
      select 1
      from semantic_private.user_suppressions as suppression
      where suppression.user_id = assertion.user_id
        and suppression.predicate_key = assertion.predicate_key
        and suppression.surface = 'memories'
        and suppression.active
        and (
          (assertion.concept_id is not null and suppression.concept_id = assertion.concept_id) or
          (assertion.user_term_id is not null and suppression.user_term_id = assertion.user_term_id)
        )
    )
    -- 0360: the cutoff. A display decision, per (user, hub), from the one
    -- active release. `coalesce(..., 1.0)` is deliberate twice over: a
    -- declared term has no score row and passes any cutoff at the top score
    -- (the same fallback the order by already uses), and a concept outside
    -- every hub resolves through the release default.
    and coalesce(score.surfacing_score, 1.0)
        >= semantic_private.active_memories_cutoff(assertion.user_id, hub.hub_key)
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$function$;

-- The order-by must survive every future edit (0106's lesson, restated).
do $$
begin
  if position('order by coalesce(score.surfacing_score, 1.0) desc' in
       pg_get_functiondef('api.list_assertions()'::regprocedure)) = 0 then
    raise exception '0360: list_assertions lost its ordering';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. The exposure writer stamps the release. Deployed text plus one
--    marked change; same signature, so no overload can appear.
-- ---------------------------------------------------------------------
create or replace function api.record_assertion_exposure(
  p_target_assertion_id uuid, p_assertion_score_version_id uuid,
  p_presentation_version text, p_displayed_label text,
  p_rank integer default null::integer,
  p_surface_name text default 'memories'::text
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  actor_id uuid := auth.uid();
  assertion_row semantic_private.user_assertions%rowtype;
  exposure_id uuid;
  version_id uuid;
begin
  if actor_id is null then
    raise exception 'authentication required';
  end if;
  perform semantic_private.assert_surface_allowed(p_surface_name);
  if p_presentation_version is null
     or char_length(btrim(p_presentation_version)) not between 1 and 80 then
    raise exception 'invalid presentation version';
  end if;
  if p_displayed_label is null
     or char_length(btrim(p_displayed_label)) not between 1 and 240 then
    raise exception 'invalid displayed label';
  end if;
  if p_rank is not null and p_rank < 0 then
    raise exception 'rank must be nonnegative';
  end if;

  select * into assertion_row
  from semantic_private.user_assertions
  where id = p_target_assertion_id
    and user_id = actor_id
    and machine_state in ('candidate', 'eligible')
  for share;
  if not found then
    raise exception 'assertion not found or unavailable';
  end if;

  if p_assertion_score_version_id is not null then
    select score.ontology_version_id into version_id
    from semantic_private.assertion_current_scores as current_score
    join semantic_private.assertion_score_versions as score
      on score.id = current_score.assertion_score_version_id
     and score.user_id = current_score.user_id
     and score.assertion_id = current_score.assertion_id
    join semantic_private.semantic_runs as run
      on run.id = current_score.semantic_run_id
     and run.user_id = current_score.user_id
    left join semantic_private.user_state_versions as user_state
      on user_state.user_id = current_score.user_id
    where current_score.assertion_id = assertion_row.id
      and current_score.user_id = actor_id
      and current_score.assertion_score_version_id = p_assertion_score_version_id
      and run.status = 'succeeded'
      and run.input_revision = coalesce(user_state.revision, 0);
    if not found then
      raise exception 'score is not the finalized current score for assertion';
    end if;
  elsif assertion_row.assertion_origin = 'inferred' then
    raise exception 'inferred assertion exposure requires its current score';
  else
    version_id := assertion_row.created_ontology_version_id;
  end if;

  if exists (
    select 1
    from semantic_private.assertion_preferences as preference
    where preference.assertion_id = assertion_row.id
      and preference.user_id = actor_id
      and preference.display_state = 'suppressed'
  ) or exists (
    select 1
    from semantic_private.user_suppressions as suppression
    where suppression.user_id = actor_id
      and suppression.predicate_key = assertion_row.predicate_key
      and suppression.surface = p_surface_name
      and suppression.active
      and (
        (assertion_row.concept_id is not null and suppression.concept_id = assertion_row.concept_id) or
        (assertion_row.user_term_id is not null and suppression.user_term_id = assertion_row.user_term_id)
      )
  ) then
    raise exception 'suppressed assertion cannot be recorded as exposed';
  end if;

  insert into semantic_private.assertion_exposures (
    assertion_id, user_id, assertion_score_version_id,
    ontology_version_id, surface, presentation_version, displayed_label, rank,
    -- 0360: the selection rule in force, stamped by the server so no client
    -- can misreport which cutoff let this row be seen.
    cutoff_release
  ) values (
    assertion_row.id, actor_id, p_assertion_score_version_id,
    version_id, p_surface_name, btrim(p_presentation_version),
    btrim(p_displayed_label), p_rank,
    semantic_private.active_cutoff_release()
  ) returning id into exposure_id;
  return exposure_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- 7. v0: everything shows. The bootstrap is a release like any other.
-- ---------------------------------------------------------------------
insert into semantic_private.memories_cutoff_releases
  (release_version, status, default_cutoff, notes)
values
  ('cutoff-v0', 'active', 0,
   'The bootstrap release: no term is withheld. David reviews the full '
   'set; the first fitted per-hub cutoffs ship as cutoff-v1.')
on conflict (release_version) do nothing;

-- ---------------------------------------------------------------------
-- 8. Proven both ways, rolled back by raising.
-- ---------------------------------------------------------------------
do $$
declare
  probe_user uuid := '00000000-0000-0000-0000-00000000c0f1';
  other_user uuid := '00000000-0000-0000-0000-00000000c0f2';
  refused boolean := false;
  answer numeric;
begin
  -- v0 answers zero for anybody, any hub.
  answer := semantic_private.active_memories_cutoff(probe_user, 'hub:music');
  if answer is distinct from 0 then
    raise exception '0360: v0 answers % for hub:music, expected 0', answer;
  end if;

  -- A second active release is refused by the index, not by convention.
  begin
    insert into semantic_private.memories_cutoff_releases
      (release_version, status) values ('0360-probe-second-active', 'active');
  exception when unique_violation then
    refused := true;
  end;
  if not refused then
    raise exception '0360: a second active release was accepted';
  end if;

  -- Precedence, answered all three ways over a probe release, rolled back.
  begin
    update semantic_private.memories_cutoff_releases
       set status = 'retired' where release_version = 'cutoff-v0';
    insert into semantic_private.memories_cutoff_releases
      (release_version, status, default_cutoff)
    values ('0360-probe', 'active', 0.3);
    insert into semantic_private.memories_cutoff_values
      (release_version, hub_key, user_id, cutoff)
    values ('0360-probe', 'hub:music', null, 0.5),
           ('0360-probe', 'hub:music', probe_user, 0.7);

    if semantic_private.active_memories_cutoff(probe_user, 'hub:music')
         is distinct from 0.7 then
      raise exception '0360: the user''s own bar did not win';
    end if;
    if semantic_private.active_memories_cutoff(other_user, 'hub:music')
         is distinct from 0.5 then
      raise exception '0360: the hub default did not answer for another user';
    end if;
    if semantic_private.active_memories_cutoff(probe_user, 'hub:film_video')
         is distinct from 0.3 then
      raise exception '0360: the release default did not answer for a bare hub';
    end if;
    -- And the null hub (a user''s own term, a concept outside every hub)
    -- resolves through the release default rather than erroring.
    if semantic_private.active_memories_cutoff(probe_user, null)
         is distinct from 0.3 then
      raise exception '0360: a null hub did not fall through to the default';
    end if;

    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then
      raise notice '0360: precedence holds — user > hub > release, null hub falls through';
  end;

  if exists (select 1 from semantic_private.memories_cutoff_releases
              where release_version like '0360-probe%') then
    raise exception '0360: probe releases survived their rollback';
  end if;
  if not exists (select 1 from semantic_private.memories_cutoff_releases
                  where release_version = 'cutoff-v0' and status = 'active') then
    raise exception '0360: cutoff-v0 is not the active release';
  end if;
end;
$$;

commit;
