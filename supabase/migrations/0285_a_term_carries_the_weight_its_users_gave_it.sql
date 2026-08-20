-- 0285 — a term carries the weight its users gave it, and the log it is
-- computed from becomes append-only in fact rather than by omission.
--
-- `0257` already has the arithmetic and it is right: posterior
-- `(keeps + α) / (keeps + strikes + α + β)` with α = β = 4, a multiplier
-- clamped to `[0.5, 1.5]`, one vote per user per proposal per independence
-- root, and a five-distinct-user support floor. What it does not have is the
-- **grain**: `calibration_dry_run` groups by
-- `(source_code, action_type, mention_family, mention_role, relation_kind)`,
-- so it can say what a YouTube like of an anime is worth and can never say
-- what *this word* is worth. The ledger carries `provisional_entity_id` and
-- `concept_id` and drops both before the aggregate.
--
-- The owner's rule needs the other grain: **confidence rises as more users
-- allow a term and falls as more strike it, and the term never disappears.**
-- So this adds a per-term aggregate beside the per-stratum one — the same
-- parameters row, the same formula, the same floor — rather than a second
-- calibration with its own numbers to drift.
--
-- Two deliberate differences from the dry run, both because this weight is for
-- *ordering* rather than for scoring evidence:
--
--   * **No support gate on the value.** Below five users the dry run returns a
--     flat 1.0 because a multiplier that moves evidence must not move on one
--     opinion. An ordering weight may: the prior is 0.5 and one keep pulls it
--     to 0.56, which is exactly the nudge a queue should feel. `support_met`
--     is reported beside it so no reader can mistake the two.
--   * **Nothing is ever hidden.** The owner's decision: a struck term sorts
--     lower and stays in the queue. There is no floor at which a term leaves.

create or replace view semantic_private.presumed_term_weights
with (security_invoker = on) as
with votes as (
  -- One vote per user per proposal per independence root, exactly as
  -- `calibration_dry_run` counts them — a person who met the same term through
  -- four videos of one channel has one opinion about it, not four.
  select distinct
         t.id as presumed_term_id,
         l.user_id,
         l.review_item_id,
         l.independence_root,
         l.calibration_vote
    from semantic_private.calibration_feedback_ledger l
    join semantic_private.provisional_entities p
      on p.id = l.provisional_entity_id
    join semantic_private.presumed_terms t
      on t.id = p.presumed_term_id
   where l.calibration_vote in ('positive', 'negative')
)
select t.id as presumed_term_id,
       t.normalized_label,
       t.family,
       coalesce(count(*) filter (where v.calibration_vote = 'positive'), 0) as keeps,
       coalesce(count(*) filter (where v.calibration_vote = 'negative'), 0) as strikes,
       coalesce(count(distinct v.user_id), 0) as distinct_users,
       prm.alpha / (prm.alpha + prm.beta) as prior_keep_rate,
       -- **`count(v.calibration_vote)`, never `count(*)`.** The join is a left
       -- one, so an unjudged term still produces a row and `count(*)` counts
       -- it: the denominator became 1 and every untouched word sat at 0.444
       -- instead of the prior. Caught by the assertion below on real data
       -- after passing a replay where no term has been judged at all — the
       -- shape of check that only fires where the input exists.
       (count(*) filter (where v.calibration_vote = 'positive') + prm.alpha)
         / (count(v.calibration_vote) + prm.alpha + prm.beta) as weight,
       count(distinct v.user_id) >= prm.min_distinct_users as support_met,
       prm.version as parameters_version
  from semantic_private.presumed_terms t
  cross join semantic_private.calibration_parameters prm
  left join votes v on v.presumed_term_id = t.id
 where prm.version = 'calibration_v1'
 group by t.id, t.normalized_label, t.family,
          prm.alpha, prm.beta, prm.min_distinct_users, prm.version;

comment on view semantic_private.presumed_term_weights is
  'Per-term confidence from user decisions: 0257''s formula at term grain. '
  'An unjudged term sits at the prior (0.5); keeps raise it, strikes lower it, '
  'and nothing removes it (0285).';

grant select on semantic_private.presumed_term_weights to semantic_worker;

-- ---------------------------------------------------------------------------
-- The log the weight is computed from becomes append-only in fact.
-- ---------------------------------------------------------------------------
--
-- `review_items` and `review_exposures` have carried
-- `guard_review_history_append_only` since `0203`, for the stated reason that
-- a feedback label is uninterpretable without the arrangement it was given in.
-- **`review_events` — the answers themselves — never got the trigger.** It is
-- append-only only because `semantic_worker` was never granted `update`, which
-- is a property of one role's privileges rather than of the table: any
-- `security definer` function, and the owner, can still rewrite an answer.
--
-- That was survivable while nothing read the log twice. It is not survivable
-- now: every term's weight is a function of these rows, so a silent update
-- would change a number that people see, with no record that it moved. Same
-- guard, same erasure exception `0204` established for the cascade.

drop trigger if exists review_events_append_only on semantic_private.review_events;
create trigger review_events_append_only
  before update or delete on semantic_private.review_events
  for each row execute function semantic_private.guard_review_history_append_only();

do $$
declare
  probe uuid;
  weighted integer;
begin
  -- The guard refuses an update to a real answer, and permits the erasure
  -- cascade, which is what `guard_review_history_append_only` already encodes.
  select id into probe from semantic_private.review_events limit 1;
  if probe is not null then
    begin
      update semantic_private.review_events set reason = 'duplicate' where id = probe;
      raise exception '0285: a recorded answer was rewritten';
    exception when others then
      if position('append' in lower(sqlerrm)) = 0
         and position('0285' in sqlerrm) > 0 then
        raise;
      end if;
    end;
  end if;

  -- Every dictionary entry has a weight, judged or not — an unjudged term
  -- sits at the prior rather than at null, because null would sort as unknown
  -- and the queue would have to invent a rule for it.
  select count(*) into weighted from semantic_private.presumed_term_weights;
  if weighted <> (select count(*) from semantic_private.presumed_terms) then
    raise exception '0285: % of % dictionary entries carry no weight',
      (select count(*) from semantic_private.presumed_terms) - weighted,
      (select count(*) from semantic_private.presumed_terms);
  end if;

  -- And an unjudged term sits exactly at the prior.
  if exists (select 1 from semantic_private.presumed_term_weights
              where keeps = 0 and strikes = 0 and weight <> 0.5) then
    raise exception '0285: an unjudged term does not sit at the prior';
  end if;
end;
$$;
