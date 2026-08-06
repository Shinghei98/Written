-- One person, one account, keyed by a phone number.
--
-- **`public.users.phone` has been unique since `0001` and nothing has ever
-- written it.** No trigger populated it, no client code set it, and there was
-- no trigger creating `public.users` from `auth.users` at all — a row appeared
-- only when `upsertProfile` ran at the name step, which is several screens into
-- onboarding and skippable by force-quitting. So the uniqueness constraint was
-- real and enforced nothing, and "one account per phone number" was a rule with
-- no mechanism.
--
-- This gives it one. Two triggers and a backfill, and after them the question
-- "does an account exist for this person" has an answer that does not depend on
-- how far through onboarding they got.

-- ---------------------------------------------------------------------------
-- The row now exists from the moment the account does
-- ---------------------------------------------------------------------------
--
-- `security definer` because the trigger runs as the *authenticating* user,
-- who at that instant has no row and therefore fails `public.users`' own
-- `auth.uid() = id` policy. `set search_path` alongside it, because a definer
-- function without one is the standard way to hand an attacker a search path.
--
-- `on conflict do nothing` rather than an upsert: this trigger's job is to make
-- sure a row *exists*, and it must never overwrite a name or a birth date that
-- `upsertProfile` has already written. The phone is filled in by the second
-- trigger below if it arrives later.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.users (id, phone)
    values (new.id, new.phone)
    on conflict (id) do nothing;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- …and keeps its phone in step
-- ---------------------------------------------------------------------------
--
-- Phone-number sign-up writes `auth.users.phone` when the SMS code is verified,
-- which is *after* the insert — so without this the row created above would
-- keep a null phone forever, and every account would look unlinked to
-- `resolve-signin`. That is the failure this trigger exists for, not a
-- hypothetical number change.
create or replace function public.sync_auth_user_phone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    update public.users set phone = new.phone where id = new.id;
    return new;
end;
$$;

drop trigger if exists on_auth_user_phone_changed on auth.users;
create trigger on_auth_user_phone_changed
    after update of phone on auth.users
    for each row
    when (new.phone is distinct from old.phone)
    execute function public.sync_auth_user_phone();

-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------
--
-- Accounts that predate the triggers. Both statements are idempotent, so this
-- migration can be replayed.

insert into public.users (id, phone)
select a.id, a.phone
from   auth.users a
on conflict (id) do nothing;

update public.users u
set    phone = a.phone
from   auth.users a
where  a.id = u.id
  and  u.phone is null
  and  a.phone is not null;

-- ---------------------------------------------------------------------------
-- What this does not do
-- ---------------------------------------------------------------------------
--
-- It does not delete or merge the accounts that already exist without a phone —
-- the ones created by Apple or Google under the old rule. They keep working;
-- they simply cannot be signed into by a *new* Apple or Google identity, which
-- is what `resolve-signin` enforces. Merging duplicates is a product decision
-- with somebody's data on the end of it and does not belong in a migration.
