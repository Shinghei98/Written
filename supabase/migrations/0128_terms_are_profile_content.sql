-- 0128 — a person's terms become profile content, shown like a bio.
--
-- **`api.discover_profiles` has been returning no terms at all, for everybody.**
-- Every `assertion_surface_permissions` row for `matching`, `bio` and
-- `icebreaker` is `can_select = false` from `default_policy`; only `memories`,
-- the surface that shows you to yourself, is open. `0125`'s permission check
-- was therefore working and refusing everything.
--
-- **The product decision is that a derived term is profile content.** Explore
-- shows everyone who fits the viewer's dating preferences, a profile's contents
-- are simply shown, and the one lever a person has is Settings → dating
-- preferences. The v0.3.1 default treats a derived claim as needing its own
-- purpose grant; this app treats it as it treats a photograph.
--
-- **No consent screen, because what one would have bought already exists.**
-- Memories lists these same nameable terms, so nothing is hidden from the person
-- they are about; and suppressing one there already removes it from
-- `matching_terms`. Visibility and removal — the two things a primer would have
-- added — are the page. What was missing is only that the removal never said it
-- also hides the term from matches, which is a wording change and not a control.
--
-- Measured before deciding, on the owner's account: **38 nameable eligible
-- assertions, 32 would show**, 6 held back by the YouTube guard whatever anybody
-- decides, 0 by calendar or health.
--
-- **Two surfaces, because the schema separates two acts and the first draft of
-- this migration conflated them.** `assertion_surface_permissions_matching_shape_check`
-- reads
--
--     surface <> 'matching' or (not can_name and not can_explain)
--
-- so **the matching surface may *use* a term and may never *name* it**: it
-- decides who is shown to whom, invisibly. Naming somebody's term to another
-- person is the `bio` surface — `assert_surface_allowed` says as much, that "a
-- dynamic bio is a projection of one person shown to another, which is the same
-- exposure `matching` is", which is why the two share a flag.
--
-- So showing terms on a card needs `bio.can_name`, and this opens:
--
--     matching   can_select                 — may influence who you meet
--     bio        can_select, can_name       — may be shown to them
--     icebreaker unchanged, shut            — no consumer; a later phase
--
-- `can_explain` stays false everywhere. Explaining *why* two people matched is
-- a third act, `0125` does not read it, and the calendar guard refuses it
-- outright for calendar-derived facts.
--
-- The first draft set `can_name` on `matching` and every one of 178 rows was
-- refused by that check constraint. The count alone named nothing — all three
-- triggers it might have blamed early-return without their evidence type — so
-- the reason had to be carried out in the exception rather than left in a log.

begin;

-- ---------------------------------------------------------------------------
-- The hazard this migration is arranged around
-- ---------------------------------------------------------------------------
--
-- **Opening the permission at insert time would stop assertions being written.**
-- This trigger inserts the four rows as part of the `user_assertions` insert,
-- and three guards fire on that insert — `assertion_permissions_guard_youtube`,
-- `assertion_permissions_guard_calendar` and
-- `assertion_surface_permissions_guard_healthkit`. Each *raises* when
-- `can_select` is true without the matching approval, and a raise inside this
-- trigger aborts the assertion write itself. A YouTube-evidenced assertion would
-- simply stop existing, and the scorer would fail mid-run.
--
-- So the row is still born closed and opened immediately afterwards, inside a
-- block that tolerates a refusal. The guards keep their veto; what changes is
-- that a veto costs the *permission* rather than the assertion.
create or replace function semantic_private.initialize_assertion_surface_permissions()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  insert into semantic_private.assertion_surface_permissions (
    assertion_id, user_id, surface, can_select, can_name, can_explain,
    permission_source
  ) values
    (new.id, new.user_id, 'memories', true, true, true, 'default_policy'),
    (new.id, new.user_id, 'matching', false, false, false, 'default_policy'),
    (new.id, new.user_id, 'bio', false, false, false, 'default_policy'),
    (new.id, new.user_id, 'icebreaker', false, false, false, 'default_policy')
  on conflict (assertion_id, user_id, surface) do nothing;

  -- Opened separately, and failure here is an ordinary outcome rather than an
  -- error: a source-specific guard refusing is the guard doing its job.
  -- Each surface in its own block, so a refusal on one does not cost the other.
  begin
    update semantic_private.assertion_surface_permissions
       set can_select = true
     where assertion_id = new.id
       and user_id = new.user_id
       and surface = 'matching';
  exception when others then
    -- Deliberately swallowed and deliberately not logged. The refusal is a
    -- fact about another policy, it is recoverable by fixing that policy, and
    -- an assertion that exists with a shut permission is exactly the state the
    -- guards intend.
    null;
  end;

  begin
    update semantic_private.assertion_surface_permissions
       set can_select = true, can_name = true
     where assertion_id = new.id
       and user_id = new.user_id
       and surface = 'bio';
  exception when others then
    null;
  end;

  return new;
end;
$function$;

-- ---------------------------------------------------------------------------
-- The back-fill
-- ---------------------------------------------------------------------------
--
-- **Row by row, not one `update`.** A bulk statement would meet the first
-- guarded assertion, raise, and roll back every grant behind it — so the six
-- YouTube-evidenced rows on one account would have cost the other thirty-two.
do $$
declare
  row_id uuid;
  row_user uuid;
  row_surface text;
  granted integer := 0;
  refused integer := 0;
  first_reason text;
begin
  for row_id, row_user, row_surface in
    select p.assertion_id, p.user_id, p.surface
      from semantic_private.assertion_surface_permissions p
     where p.surface in ('matching', 'bio')
       and p.permission_source = 'default_policy'
       and not p.can_select
  loop
    begin
      update semantic_private.assertion_surface_permissions
         set can_select = true,
             -- Naming is the bio surface's alone; `matching` forbids it by
             -- check constraint.
             can_name = (row_surface = 'bio')
       where assertion_id = row_id
         and user_id = row_user
         and surface = row_surface;
      granted := granted + 1;
    exception when others then
      refused := refused + 1;
      -- **The reason travels with the failure.** A count alone said "178
      -- refused" and named nothing, and the guards it was meant to blame all
      -- turned out to early-return. Same lesson as `pg_net`: what a function
      -- needs to say belongs in what it returns, not only in a log nobody has.
      if first_reason is null then
        first_reason := sqlstate || ' ' || sqlerrm;
      end if;
    end;
  end loop;

  raise notice 'term exposure: % opened across matching+bio, % refused by a guard',
    granted, refused;

  -- **A back-fill that opened nothing is `0117` again** — a change that runs
  -- clean and does nothing, reading as success. Only excusable where there was
  -- nothing to open.
  if granted = 0 and refused = 0 then
    raise notice 'no closed matching rows existed; nothing to back-fill';
  elsif granted = 0 then
    raise exception
      'every one of % rows was refused; first reason: %', refused, first_reason;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- What must still be true afterwards
-- ---------------------------------------------------------------------------
do $$
declare
  open_bio integer;
  open_ice integer;
  open_matching integer;
  shut_matching integer;
begin
  select count(*) filter (where surface = 'bio' and can_name),
         count(*) filter (where surface = 'icebreaker' and can_select),
         count(*) filter (where surface = 'matching' and can_select),
         count(*) filter (where surface = 'matching' and not can_select)
    into open_bio, open_ice, open_matching, shut_matching
    from semantic_private.assertion_surface_permissions;

  if open_ice > 0 then
    raise exception 'icebreaker was opened; it has no consumer and belongs to a later phase';
  end if;

  if exists (select 1 from semantic_private.assertion_surface_permissions
              where can_explain and surface <> 'memories') then
    raise exception 'can_explain was set outside memories; explanation is a third act';
  end if;

  -- Restating the check constraint as an assertion, because the first draft
  -- violated it on every row and a count would not have said so.
  if exists (select 1 from semantic_private.assertion_surface_permissions
              where surface = 'matching' and can_name) then
    raise exception 'matching may use a term and may never name it';
  end if;

  -- **Conditional on there being assertions to grant, which is not a
  -- weakening.** The back-fill is what this asserts, and a back-fill over an
  -- empty table correctly grants nothing — so demanding a non-zero count made
  -- the migration unapplicable to a fresh database and the whole chain
  -- unreplayable. On the database this was written against there were 178
  -- rows and 155 opened; the check that matters is that a *populated* table
  -- did not come out with every row shut, which is the failure it was written
  -- for and which this still catches.
  if open_bio = 0
     and exists (select 1 from semantic_private.assertion_surface_permissions) then
    raise exception 'no bio row can name anything, so no card will show a term';
  end if;

  raise notice 'matching open on %, bio nameable on %, matching still shut on % (guarded)',
    open_matching, open_bio, shut_matching;
end
$$;

-- ---------------------------------------------------------------------------
-- `0125` read the wrong surface
-- ---------------------------------------------------------------------------
--
-- **It returns labels, gated on `matching.can_select`.** But a label is a
-- *name*, and the matching surface may never name — the check constraint above
-- says so in one line. So the gate has to be `bio.can_name`: may this term be
-- shown to the person reading the card.
--
-- `matching.can_select` still matters and is still granted; it is simply about
-- something the app does not do yet, which is letting a term influence *who*
-- appears rather than *what is written* on their card. Requiring both would
-- withhold a nameable term because ranking is unbuilt.
--
-- Everything else about the function is unchanged: the currency rule, the
-- `eligible`-only test, the suppression checks, and `0118`'s witness test for
-- inferred assertions.
create or replace function semantic_private.matching_terms(p_subject uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(term order by term ->> 'score' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'label', coalesce(revision.preferred_label, user_term.label),
               'kind', revision.concept_kind,
               'score', coalesce(score.surfacing_score, 1.0)
             ) as term
        from semantic_private.user_assertions as assertion
        left join semantic_private.user_terms as user_term
          on user_term.id = assertion.user_term_id
         and user_term.user_id = assertion.user_id
        left join semantic_private.assertion_preferences as preference
          on preference.assertion_id = assertion.id
         and preference.user_id = assertion.user_id
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
       where assertion.user_id = p_subject
         and assertion.machine_state = 'eligible'
         and coalesce(preference.display_state, 'default') <> 'suppressed'
         -- **`bio.can_name`, not `matching.can_select`.** Returning a label is
         -- naming, and only the bio surface permits it.
         and exists (
           select 1 from semantic_private.assertion_surface_permissions as permission
            where permission.assertion_id = assertion.id
              and permission.user_id = assertion.user_id
              and permission.surface = 'bio'
              and permission.can_name
         )
         and not exists (
           select 1 from semantic_private.user_suppressions as suppression
            where suppression.user_id = assertion.user_id
              and suppression.predicate_key = assertion.predicate_key
              and suppression.surface in ('matching', 'bio')
              and suppression.active
              and (
                (assertion.concept_id is not null
                 and suppression.concept_id = assertion.concept_id)
                or (assertion.user_term_id is not null
                    and suppression.user_term_id = assertion.user_term_id)
              )
         )
         and (
           assertion.assertion_origin <> 'inferred'
           or (score.id is not null and score_run.id is not null)
         )
         and (
           assertion.assertion_origin <> 'inferred'
           or assertion.concept_id is null
           or semantic_private.concept_has_non_video_witness(
                score_run.id, assertion.concept_id)
         )
         and coalesce(revision.preferred_label, user_term.label) is not null
    ) as permitted;
$$;

revoke all on function semantic_private.matching_terms(uuid) from public, anon, authenticated;

-- **It must now return something**, or the whole exercise is unobserved. A
-- function that answers `[]` for everybody is what `0125` shipped and what this
-- migration exists to correct, so this refuses to pass in that state.
do $$
declare
  subject uuid;
  produced integer;
begin
  select a.user_id into subject
    from semantic_private.user_assertions a
   where a.machine_state = 'eligible'
   group by a.user_id
   order by count(*) desc
   limit 1;

  if subject is null then
    raise notice 'no eligible assertions; matching_terms unexercised';
    return;
  end if;

  produced := jsonb_array_length(semantic_private.matching_terms(subject));
  raise notice 'matching_terms now returns % terms for the busiest account', produced;
  if produced = 0 then
    raise exception
      'matching_terms still returns nothing after opening bio.can_name; '
      'another gate is refusing and this migration has not done its job';
  end if;
end
$$;

commit;
