-- 0123 — blocking, and it is enforced where the client cannot see it.
--
-- **The last of Phase 4's blockers.** §10 requires discovery RPCs to enforce
-- mutual block on every request; `0120` shipped `private.is_blocked` as a stub
-- returning false because there was no table, no UI and no product decision.
-- This is the decision, made 2026-08-12:
--
--   * **Both ways.** Neither sees the other in discovery, ever.
--   * **The conversation stays visible and freezes.** Both keep the thread and
--     neither can send. Past contact is history they both took part in;
--     blocking ends future contact rather than erasing the past.
--   * **A pending invitation is revoked.** An admirer row for somebody you have
--     blocked is exactly what blocking should prevent.
--   * **The blocked person is told nothing.** No notification, no error naming
--     the block; the other person simply stops appearing.
--
-- **That last decision is what dictates the mechanism, and it is worth setting
-- out because the obvious implementation is wrong.** RLS policies are evaluated
-- as the *caller*, so a policy that consults the block table would need
-- `authenticated` to hold execute on the check — and anything a client may call,
-- a client may probe: `is_blocked(me, them)` would answer the one question the
-- blocked person must not be able to ask. It would also mean granting usage on
-- `private`, where `anon`, `authenticated` and `service_role` have none and the
-- ACL fingerprint is checked either side of every deploy.
--
-- So enforcement lives in **`security definer` triggers and RPCs**, which run as
-- their owner and are never invoked by a client. `private.is_blocked` stays
-- ungranted and unprobeable, and the *select* policy on `blocks` shows a row
-- only to the person who created it. Invisibility is structural rather than a
-- thing the UI remembers not to draw.

begin;

-- **One row per direction, and the pair is the key.** A block is a fact one
-- person asserts about another; `is_blocked` reads it symmetrically, so B
-- blocking A and A blocking B are two rows that mean the same thing to every
-- consumer and different things to the two people.
create table if not exists public.blocks (
  blocker_id uuid not null references public.users(id) on delete cascade,
  blocked_id uuid not null references public.users(id) on delete cascade,
  -- Nullable and unconstrained on purpose: moderation vocabulary is not settled
  -- and inventing one here would be inventing a taxonomy nobody has agreed.
  reason_code text,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_distinct_check check (blocker_id <> blocked_id)
);

alter table public.blocks enable row level security;

-- **Only the blocker may read the row, and that is the no-signal promise made
-- structural.** The blocked person cannot select it, cannot count it, and
-- cannot infer it from an error — every refusal they meet is the same refusal
-- somebody unmatched meets.
drop policy if exists "own blocks" on public.blocks;
create policy "own blocks" on public.blocks
  for select using (auth.uid() = blocker_id);

drop policy if exists "block someone" on public.blocks;
create policy "block someone" on public.blocks
  for insert with check (auth.uid() = blocker_id);

-- **Unblocking is a real delete.** "Nothing in Postgres is ever deleted"
-- describes the distillation record, not a list somebody curates — the same
-- argument `0035` made for bookmarks.
drop policy if exists "unblock" on public.blocks;
create policy "unblock" on public.blocks
  for delete using (auth.uid() = blocker_id);

-- No update policy: a block has nothing to change, and lifting one is the
-- delete above.

grant select, insert, delete on public.blocks to authenticated;

-- **The stub `0120` named, now real.** Symmetric by design: whichever of the
-- two pressed the button, neither may reach the other.
--
-- `stable`, not `immutable` — it reads a table, and `0102` already paid for
-- that distinction once: an `immutable` function may be folded at plan time,
-- which for a guard means evaluated once and never again.
--
-- `security definer` so it sees rows the caller may not, which is the whole
-- point; and deliberately **not granted to any client role**, because a
-- boolean a blocked person can call is a boolean that tells them they are
-- blocked.
create or replace function private.is_blocked(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks b
     where (b.blocker_id = p_a and b.blocked_id = p_b)
        or (b.blocker_id = p_b and b.blocked_id = p_a)
  );
$$;

comment on function private.is_blocked(uuid, uuid) is
  'Symmetric: true if either has blocked the other. security definer so it sees '
  'rows the caller cannot, and granted to no client role — a boolean the blocked '
  'person could call would tell them they are blocked. Called from RPCs and '
  'triggers that are themselves definer, never from an RLS policy.';

revoke all on function private.is_blocked(uuid, uuid) from public;

-- `revoked` joins the vocabulary rather than reusing `declined`: "I answered no"
-- and "this was withdrawn when somebody blocked" are different facts, and
-- collapsing them would lose the distinction in the only table that records it.
alter table public.likes
  drop constraint if exists likes_status_check,
  add constraint likes_status_check check (
    status in ('pending', 'accepted', 'declined', 'revoked')
  );

-- **Blocking revokes a pending invitation, and does not touch an accepted one.**
-- An accepted like is why a conversation exists, and the conversation is kept
-- and frozen rather than erased — un-accepting it would make the thread
-- unexplainable.
create or replace function private.revoke_likes_on_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.likes
     set status = 'revoked', responded_at = now()
   where status = 'pending'
     and ((liker_id = new.blocker_id and liked_id = new.blocked_id)
       or (liker_id = new.blocked_id and liked_id = new.blocker_id));
  return new;
end;
$$;

drop trigger if exists blocks_revoke_pending_likes on public.blocks;
create trigger blocks_revoke_pending_likes
after insert on public.blocks
for each row execute function private.revoke_likes_on_block();

-- **A trigger, not a policy** — see the head of this file. It runs as its owner
-- when the client inserts, so the client needs no privilege on it and cannot
-- call it to ask whether it would refuse.
create or replace function private.refuse_blocked_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_blocked(new.liker_id, new.liked_id) then
    -- Deliberately says nothing about a block. `23503` already means "that
    -- person is gone" to this client, and an unavailable profile is the message
    -- the feed already shows for a deleted account.
    raise exception 'that profile is no longer available'
      using errcode = 'foreign_key_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists likes_refuse_when_blocked on public.likes;
create trigger likes_refuse_when_blocked
before insert on public.likes
for each row execute function private.refuse_blocked_like();

-- **Freezing, which is what "visible but frozen" means in practice.** The
-- select policies on `conversations` and `messages` are untouched, so both
-- people keep the thread and everything already in it; only new messages are
-- refused, and refused for *both* sides rather than only the blocked one.
create or replace function private.refuse_blocked_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  a uuid;
  b uuid;
begin
  select c.user_a, c.user_b into a, b
    from public.conversations c
   where c.id = new.conversation_id;

  if a is not null and private.is_blocked(a, b) then
    raise exception 'this conversation is closed'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

drop trigger if exists messages_refuse_when_blocked on public.messages;
create trigger messages_refuse_when_blocked
before insert on public.messages
for each row execute function private.refuse_blocked_message();

-- **The second place `0122` said blocking would have to be consulted.** Its
-- conversation clause authorises on the thread existing, and a frozen thread
-- still exists — so without this, blocking somebody would leave their school
-- and bio readable through the chat banner's avatar.
create or replace function public.match_profile(target uuid)
returns table(school text, bio text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    me uuid := auth.uid();
begin
    if me is null or target is null or me = target then
        return;
    end if;

    -- Before anything else: a block ends every route, including the frozen
    -- conversation that `0122` deliberately left as sufficient authorisation.
    if private.is_blocked(me, target) then
        return;
    end if;

    if not exists (
        select 1 from public.likes l
         where l.liker_id = target and l.liked_id = me
           and l.status in ('pending', 'accepted')
    ) and not exists (
        select 1 from public.conversations c
         where (c.user_a = me and c.user_b = target)
            or (c.user_a = target and c.user_b = me)
    ) then
        return;
    end if;

    return query
    with latest as (
        select distinct on (d.data_type) d.data_type, d.name
          from public.distilled_records d
         where d.user_id = target
           and d.source = 'user'
           and d.data_type in ('education', 'bio')
           and d.removed_at is null
         order by d.data_type, d.distilled_at desc
    )
    select (select name from latest where data_type = 'education'),
           (select name from latest where data_type = 'bio');
end;
$function$;

-- **Behaviour, and it must be able to fail.** `0117` shipped a guard that read
-- an empty table and its own check passed, so these assert the symmetry and the
-- privilege posture rather than that the function exists.
do $$
declare
  a constant uuid := '00000000-0000-0000-0000-0000000000a1';
  b constant uuid := '00000000-0000-0000-0000-0000000000b2';
begin
  if private.is_blocked(a, b) then
    raise exception 'is_blocked is true for a pair with no rows';
  end if;

  -- No client role may call it, or the blocked person can ask.
  if has_function_privilege('authenticated', 'private.is_blocked(uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'private.is_blocked(uuid,uuid)', 'execute') then
    raise exception 'is_blocked is callable by a client role';
  end if;

  -- And the schema itself stays shut, which is the invariant the ACL
  -- fingerprint check watches either side of a deploy.
  if has_schema_privilege('authenticated', 'private', 'usage')
     or has_schema_privilege('anon', 'private', 'usage') then
    raise exception 'a client role gained usage on private';
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'blocks' and cmd = 'SELECT'
       and qual like '%blocker_id%'
  ) then
    raise exception 'blocks select policy does not restrict to the blocker';
  end if;
end
$$;

commit;
