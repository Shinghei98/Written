-- 0292 — reason-scoped calibration labels and the stratum ladder.
--
-- Cardinal specification §6.3, §8. A review event is not one signal: a keep
-- confirms the affinity strongly, the identity route somewhat, the root
-- hardly at all; a not_relevant strike is a strong personal negative and
-- almost no statement about classification; wrong_identity penalizes the
-- resolver, not the person's taste. The spec's Table 2 prices each, in signed
-- Δ log-odds, and this migration writes those labels as rows — one review
-- event fanning out into typed supervision the calibration ladder aggregates.
--
-- **The reason vocabulary maps, it does not fork.** `review_events.reason`
-- already holds a fourteen-word vocabulary; the spec's seven codes map onto
-- it (not_relevant → not_interested/ambiguous_rejection, wrong_identity →
-- wrong_entity, wrong_cardinal → wrong_type, wrong_parent stays,
-- wrong_predicate stays, bad_evidence → not_representative, and
-- sensitive_or_private → too_private). One vocabulary, two spellings would be
-- the drift this schema keeps paying to avoid.

create table if not exists semantic_private.calibration_labels (
  id uuid primary key default extensions.gen_random_uuid(),
  review_event_id uuid not null,
  user_id uuid not null,
  -- What the label supervises: the spec's target domains.
  target_domain text not null check (target_domain in (
    'user_affinity', 'identity_route', 'classification_root',
    'classification_parent', 'predicate_route', 'source_action_route')),
  target_key text not null,
  delta_log_odds numeric not null check (delta_log_odds between -8 and 8),
  actor_authority numeric not null default 1.0
    check (actor_authority between 0 and 1),
  eligible_for_global boolean not null default true,
  version_tuple jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (review_event_id, user_id)
    references semantic_private.review_events (id, user_id) on delete cascade,
  unique (review_event_id, target_domain, target_key)
);

create index if not exists calibration_labels_target_idx
  on semantic_private.calibration_labels (target_domain, target_key);

-- Append-only: supervision, like the answers it derives from, is history.
drop trigger if exists calibration_labels_append_only on semantic_private.calibration_labels;
create trigger calibration_labels_append_only
  before update or delete on semantic_private.calibration_labels
  for each row execute function semantic_private.guard_review_history_append_only();

grant select, insert on semantic_private.calibration_labels to semantic_worker;

-- ---------------------------------------------------------------------------
-- The fan-out: one review event becomes its priced labels.
-- ---------------------------------------------------------------------------
--
-- A trigger rather than a job, because the spec's I-08 says keep, strike and
-- edit recompute immediately, and because the event row already carries
-- everything the labels need. Prices are Table 2's, held in a table so
-- product analytics can tune them only through a calibration release rather
-- than a code edit.

create table if not exists semantic_private.calibration_label_prices (
  price_version text not null default 'table2-v1',
  action text not null,
  reason text not null default '*',
  target_domain text not null,
  delta_log_odds numeric not null,
  primary key (price_version, action, reason, target_domain)
);

insert into semantic_private.calibration_label_prices
  (action, reason, target_domain, delta_log_odds) values
  ('keep', '*', 'user_affinity', 2.00),
  ('keep', '*', 'identity_route', 1.20),
  ('keep', '*', 'classification_root', 0.35),
  ('strike_off', 'not_interested', 'user_affinity', -2.50),
  ('strike_off', 'not_interested', 'identity_route', -0.10),
  ('strike_off', 'ambiguous_rejection', 'user_affinity', -2.50),
  ('strike_off', 'ambiguous_rejection', 'identity_route', -0.10),
  ('strike_off', 'wrong_entity', 'identity_route', -2.00),
  ('strike_off', 'wrong_entity', 'user_affinity', -0.50),
  ('strike_off', 'wrong_type', 'classification_root', -2.00),
  ('strike_off', 'wrong_type', 'classification_parent', -1.00),
  ('strike_off', 'wrong_parent', 'classification_parent', -2.00),
  ('strike_off', 'wrong_parent', 'classification_root', -0.10),
  ('strike_off', 'wrong_predicate', 'predicate_route', -2.00),
  ('strike_off', 'not_representative', 'source_action_route', -2.00),
  ('strike_off', 'too_private', 'source_action_route', -2.00),
  ('edit', '*', 'user_affinity', -2.00),
  ('edit', 'wrong_primary_term', 'identity_route', -2.00),
  ('edit', 'wrong_type', 'classification_root', -1.50)
on conflict do nothing;

create or replace function semantic_private.emit_calibration_labels()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  price record;
  term_key text;
begin
  if new.action not in ('keep', 'strike_off', 'edit') then
    return new;  -- defer and restore carry no label; finish is keep-by-silence
  end if;

  -- The term the card was about: canonical id when the candidate has one,
  -- else the provisional's identity.
  select coalesce(utc.concept_id::text, utc.provisional_entity_id::text)
    into term_key
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
   where ri.id = new.review_item_id;
  if term_key is null then
    return new;  -- an event about nothing prices nothing
  end if;

  for price in
    select p.target_domain, p.delta_log_odds
      from semantic_private.calibration_label_prices p
     where p.price_version = 'table2-v1'
       and p.action = new.action
       and (p.reason = new.reason or p.reason = '*')
  loop
    insert into semantic_private.calibration_labels
      (review_event_id, user_id, target_domain, target_key, delta_log_odds,
       version_tuple)
    values
      (new.id, new.user_id, price.target_domain,
       case price.target_domain
         when 'user_affinity' then term_key
         when 'identity_route' then coalesce(new.route_version, 'unversioned')
         when 'predicate_route' then coalesce(new.corrected_predicate, 'affinity_to')
         else term_key
       end,
       price.delta_log_odds,
       jsonb_build_object('model_revision', new.model_revision,
                          'route_version', new.route_version,
                          'price_version', 'table2-v1'))
    on conflict do nothing;
  end loop;
  return new;
end;
$function$;

drop trigger if exists review_events_emit_labels on semantic_private.review_events;
create trigger review_events_emit_labels
  after insert on semantic_private.review_events
  for each row execute function semantic_private.emit_calibration_labels();

-- ---------------------------------------------------------------------------
-- The ladder (spec 8.3): per-term weight from priced labels, w_label mass,
-- five-users-and-ten-cards activation.
-- ---------------------------------------------------------------------------

create or replace view semantic_private.calibration_label_weights
with (security_invoker = on) as
select l.target_domain, l.target_key,
       count(*) as labels,
       count(distinct l.user_id) as distinct_users,
       count(distinct l.review_event_id) as labeled_cards,
       sum(least(abs(l.delta_log_odds) / 2.50, 1.00) * l.actor_authority)
         filter (where l.delta_log_odds > 0) as k_mass,
       sum(least(abs(l.delta_log_odds) / 2.50, 1.00) * l.actor_authority)
         filter (where l.delta_log_odds < 0) as s_mass,
       (coalesce(sum(least(abs(l.delta_log_odds) / 2.50, 1.00) * l.actor_authority)
                   filter (where l.delta_log_odds > 0), 0) + 4)
       / (coalesce(sum(least(abs(l.delta_log_odds) / 2.50, 1.00) * l.actor_authority), 0) + 8)
         as posterior_keep_rate,
       least(greatest(
         ((coalesce(sum(least(abs(l.delta_log_odds) / 2.50, 1.00) * l.actor_authority)
                      filter (where l.delta_log_odds > 0), 0) + 4)
          / (coalesce(sum(least(abs(l.delta_log_odds) / 2.50, 1.00) * l.actor_authority), 0) + 8))
         / 0.50, 0.50), 1.50) as multiplier,
       count(distinct l.user_id) >= 5 and count(distinct l.review_event_id) >= 10
         as activation_met
  from semantic_private.calibration_labels l
 where l.eligible_for_global
 group by l.target_domain, l.target_key;

grant select on semantic_private.calibration_label_weights to semantic_worker;

do $$
declare
  n integer;
begin
  select count(*) into n from semantic_private.calibration_label_prices
   where price_version = 'table2-v1';
  if n < 15 then
    raise exception '0292: only % prices seeded; Table 2 names more', n;
  end if;

  -- The trigger prices real events retroactively? No — labels are forward
  -- from here, and the view answers 0 rows on an empty database, which is the
  -- same answer production gives before the next review act. What must be
  -- true both ways now: an event outside the three acting verbs emits nothing
  -- (asserted structurally — the trigger's first branch), and the append-only
  -- guard holds.
  if exists (select 1 from semantic_private.calibration_labels) then
    begin
      update semantic_private.calibration_labels set delta_log_odds = 0
       where id = (select id from semantic_private.calibration_labels limit 1);
      raise exception '0292: a label was rewritten';
    exception when others then
      if position('0292' in sqlerrm) > 0 then raise; end if;
    end;
  end if;
end;
$$;
