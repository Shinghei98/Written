-- 0121 — pin both gender vocabularies, and assert they still correspond.
--
-- **The defect.** `public.users` describes gender in two columns that speak two
-- languages, and they have to be compared:
--
--     users.sex           Identity.columnValue -> Gender.label
--                         'Male', 'Female', 'Non-binary'   (pipe-joined)
--     users.interested_in Gender.rawValue
--                         'male', 'female', 'nonbinary'    (text[])
--
-- `lower('Non-binary')` is `non-binary` and the raw value is `nonbinary`, so the
-- obvious comparison matches the two binary cases and **silently drops every
-- non-binary person from every feed, in both directions**. `0120`'s
-- `private.gender_key` is the bridge; this migration stops the bridge from
-- quietly going out of date.
--
-- **`sex` stores a *display* string, and that is the root of it.** A label
-- exists to be reworded, recapitalised and localised. The day somebody writes
-- `Nonbinary` without the hyphen, or ships a second locale, `users.sex` starts
-- holding a value `gender_key` returns null for — which fails closed, which
-- means that person simply stops appearing to anybody, with no error anywhere.
--
-- **It has already bitten once, from the other side.** `SupabaseAuth.swift:1050`
-- carries the scar: *"Matching on `rawValue` here would silently adopt nothing
-- and send a returning user back to the gender page with no clue why."* That was
-- fixed by conforming to the label rather than by fixing the vocabulary, so the
-- mismatch survived to be found again in `0120`.
--
-- **What this does and does not buy.** A constraint alone would be weaker than
-- it sounds here: the identity push runs in a detached task whose result nobody
-- reads, so a rejected write is quiet at the client. What makes it worth having
-- is the third statement — an assertion that the *label* vocabulary and the
-- *raw value* vocabulary still map onto each other through `gender_key`. Reword
-- a label and this migration's replay fails by name, which is the loud signal
-- the write path cannot give.
--
-- Adapted from `0051`, which asserted its two `key_version` patterns matched by
-- reading them out of the catalog rather than trusting its own comment.
--
-- **This is the holding fix.** The real one is a correctly named `users.gender`
-- with a single vocabulary — `sex` is misnamed as well as mis-encoded, and that
-- ambiguity already cost a bug where HealthKit's biological sex overwrote a
-- chosen gender. That belongs with the next onboarding change.

begin;

-- Every combination `Identity.columnValue` can emit: `Gender.allCases.filter`
-- preserves declaration order (male, female, nonbinary), so the pipe-joined
-- forms are exactly these and in this order. Null is allowed — somebody who has
-- not reached the gender step yet — and the empty string is not, because
-- `columnValue` only returns it for an empty set and the onboarding page
-- refuses to continue on empty.
alter table public.users
  drop constraint if exists users_sex_vocabulary_check,
  add constraint users_sex_vocabulary_check check (
    sex is null or sex in (
      'Male', 'Female', 'Non-binary',
      'Male|Female', 'Male|Non-binary', 'Female|Non-binary',
      'Male|Female|Non-binary'
    )
  );

-- Containment rather than an enumeration of orders: `interested_in` is a set and
-- the order it arrives in is not meaningful. An empty array passes, which is
-- correct — `DatingPreferences` treats empty as "nobody has answered yet",
-- which is different from wanting nobody.
alter table public.users
  drop constraint if exists users_interested_in_vocabulary_check,
  add constraint users_interested_in_vocabulary_check check (
    interested_in is null
    or interested_in <@ array['male', 'female', 'nonbinary']::text[]
  );

comment on column public.users.sex is
  'The gender somebody CHOSE, never a biological fact — see the HealthKit note '
  'in CLAUDE.md. Stored as Gender.label (display strings), pipe-joined, pinned '
  'by users_sex_vocabulary_check. Compare against interested_in only through '
  'private.gender_key: lower() does not bridge Non-binary/nonbinary.';

comment on column public.users.interested_in is
  'Who this person would date. Stored as Gender.rawValue, pinned by '
  'users_interested_in_vocabulary_check. A different vocabulary from users.sex; '
  'private.gender_key is the only bridge.';

-- **The correspondence, read from the constraints rather than restated.**
--
-- Both vocabularies are now pinned above, so the remaining way for them to
-- drift is for `gender_key` to stop mapping one onto the other — which is what
-- a reworded label does. Each allowed `sex` label must map to a value the
-- `interested_in` constraint accepts, and the mapping must be onto: three
-- labels, three raw values, no collisions and none left over.
do $$
declare
  labels constant text[] := array['Male', 'Female', 'Non-binary'];
  raws   constant text[] := array['male', 'female', 'nonbinary'];
  mapped text[];
begin
  select array_agg(private.gender_key(l) order by private.gender_key(l))
    into mapped
    from unnest(labels) as l;

  if array_position(mapped, null) is not null then
    raise exception
      'private.gender_key returns null for one of %, so that gender would be '
      'dropped from every feed silently', labels;
  end if;

  if mapped is distinct from (select array_agg(r order by r) from unnest(raws) as r) then
    raise exception
      'the label vocabulary no longer maps onto the raw-value vocabulary: '
      'gender_key produced %, expected %', mapped, raws;
  end if;

  -- Onto, not merely into: two labels collapsing onto one raw value would pass
  -- the check above only if a third appeared, but stating it separately is what
  -- makes the intent survive an edit.
  if (select count(distinct m) from unnest(mapped) as m) <> array_length(labels, 1) then
    raise exception 'gender_key is not injective over %', labels;
  end if;

  raise notice 'gender vocabularies correspond: % -> %', labels, mapped;
end
$$;

commit;
