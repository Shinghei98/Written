-- 0234 — an exact miss gets somewhere to go.
--
-- Stage 1A of the finalized sequence. `0233` gave a provisional an identity and
-- made a strike survive becoming a concept; this is the route that mints one.
--
-- ## What it is not
--
-- **This is not a claim that exact matching discovers enough vocabulary.** It
-- does not: 1 of 882 distinct labels on active observations matches any of the
-- 8,115 concept labels, and that is the measurement that put the sink before the
-- model rather than after it. Exact matching is the known-term fast path. The
-- sink is what stops an unknown term from disappearing, whichever producer found
-- it — and the producer that matters later is Qwen.
--
-- ## The exact verdict is preserved, not replaced
--
-- `0212` keys a verdict on `(mention_id, route_id, resolver_version,
-- evaluated_ontology_version_id)` and `current_mention_resolutions` is `distinct
-- on (mention_id, route_id)`, so a second route stands beside the first rather
-- than over it. The exact lane keeps saying `unresolved` — which is true, and is
-- the record that lets a later ontology rescue the term — while
-- `projection_personal_v1` says `personal_provisional` about the same mention.
--
-- One exact match still resolves canonically and several still leave it
-- `ambiguous`; neither mints anything. A provisional is only for the case where
-- the vocabulary genuinely has nothing to say.
--
-- ## The allowlist is a table, and it is short on purpose
--
-- `semantic_private.provisional_projection_families` maps a projection's own
-- `mention_role` onto the family a provisional may truthfully claim. It is a
-- table for the reason `sources.engagement_modes` is a column and not a list in
-- `score.py`: the next person to ask "which projections may mint?" should find
-- the answer beside the data rather than inside a query.
--
-- **Three roles are admitted and three are deliberately refused.**
--
-- `album` and `work` and `source_work` map to families that say no more than the
-- projection knows. `creator`, `composer` and `genre` do not, and the reason is
-- worth writing down because it looks like an omission:
--
-- - `provisional_entities.family` has no `creator` or identity kind at all. The
--   two candidates, `person` and `group`, both compile to
--   `concept_kind = creator` but carry `metadata.entity_form`, so choosing
--   either asserts a *form* a performer credit does not state. A string in the
--   `primary_performer` field may be a person, a duo, an orchestra or a label.
-- - `genre` has no family either; `game_category` is genre-in-games and nothing
--   else.
--
-- Adding a truthful `creator_identity` means the authoring workbook, a sixth
-- entry in `MODEL_FORBIDDEN_FAMILIES` — the model emits `person` or `group` and
-- must never emit the uncommitted kind — and a recompiled contract, because
-- `--check-database` reads this constraint back and refuses to agree that the
-- contract compiles if the two have drifted. That is an authoring decision, not
-- a consequence of this migration, and coercing to `person` while it is pending
-- would put a claim in the database that nothing later could tell from a real
-- one.
--
-- **So the first route mints for 5,665 of 6,372 mentions and refuses 655**, and
-- the refusal is legible rather than silent.
--
-- ## What the armer had to learn
--
-- Two stages gained work they could not see. `resolve_mention` now also has
-- something to do when an eligible exact miss has no provisional verdict at the
-- published version, and `build_candidate_overlay` when a provisional-backed
-- candidate is missing its evidence. `0232` is three days old and its lesson
-- applies here: a work test that does not match what the statement writes is a
-- stage that either never runs or never stops.

-- ---------------------------------------------------------------------------
-- 1. Which projections may mint, and what they may claim.
-- ---------------------------------------------------------------------------

create table if not exists semantic_private.provisional_projection_families (
  mention_role text primary key,
  family text not null,
  notes text not null,
  created_at timestamptz not null default now()
);

comment on table semantic_private.provisional_projection_families is
  'Which legacy projection roles may mint a personal provisional, and the family '
  'each may truthfully claim. A role absent from this table mints nothing. '
  'Widening it is an authoring decision: the family must say no more than the '
  'projection knows.';

insert into semantic_private.provisional_projection_families
  (mention_role, family, notes)
values
  ('album', 'album',
   'An album title names an album. The family says exactly what the field does.'),
  ('work', 'work',
   'A track or work title names a creative work. `work` compiles to '
   'concept_kind=work with work_type=creative_work, which is the least committed '
   'truthful reading — it does not decide between a song, a composition or a '
   'recording, and 0221 is why that restraint matters.'),
  ('source_work', 'work',
   'The originating work of a soundtrack credit. Same family, same reasoning.')
on conflict (mention_role) do nothing;

-- ---------------------------------------------------------------------------
-- 2. The armer sees both stages' new work.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.arm_candidate_overlay(
  target_user uuid default null,
  resolver_version text default 'exact-0.1.0'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  armed integer := 0;
  published uuid;
  candidate record;
  plan record;
  next_count bigint;
begin
  select id into published from ontology.versions where status = 'published';
  if published is null then
    raise notice 'arm_candidate_overlay: no published ontology; nothing can resolve';
    return 0;
  end if;

  for plan in
    select * from (values
      ('resolve_mention', jsonb_build_object('resolver_version', resolver_version), 0),
      ('build_candidate_overlay', '{}'::jsonb, 90),
      ('aggregate_term_candidates', '{}'::jsonb, 180),
      ('build_review_items', jsonb_build_object('review_epoch', 0), 270)
    ) as s(job_type, extra, delay_seconds)
  loop
    for candidate in
      select u.id as user_id
        from auth.users u
       where (target_user is null or u.id = target_user)
         -- Nothing of this stage already in flight for this account.
         and not exists (
           select 1 from semantic_private.worker_jobs j
            where j.user_id = u.id and j.job_type = plan.job_type
              and j.status in ('queued', 'running'))
         -- **And there is work.** One condition per stage, each asking of the
         -- data rather than of a counter.
         and case plan.job_type
           -- A mention nothing has judged at the published vocabulary, or an
           -- eligible exact miss the provisional route has not yet answered.
           -- The second half is `0234`: the job does both and a work test that
           -- named only the first would stop arming with the sink still empty.
           when 'resolve_mention' then exists (
             select 1
               from semantic_private.observation_mentions m
               join semantic_private.observations o
                 on o.id = m.observation_id and o.user_id = m.user_id
              where m.user_id = u.id
                and o.lifecycle_state = 'active'
                and o.action_weight > 0
                and not exists (
                  select 1 from semantic_private.mention_resolutions r
                   where r.mention_id = m.id
                     and r.evaluated_ontology_version_id = published))
             or exists (
             select 1
               from semantic_private.current_mention_resolutions r
               join semantic_private.observation_mentions m
                 on m.id = r.mention_id and m.user_id = r.user_id
               join semantic_private.observations o
                 on o.id = m.observation_id and o.user_id = m.user_id
               join semantic_private.provisional_projection_families f
                 on f.mention_role = m.mention_role
              where r.user_id = u.id
                and r.route_id = 'exact_label'
                and r.resolution = 'unresolved'
                and r.evaluated_ontology_version_id = published
                and o.lifecycle_state = 'active'
                and o.action_weight > 0
                and m.extraction_method = 'projection_field'
                and length(btrim(m.normalized_text)) > 0
                and not exists (
                  select 1 from semantic_private.mention_resolutions p
                   where p.mention_id = m.id
                     and p.route_id = 'projection_personal_v1'
                     and p.evaluated_ontology_version_id = published))
           -- **The same question the job's own anti-join asks**, now for both
           -- shapes of candidate. `0232` keyed this on concept, observation and
           -- route after it had been keyed on a resolution row id that every
           -- ontology publish replaced.
           when 'build_candidate_overlay' then exists (
             select 1
               from semantic_private.current_mention_resolutions r
               join semantic_private.observation_mentions m
                 on m.id = r.mention_id and m.user_id = r.user_id
              where r.user_id = u.id
                and r.resolution = 'resolved_existing'
                and r.concept_id is not null
                and (
                  not exists (
                    select 1 from semantic_private.user_term_candidates c
                     where c.user_id = r.user_id
                       and c.concept_id = r.concept_id
                       and c.lifecycle_state = 'active')
                  or exists (
                    select 1 from semantic_private.user_term_candidates c
                     where c.user_id = r.user_id
                       and c.concept_id = r.concept_id
                       and c.lifecycle_state = 'active'
                       and not exists (
                         select 1 from semantic_private.candidate_support_links l
                          where l.candidate_id = c.id
                            and l.observation_id = m.observation_id
                            and l.route_id = r.route_id))))
             or exists (
             select 1
               from semantic_private.current_mention_resolutions r
               join semantic_private.observation_mentions m
                 on m.id = r.mention_id and m.user_id = r.user_id
              where r.user_id = u.id
                and r.resolution = 'personal_provisional'
                and r.provisional_entity_id is not null
                and (
                  not exists (
                    select 1 from semantic_private.user_term_candidates c
                     where c.user_id = r.user_id
                       and c.provisional_entity_id = r.provisional_entity_id
                       and c.lifecycle_state = 'active')
                  or exists (
                    select 1 from semantic_private.user_term_candidates c
                     where c.user_id = r.user_id
                       and c.provisional_entity_id = r.provisional_entity_id
                       and c.lifecycle_state = 'active'
                       and not exists (
                         select 1 from semantic_private.candidate_support_links l
                          where l.candidate_id = c.id
                            and l.observation_id = m.observation_id
                            and l.route_id = r.route_id))))
           when 'aggregate_term_candidates' then exists (
             select 1
               from semantic_private.user_term_candidates c
               join semantic_private.candidate_support_links l
                 on l.candidate_id = c.id
              where c.user_id = u.id and c.lifecycle_state = 'active'
              group by c.id, c.updated_at
             having max(l.created_at) > c.updated_at)
           when 'build_review_items' then exists (
             select 1 from semantic_private.user_term_candidates c
              where c.user_id = u.id and c.lifecycle_state = 'active'
                and not exists (
                  select 1 from semantic_private.review_items i
                   where i.candidate_id = c.id and i.review_epoch = 0))
           else false
         end
    loop
      insert into semantic_private.overlay_stage_cursors (user_id, stage, armed_count, last_armed_at)
      values (candidate.user_id, plan.job_type, 1, now())
      on conflict (user_id, stage) do update
        set armed_count = semantic_private.overlay_stage_cursors.armed_count + 1,
            last_armed_at = now()
      returning armed_count into next_count;

      insert into semantic_private.worker_jobs
        (job_type, user_id, payload, idempotency_key, available_at)
      values (plan.job_type, candidate.user_id,
              plan.extra || jsonb_build_object('user_id', candidate.user_id::text),
              'overlay:v2:' || plan.job_type || ':' || candidate.user_id::text
                || ':' || next_count::text,
              now() + make_interval(secs => plan.delay_seconds));
      armed := armed + 1;
    end loop;
  end loop;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_candidate_overlay(uuid, text)
  from public, anon, authenticated, semantic_ingestor, semantic_worker;

-- ---------------------------------------------------------------------------
-- 3. The worker may read the allowlist and nothing may write it.
-- ---------------------------------------------------------------------------

grant select on semantic_private.provisional_projection_families to semantic_worker;

-- ---------------------------------------------------------------------------
-- 3b. The lane itself, in SQL so that a contract file can run it.
-- ---------------------------------------------------------------------------
--
-- **These are functions rather than statements in the worker because of what a
-- proof needs.** The overlay's other statements live as Python string constants
-- and `apply_feedback` is the standing consequence: two of its statements were
-- wrong for months and no test could reach them. A contract file can seed rows,
-- call a function and read the result back; it cannot reach a string in a
-- Lambda bundle.
--
-- The route literal lives here and only here for the same reason `0232` exists.

create or replace function semantic_private.provision_exact_misses(
  p_user_id uuid,
  p_version uuid
)
returns table (minted integer, provisioned integer)
language plpgsql
set search_path = ''
as $$
declare
  exact_route  constant text := 'exact_label';
  fallback     constant text := 'projection_personal_v1';
  minted_rows  integer := 0;
  written_rows integer := 0;
begin
  -- **Identities first, verdicts second, because the conflict target is the
  -- point.** `on conflict do nothing` returns nothing for rows that already
  -- existed, so the ids are resolved by lookup below rather than from
  -- `returning` — the same reason `append_source_records` cannot trust a head
  -- that missed a seen item.
  --
  -- The `on conflict` predicate repeats `provisional_entities_live_identity_idx`
  -- exactly. A partial index whose predicate the writer restates loosely is an
  -- index the writer does not actually use.
  --
  -- `distinct on` picks one canonical label per identity: several mentions can
  -- normalize to one string, and the surface that gets stored should be stable
  -- rather than whichever row the planner reached first.
  insert into semantic_private.provisional_entities
    (scope, user_id, canonical_label, normalized_label, family)
  select distinct on (m.user_id, m.normalized_text, f.family)
         'user', m.user_id, m.mention_text, m.normalized_text, f.family
    from semantic_private.current_mention_resolutions r
    join semantic_private.observation_mentions m
      on m.id = r.mention_id and m.user_id = r.user_id
    join semantic_private.observations o
      on o.id = m.observation_id and o.user_id = m.user_id
    join semantic_private.provisional_projection_families f
      on f.mention_role = m.mention_role
   where r.user_id = p_user_id
     and r.route_id = exact_route
     and r.resolution = 'unresolved'
     and r.evaluated_ontology_version_id = p_version
     and o.lifecycle_state = 'active'
     and o.action_weight > 0
     and m.extraction_method = 'projection_field'
     and length(btrim(m.normalized_text)) > 0
   order by m.user_id, m.normalized_text, f.family, m.mention_text
  on conflict (user_id, normalized_label, family)
    where scope = 'user'
      and identity_state <> 'quarantined'
      and redirect_concept_id is null
  do nothing;
  get diagnostics minted_rows = row_count;

  -- The verdict, under its own route, joined to whichever identity now stands
  -- for that label. **The exact row is untouched.**
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
    join semantic_private.provisional_projection_families f
      on f.mention_role = m.mention_role
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
     and m.extraction_method = 'projection_field'
     and length(btrim(m.normalized_text)) > 0
  on conflict do nothing;
  get diagnostics written_rows = row_count;

  minted := minted_rows;
  provisioned := written_rows;
  return next;
end;
$$;

create or replace function semantic_private.build_provisional_candidates(
  p_user_id uuid,
  p_predicate text,
  p_batch integer
)
returns table (candidates integer, links integer)
language plpgsql
set search_path = ''
as $$
declare
  fallback   constant text := 'projection_personal_v1';
  cand_rows  integer := 0;
  link_rows  integer := 0;
begin
  -- **Separate from the concept branch rather than generalised**, because each
  -- `on conflict` names one partial index and Postgres infers one arbiter at a
  -- time. `user_term_candidates_single_term_check` is what makes "exactly one
  -- of them" a fact rather than a convention, so neither statement can produce
  -- the other's row.
  insert into semantic_private.user_term_candidates
    (user_id, provisional_entity_id, user_facing_predicate, confidence_tier,
     primary_route_id)
  select distinct r.user_id, r.provisional_entity_id, p_predicate, 'secondary',
         fallback
    from semantic_private.current_mention_resolutions r
   where r.user_id = p_user_id
     and r.route_id = fallback
     and r.resolution = 'personal_provisional'
     and r.provisional_entity_id is not null
  on conflict (user_id, provisional_entity_id, user_facing_predicate)
    where lifecycle_state = 'active' and provisional_entity_id is not null
  do nothing;
  get diagnostics cand_rows = row_count;

  insert into semantic_private.candidate_support_links
    (user_id, candidate_id, observation_id, mention_resolution_id, route_id,
     evidence_family_key, contribution)
  select c.user_id, c.id, m.observation_id, r.id, fallback,
         coalesce(m.type_hint, 'unspecified'),
         least(greatest(m.evidence_weight * m.recency_weight, 0.0), 1.0)
    from semantic_private.current_mention_resolutions r
    join semantic_private.observation_mentions m
      on m.id = r.mention_id and m.user_id = r.user_id
    join semantic_private.user_term_candidates c
      on c.user_id = r.user_id
     and c.provisional_entity_id = r.provisional_entity_id
     and c.user_facing_predicate = p_predicate
     and c.lifecycle_state = 'active'
   where r.user_id = p_user_id
     and r.route_id = fallback
     and r.resolution = 'personal_provisional'
     and r.provisional_entity_id is not null
     and not exists (
       select 1 from semantic_private.candidate_support_links l
        where l.candidate_id = c.id
          and l.observation_id = m.observation_id
          and l.route_id = fallback)
   order by r.id
   limit p_batch
  on conflict (candidate_id, observation_id, route_id) do nothing;
  get diagnostics link_rows = row_count;

  candidates := cand_rows;
  links := link_rows;
  return next;
end;
$$;

revoke all on function semantic_private.provision_exact_misses(uuid, uuid)
  from public, anon, authenticated, semantic_ingestor;
revoke all on function semantic_private.build_provisional_candidates(uuid, text, integer)
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.provision_exact_misses(uuid, uuid)
  to semantic_worker;
grant execute on function semantic_private.build_provisional_candidates(uuid, text, integer)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- 4. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  stray text;
begin
  -- Every family this table names must be one the provisional table accepts, or
  -- the route mints nothing and says so only at the insert. Read back from the
  -- constraint rather than trusted to this file.
  select string_agg(distinct f.family, ', ') into stray
    from semantic_private.provisional_projection_families f
   where not exists (
     select 1
       from pg_constraint con
       join pg_class rel on rel.oid = con.conrelid
       join pg_namespace nsp on nsp.oid = rel.relnamespace
      where nsp.nspname = 'semantic_private'
        and rel.relname = 'provisional_entities'
        and con.contype = 'c'
        and pg_get_constraintdef(con.oid) like '%' || f.family || '%'
        and pg_get_constraintdef(con.oid) like '%family%');
  if stray is not null then
    raise exception
      '0234: provisional_projection_families names families provisional_entities refuses: %', stray;
  end if;

  -- The three refusals are the point of the table, so a later edit that quietly
  -- admits an identity role has to say so here first.
  if exists (select 1 from semantic_private.provisional_projection_families
              where mention_role in ('creator', 'composer', 'genre')) then
    raise exception
      '0234: creator, composer and genre have no truthful family yet; see the header';
  end if;
end;
$$;
