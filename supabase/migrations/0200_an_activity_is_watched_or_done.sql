-- 0200 — an activity is watched or done, and the predicate is where that lives.
--
-- ## The claim this could not make
--
-- Somebody who plays football and somebody who follows it share a concept and
-- share almost nothing else, and both arrived as `affinity_to activity:soccer`.
-- **Every assertion in production carries `affinity_to`** — one predicate, for
-- every kind of thing, saying only *this person likes this*.
--
-- The gap was already written down, in `score.py`, about a game named in a
-- subscribed channel's keywords: *"Whether somebody **plays** it is a different
-- claim and is not made here."* This is that claim.
--
-- ## Why a predicate and not a second concept
--
-- Minting `activity:soccer` twice — one to watch, one to play — splits the
-- evidence between them and still cannot say which was meant, because **the
-- evidence decides, not the concept**. A HealthKit workout is involvement; a
-- subscription to a football channel is viewing. So one concept keeps
-- accumulating everything and the *claim about it* names the engagement.
--
-- ## Two predicates, and why the obvious ones could not be used
--
-- `ontology.relation_types` already separates watching from doing —
-- `completed_activity` (*"from a structured fitness source"*), `watched`,
-- `attended_activity_at`, `booked_activity_at` (*"not attendance or liking"*) —
-- and **not one of them may be asserted**. They are `relation_class =
-- 'observed_action'` with `assertion_safe = false`, because what somebody did is
-- evidence rather than a claim about them, and
-- `guard_user_assertion_relation_class` refuses both properties for an inferred
-- assertion. `score.py` records what happened the once: *"Asserting it took the
-- whole worker down."*
--
-- `likes_activity` is `user_claim` and also refused — `assertion_safe = false`,
-- *"requiring user addition or confirmation"* — which is a deliberate rule about
-- machine-made claims of *liking* an activity, and is not disturbed here.
--
-- So two new predicates, both `user_claim`, both `assertion_safe`, both zero
-- inference hops for the same reason `affinity_to` is: an engagement does not
-- propagate along `broader`, or playing five-a-side would become participating
-- in sport in general by arithmetic.
--
--     participates_in_activity   the person does this
--     follows_activity           the person watches this
--
-- **`affinity_to` remains and remains the default.** It is what a creator, a
-- work, a genre and a topic get — there is nothing to watch or do about Bach —
-- and it is what an activity gets when the evidence says neither.
--
-- ## Where the rule lives: beside `action_weights`, not in Python
--
-- `semantic_private.sources.engagement_modes` maps an action to `participation`
-- or `spectating`, per source, in the column next to the one that already says
-- what an action is worth. A list in `score.py` would have been a second place
-- to look and the first to go stale.
--
-- **Only what is genuinely one or the other is marked, and the unmarked case is
-- the point.** A saved track is neither watching nor doing; a booked calendar
-- event cannot be told apart at the level of the action, because booking a yoga
-- class and booking a ticket to a match are the same act on the same source.
-- Marking those would be guessing, and an activity attested only by unmarked
-- evidence keeps `affinity_to` — which is the honest reading rather than a
-- fallback.
--
-- ## What this changes today: nothing, and the measurement says why
--
-- Measured across both accounts before writing:
--
--     mappings onto any `activity` concept                     0
--     HealthKit observations in the vault                      0
--     `healthkit.workout` action weight                      0.0
--     suppressions or preferences on an activity               0
--
-- So the participation branch has no evidence to run on, and the spectating
-- branch has no activity to run on. **That is worth stating rather than
-- discovering**: this ships a rule ahead of the data, which is the right order
-- only because the alternative is that the first HealthKit distillation lands
-- and says nothing more than "likes". The unit tests exercise both branches,
-- because a rule that has only ever answered one way is not a rule anybody
-- should believe.
--
-- **`healthkit.workout` is weighted 0.0** and this migration does not change
-- that. Raising it is a separate decision about how much a workout says, and
-- making it here would have hidden a scoring change inside a vocabulary one.
--
-- ## The decision a re-score must not undo
--
-- An assertion under a new predicate is a **new row**, and both places a person's
-- answer is recorded would stop matching it: `assertion_preferences` is keyed on
-- the assertion id, and `user_suppressions` on the predicate itself. A concept
-- moving from `affinity_to` to `follows_activity` would put a suppressed term
-- back on somebody's page — a decision undone by a background job. `score.py`
-- carries both across, copying and never inventing.

begin;

insert into ontology.relation_types (
  predicate_key, relation_class, inverse_predicate_key, is_symmetric,
  transitive_for_inference, max_inference_hops, assertion_safe, description)
values
  ('participates_in_activity', 'user_claim', null, false, false, 0, true,
   'The person does this activity themselves. Inferred only from involvement evidence; never from viewing.'),
  ('follows_activity', 'user_claim', null, false, false, 0, true,
   'The person watches or follows this activity. Never a claim that they do it.')
on conflict (predicate_key) do nothing;

-- **Beside `action_weights`, and `not null` with an empty default**, so a source
-- that has never been classified reads as "nothing marked" rather than as null,
-- which `->>` would answer identically and a reader could not tell apart from a
-- source nobody had considered.
alter table semantic_private.sources
  add column if not exists engagement_modes jsonb not null default '{}'::jsonb;

comment on column semantic_private.sources.engagement_modes is
  'Per action: participation (the person did it) or spectating (the person watched it). '
  'An action absent from this map is neither, which is the common case and not a gap.';

update semantic_private.sources
   set engagement_modes = jsonb_build_object(
         'workout', 'participation',
         'routine', 'participation')
 where source_code = 'healthkit';

update semantic_private.sources
   set engagement_modes = jsonb_build_object(
         'subscription', 'spectating',
         'liked_video', 'spectating',
         'liked', 'spectating',
         'watched', 'spectating',
         'video', 'spectating',
         'shared', 'spectating')
 where source_code = 'youtube';

do $$
declare
  participation_actions integer;
  spectating_actions    integer;
  both_ways             integer;
  unmarked_sources      integer;
  refused               integer := 0;
  accepted              integer := 0;
  probe_concept         uuid;
  probe_version         uuid;
  probe_user            uuid;
  enqueued              integer;
begin
  -- 1. The map answers both ways over real rows, and never both about one act.
  select count(*) into participation_actions
    from semantic_private.sources s,
         lateral jsonb_each_text(s.engagement_modes) as e(action, mode)
   where e.mode = 'participation';
  select count(*) into spectating_actions
    from semantic_private.sources s,
         lateral jsonb_each_text(s.engagement_modes) as e(action, mode)
   where e.mode = 'spectating';
  select count(*) into both_ways
    from semantic_private.sources s,
         lateral jsonb_each_text(s.engagement_modes) as e(action, mode)
   where e.mode not in ('participation', 'spectating');

  if participation_actions = 0 then
    raise exception '0200: no action means participation, so the rule can only ever answer one way';
  end if;
  if spectating_actions = 0 then
    raise exception '0200: no action means spectating, so the rule can only ever answer one way';
  end if;
  if both_ways > 0 then
    raise exception '0200: % action(s) carry a mode that is neither participation nor spectating', both_ways;
  end if;

  -- **And most sources are deliberately unmarked.** If every source were
  -- classified, somebody had guessed — a saved track is neither, and a booked
  -- calendar event cannot be told apart at the level of the action.
  select count(*) into unmarked_sources
    from semantic_private.sources where engagement_modes = '{}'::jsonb;
  if unmarked_sources = 0 then
    raise exception '0200: every source was classified, which means something was guessed';
  end if;

  -- 2. **The guard itself, answering both ways.** A check on `relation_types`
  --    columns would be a check on what the guard *reads*, not on what it
  --    *does*. So the real trigger function runs, against a temporary table
  --    carrying the columns it touches and a real activity concept at the
  --    published version — and it must accept the two new predicates and go on
  --    refusing an observed action.
  --
  --    The production table cannot be used for this: `reject_stale_inferred_assertion`
  --    demands a `running` run at the account's current revision, and a
  --    migration has none, so an insert there would fail for a reason that has
  --    nothing to do with the question.
  select v.id into probe_version from ontology.versions v where v.status = 'published';
  select r.concept_id into probe_concept
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = probe_version
     and r.status = 'active'
     and r.concept_kind = 'activity'
     and r.sensitivity <> 'sensitive'
     and r.inference_policy in ('inferable', 'review_required')
   order by c.concept_key
   limit 1;
  if probe_concept is null then
    raise exception '0200: no activity concept to test the guard against';
  end if;
  select u.id into probe_user from auth.users u limit 1;

  create temporary table guard_probe (
    predicate_key text,
    assertion_origin text,
    concept_id uuid,
    created_ontology_version_id uuid,
    user_id uuid
  ) on commit drop;

  create trigger guard_probe_relation_class
    before insert on guard_probe
    for each row execute function semantic_private.guard_user_assertion_relation_class();

  <<probes>>
  declare
    predicate text;
    should_pass boolean;
  begin
    foreach predicate in array array[
      'participates_in_activity', 'follows_activity', 'affinity_to',
      'watched', 'completed_activity', 'likes_activity'
    ] loop
      should_pass := predicate in
        ('participates_in_activity', 'follows_activity', 'affinity_to');
      begin
        insert into guard_probe values (
          predicate, 'inferred', probe_concept, probe_version, probe_user);
        if should_pass then
          accepted := accepted + 1;
        else
          raise exception '0200: the guard accepted %, which is not assertion-safe', predicate;
        end if;
      exception
        when sqlstate 'P0001' then
          if should_pass then
            raise exception '0200: the guard refused %, which this scorer must be able to write: %',
              predicate, sqlerrm;
          end if;
          refused := refused + 1;
      end;
    end loop;
  end probes;

  if accepted <> 3 or refused <> 3 then
    raise exception '0200: the guard accepted % and refused %, expected 3 and 3', accepted, refused;
  end if;

  -- 3. The worker can read the new column. `semantic_worker` is `bypassrls` and
  --    that is not a grant; a column it cannot select would make every
  --    engagement answer null and every activity fall back to `affinity_to`,
  --    silently and forever.
  if not has_column_privilege('semantic_worker', 'semantic_private.sources',
                              'engagement_modes', 'select') then
    raise exception '0200: semantic_worker cannot read sources.engagement_modes';
  end if;

  -- 4. The model version, and the recompute it implies, in this migration.
  --    Retiring the old one here rather than leaving two active: the finalizer
  --    picks the newest *active* model, so two would work by ordering, which is
  --    a coincidence rather than a statement.
  update ontology.model_versions set status = 'retired'
   where model_key = 'evidence_weighted_scorer' and status = 'active';

  insert into ontology.model_versions (
    id, model_key, version, model_role, code_hash, parameters, status)
  select extensions.gen_random_uuid(), 'evidence_weighted_scorer', '0.15.0',
         'scorer', null,
         old.parameters || jsonb_build_object(
           'engagement_predicates',
           'An activity concept is asserted as participates_in_activity where any '
           || 'evidence for it is marked participation, follows_activity where any '
           || 'is marked spectating, and affinity_to where neither. Participation '
           || 'outranks spectating: it is a positive fact that watching does not '
           || 'contradict. The marks live in semantic_private.sources.engagement_modes '
           || 'beside action_weights; an unmarked action is neither, which is the '
           || 'common case. Only concept_kind = activity is affected, less travel:*, '
           || 'which assert_travel writes outside the concept loop.',
           'engagement_decision_carry',
           'A concept whose predicate changes is a new assertion row, so the '
           || 'preference (keyed on assertion id) and the suppression (keyed on '
           || 'predicate) are copied onto it. Without that a re-score would put a '
           || 'suppressed term back on somebody page.'
         ),
         'active'
    from ontology.model_versions old
   where old.model_key = 'evidence_weighted_scorer' and old.version = '0.14.0';

  if not exists (select 1 from ontology.model_versions
                  where model_key = 'evidence_weighted_scorer'
                    and version = '0.15.0' and status = 'active') then
    raise exception '0200: scorer 0.15.0 was not published';
  end if;
  if (select count(*) from ontology.model_versions
       where model_key = 'evidence_weighted_scorer' and status = 'active') <> 1 then
    raise exception '0200: more than one scorer is active';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.15.0: an activity is watched or done'
         ) into enqueued;

  raise notice '0200: % participation action(s), % spectating action(s), % source(s) unmarked; guard accepted % and refused %; % recompute job(s)',
    participation_actions, spectating_actions, unmarked_sources, accepted, refused, enqueued;
end;
$$;

commit;
