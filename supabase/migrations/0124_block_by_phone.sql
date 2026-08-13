-- 0124 — the block list blocks a phone number, and the server decides whose.
--
-- **`0123` gave blocking a table keyed on an account; the block list collects a
-- phone number.** Those are reconcilable here and nowhere else, because a phone
-- number *is* the account identity in this app: sign-up is phone-only, and
-- `resolve-signin` deletes any Apple or Google account whose `public.users` row
-- has no phone. So a number resolves to at most one person.
--
-- **The resolution must happen server-side, and not for convenience.**
-- `public.users` is `auth.uid() = id`, so a client cannot look a number up —
-- and it must not be able to. A block that answered "found them" would turn the
-- safety screen into an oracle for *"is this person on Written?"*, which is a
-- question about somebody else's account that nobody is entitled to ask. Both
-- functions below therefore **return void and behave identically whether or not
-- the number matches**: no row count, no boolean, no distinguishable error.
--
-- The caller keeps its own list of the numbers it typed — `BanList.person`,
-- which is what the screen draws and what makes the block visible to the person
-- who made it. This adds the half that reaches the other account.
--
-- **A number with no account is not an error.** Blocking somebody who has not
-- joined is the ordinary case for a contacts sync, and the local ban already
-- covers it; if they sign up later, nothing here retroactively blocks them.
-- That gap is real and is recorded rather than papered over: closing it means
-- checking the ban list at signup, which is a different mechanism.

begin;

-- Digits only, on both sides. `users.phone` is stored E.164 (`+85212345678`),
-- and somebody typing into a text field will write spaces, dashes and brackets.
-- **The country code has to be there** — a bare national number is ambiguous
-- across countries, and this deliberately does not guess one: an unmatched
-- number simply blocks nobody, which is the same outcome as a number belonging
-- to no account and is indistinguishable to the caller by design.
create or replace function private.phone_digits(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), '');
$$;

-- Matching is on the normalised form, so the lookup must be too. `immutable`
-- above is what lets this exist at all.
create index if not exists users_phone_digits_idx
  on public.users (private.phone_digits(phone));

create or replace function public.block_by_phone(p_phone text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  target uuid;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;

  select u.id into target
    from public.users u
   where private.phone_digits(u.phone) = private.phone_digits(p_phone)
     and u.id <> me
   limit 1;

  -- **Returns the same way whether or not it found somebody.** This is the
  -- whole reason the function exists rather than the client inserting the row
  -- itself, and it is why there is no `found` out-parameter to be tempted by
  -- later: the difference between "blocked an account" and "blocked a number
  -- nobody has" must not be observable.
  if target is not null then
    insert into public.blocks (blocker_id, blocked_id)
    values (me, target)
    on conflict do nothing;
  end if;
end;
$$;

comment on function public.block_by_phone(text) is
  'Blocks the account holding this number, if any. Returns void and behaves '
  'identically when no account matches — a distinguishable answer would make '
  'the block list an oracle for whether a number is registered. The caller '
  'keeps its own list of typed numbers; this writes the half that reaches the '
  'other account.';

-- **The address book, in one statement.** A contacts sync runs to hundreds of
-- numbers, and `DistillViewModel.block(names:)` already makes this argument for
-- the local half: blocking them one at a time would be hundreds of round trips.
--
-- Same oracle property, and it matters more here rather than less: a count of
-- how many of your contacts are on Written is a far more interesting answer
-- than whether one number is, and it is just as much nobody's business.
create or replace function public.block_by_phones(p_phones text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  if p_phones is null or cardinality(p_phones) = 0 then
    return;
  end if;

  insert into public.blocks (blocker_id, blocked_id)
  select me, u.id
    from public.users u
   where private.phone_digits(u.phone) in (
           select private.phone_digits(p) from unnest(p_phones) as p
         )
     and u.id <> me
  on conflict do nothing;
end;
$$;

comment on function public.block_by_phones(text[]) is
  'Bulk form of block_by_phone for a contacts sync — one statement rather than '
  'one round trip per contact. Void and silent: how many of somebody''s '
  'contacts hold accounts is a more interesting answer than whether one does, '
  'and equally nobody''s business.';

create or replace function public.unblock_by_phone(p_phone text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;

  delete from public.blocks b
   where b.blocker_id = me
     and private.phone_digits((select u.phone from public.users u where u.id = b.blocked_id))
       = private.phone_digits(p_phone);
end;
$$;

comment on function public.unblock_by_phone(text) is
  'Lifts a block on the account holding this number. Void and silent for the '
  'same reason as block_by_phone. A real delete, as 0123 intends: a block is a '
  'list somebody curates, not a record of what happened.';

-- **From `anon` by name, not only from `PUBLIC`.** Supabase installs default
-- privileges that grant execute on every new `public` function to `anon` and
-- `authenticated`, so revoking from the `PUBLIC` pseudo-role leaves that direct
-- grant untouched and the function callable by a signed-out caller. The first
-- draft of this migration did exactly that and its own assertion refused it —
-- which is the mirror of `0053`'s lesson that `revoke ... on schema public`
-- from one role does nothing, seen from the other side.
--
-- The exposure was bounded (`auth.uid()` is null for `anon`, so the body raises
-- before touching anything) and that is not the point: a safety function
-- reachable by a signed-out caller is a fact somebody would have to re-derive.
revoke all on function public.block_by_phone(text) from public, anon;
revoke all on function public.block_by_phones(text[]) from public, anon;
revoke all on function public.unblock_by_phone(text) from public, anon;
grant execute on function public.block_by_phone(text) to authenticated;
grant execute on function public.block_by_phones(text[]) to authenticated;
grant execute on function public.unblock_by_phone(text) to authenticated;

-- **Behaviour, and it must be able to fail.** The normaliser is the part most
-- likely to be quietly wrong, and a mismatch there blocks nobody while looking
-- exactly like a number with no account — the failure this file is arranged
-- around being unable to distinguish.
do $$
begin
  if private.phone_digits('+852 1234 5678') is distinct from '85212345678' then
    raise exception 'phone_digits does not strip formatting';
  end if;
  if private.phone_digits('(852) 1234-5678') is distinct from '85212345678' then
    raise exception 'phone_digits does not agree across punctuation';
  end if;
  if private.phone_digits('') is not null or private.phone_digits(null) is not null then
    raise exception 'phone_digits must answer null for nothing, not an empty string';
  end if;

  -- The oracle property, asserted rather than trusted to the comment above:
  -- neither function may return anything at all.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('block_by_phone', 'block_by_phones', 'unblock_by_phone')
         and p.prorettype <> 'void'::regtype) > 0 then
    raise exception 'a block-by-phone function returns something; that is an oracle';
  end if;

  if has_function_privilege('anon', 'public.block_by_phone(text)', 'execute') then
    raise exception 'anon may block by phone';
  end if;
end
$$;

commit;
