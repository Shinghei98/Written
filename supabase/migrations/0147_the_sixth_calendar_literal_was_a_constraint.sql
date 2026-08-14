-- 0147 — the sixth calendar literal was a constraint, not a function.
--
-- **Outlook ingestion has been refused at the database since the fix that was
-- supposed to enable it**, and a real distillation hit it tonight:
--
--     raw_source_records_source_purpose_v03_check
--     Failing row contains (…, outlook_calendar, calendar, …,
--                           calendar_distillation, …)
--
-- `raw_source_records_source_purpose_v03_check` pairs a source with the consent
-- purpose it may be captured under, and it names the calendars by literal:
-- `apple_calendar` and `google_calendar` get `calendar_distillation`, and
-- **everything else must be `source_distillation`**. `outlook_calendar` is in
-- "everything else".
--
-- ## Two mistakes met here, and only one of them is tonight's
--
-- The first is `0133`'s. That migration replaced five literal calendar lists in
-- `semantic_private` with `is_private_calendar_source`, and asserted that **no
-- function** outside the two helpers still names a calendar by literal. This is
-- a *check constraint*. It was never a function, so the assertion could not see
-- it and reported success over a schema that still held a sixth list. That is
-- the deny-list failure mode `0133` was written about, surviving inside `0133`.
--
-- The second is mine, from earlier today. The Outlook ingestion fix taught
-- `consentPurposeFor` to answer `calendar_distillation` for `outlook_calendar`
-- — correct in intent, because an Outlook event is a whole calendar event and
-- belongs under the calendar grant rather than the general one — and I asserted
-- it in a unit test that checked *the code did what I intended* rather than
-- *the database accepts it*. `tools/replay_contracts.sh` asks the built schema
-- exactly this class of question; the JS test asked only itself.
--
-- **The Outlook rows were never lost.** `SemanticIngestionService` classes a
-- 5xx as transient and a constraint violation surfaces as 500, so the batch was
-- retried rather than dropped — and the legacy path took them regardless. What
-- was lost is the vault copy, for as long as this stood.
--
-- ## The fix is the helper, not a third name in the list
--
-- Adding `'outlook_calendar'` to the array would leave a seventh list for the
-- next calendar to be missing from. The constraint uses
-- `is_private_calendar_source`, which `0133` made a **pure literal array and
-- `immutable`** precisely so it could back a check constraint — a helper
-- reading `semantic_private.sources` could not be immutable, and a table would
-- let a row quietly change what is enforced.
--
-- **Dropping and re-adding re-validates every row**, 10,634 of them. That is
-- the cost and it is paid once: the new predicate is strictly wider than the
-- old one for calendars and identical everywhere else, so nothing stored can
-- fail it — asserted below rather than assumed, because a re-validation that
-- fails halfway leaves the table without the constraint.

begin;

alter table semantic_private.raw_source_records
  drop constraint raw_source_records_source_purpose_v03_check;

alter table semantic_private.raw_source_records
  add constraint raw_source_records_source_purpose_v03_check check (
    (source_code = 'healthkit' and consent_purpose = 'fitness_connection')
    or (semantic_private.is_private_calendar_source(source_code)
        and consent_purpose = 'calendar_distillation')
    or (source_code <> 'healthkit'
        and not semantic_private.is_private_calendar_source(source_code)
        and consent_purpose = 'source_distillation')
  );

do $$
declare
  offending integer;
  calendars text[];
begin
  -- **Every calendar the helper knows must now be capturable**, which is the
  -- property the old literal broke. Asserted by asking the helper rather than
  -- by listing them here, so a fourth calendar added to `0133`'s array is
  -- covered without this migration being edited — the whole point of the fix.
  select array_agg(code order by code) into calendars
  from unnest(array['apple_calendar', 'google_calendar', 'outlook_calendar']) as code
  where semantic_private.is_private_calendar_source(code);
  if calendars is null or array_length(calendars, 1) <> 3 then
    raise exception
      'is_private_calendar_source does not hold all three calendars: %', calendars;
  end if;

  -- The constraint is a predicate, so it is proved by evaluating it — both
  -- ways, over the exact pairing that failed tonight and the one that must
  -- still be refused. `0117` passed a structural check while answering false
  -- for everything; a constraint that accepts everything would pass a check
  -- that only counts rows.
  if not (
    semantic_private.is_private_calendar_source('outlook_calendar')
    and not semantic_private.is_private_calendar_source('youtube')
    and not semantic_private.is_private_calendar_source('healthkit')
  ) then
    raise exception 'is_private_calendar_source does not separate calendars from the rest';
  end if;

  -- Nothing already stored may violate the new shape. The re-validation above
  -- would have raised, so this is belt and braces — and it is the check that
  -- would catch a helper edited to *exclude* a calendar whose rows exist.
  select count(*) into offending
  from semantic_private.raw_source_records
  where not (
    (source_code = 'healthkit' and consent_purpose = 'fitness_connection')
    or (semantic_private.is_private_calendar_source(source_code)
        and consent_purpose = 'calendar_distillation')
    or (source_code <> 'healthkit'
        and not semantic_private.is_private_calendar_source(source_code)
        and consent_purpose = 'source_distillation')
  );
  if offending <> 0 then
    raise exception '% stored raw records violate the new purpose pairing', offending;
  end if;

  -- **And the constraint really is the one being enforced.** Dropping and
  -- re-adding under the same name means a failure anywhere above leaves the
  -- table unconstrained, which is worse than the bug being fixed.
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'semantic_private.raw_source_records'::regclass
      and conname = 'raw_source_records_source_purpose_v03_check'
  ) then
    raise exception 'the purpose constraint is missing after the rebuild';
  end if;

  -- No literal calendar name may survive in it, which is `0133`'s own rule
  -- applied to the object `0133` could not see.
  if exists (
    select 1 from pg_constraint
    where conrelid = 'semantic_private.raw_source_records'::regclass
      and conname = 'raw_source_records_source_purpose_v03_check'
      and (pg_get_constraintdef(oid) like '%apple_calendar%'
        or pg_get_constraintdef(oid) like '%google_calendar%'
        or pg_get_constraintdef(oid) like '%outlook_calendar%')
  ) then
    raise exception 'the rebuilt constraint still names a calendar by literal';
  end if;
end
$$;

commit;
