-- 0129 — a conversation becomes a match authorization.
--
-- **The dyad producer cannot run without this, and nothing writes it.**
-- `guard_dyad_run_current` refuses any dyad run where
-- `active_match_authorization_id_v031(viewer, subject)` is null — *"dyad run
-- requires an exact current social authorization"* — and
-- `semantic_private.match_authorizations` has 0 rows. Six functions read that
-- table; nothing in the app or the schema has ever inserted into it. The
-- integration plan names it as what new matches use, and it was never wired.
--
-- **The app's fact of a match is `public.conversations`.** `0009` lets a row be
-- inserted only by a participant and only where an *accepted* like exists
-- between the two, so its existence already means "these two agreed" — which is
-- exactly what an authorization records. So the bridge is a trigger on that
-- table rather than a new product step.
--
-- **`match_id` is the conversation's id**, deliberately. It has to be stable
-- for the pair across epochs — `guard_match_authorization_identity` refuses a
-- later epoch whose participants differ from the first — and the conversation
-- is the one identifier this app already keeps per pair for life. Minting a
-- fresh uuid would mean a second identity to keep in step with the first.
--
-- **Participants are ordered by uuid.** The pair is unordered everywhere that
-- reads it, and `active_match_authorization_id_v031` checks both directions —
-- but writing them in a stable order means two rows for one pair can be
-- compared without normalising them first.
--
-- **Blocking revokes it**, because `0123` decided a block ends future contact:
-- an authorization surviving a block would let a dyad be computed for two
-- people who may not reach each other. The conversation itself stays and
-- freezes, which is the product decision; the *authorization* does not.

begin;

create or replace function private.open_match_authorization()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  first_user uuid;
  second_user uuid;
  next_epoch bigint;
begin
  first_user := least(new.user_a, new.user_b);
  second_user := greatest(new.user_a, new.user_b);

  -- A conversation can only exist once per pair, so in practice this is epoch
  -- 1 — but a revoked epoch stays on the table (it is history, and the
  -- invalidation trigger keys off it), so a re-authorization must count past
  -- whatever is already there rather than assume.
  select coalesce(max(authorization_epoch), 0) + 1 into next_epoch
    from semantic_private.match_authorizations
   where match_id = new.id;

  -- **An active authorization already covering this pair is left alone.** The
  -- guard reads the newest active row; opening a second would make "which one"
  -- a question nobody should have to answer.
  if semantic_private.active_match_authorization_id_v031(first_user, second_user)
     is not null then
    return new;
  end if;

  insert into semantic_private.match_authorizations (
    match_id, participant_a_user_id, participant_b_user_id,
    authorization_state, authorization_epoch, source_version
  ) values (
    new.id, first_user, second_user, 'active', next_epoch, 'conversations_v1'
  );

  return new;
end;
$$;

comment on function private.open_match_authorization() is
  'A conversation is the app''s record that two people agreed — 0009 permits '
  'the insert only where an accepted like exists — so it opens the semantic '
  'match authorization the dyad producer requires. match_id is the '
  'conversation''s id because it must be stable for the pair across epochs.';

drop trigger if exists conversations_open_match_authorization on public.conversations;
create trigger conversations_open_match_authorization
after insert on public.conversations
for each row execute function private.open_match_authorization();

-- ---------------------------------------------------------------------------
-- Blocking ends the authorization
-- ---------------------------------------------------------------------------
--
-- `0123` froze the conversation and left it visible, which is the product
-- decision about *history*. An authorization is not history: it is the standing
-- permission a dyad run checks, and leaving it active would let two people who
-- may not reach each other be compared.
create or replace function private.revoke_match_authorization_on_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update semantic_private.match_authorizations
     set authorization_state = 'revoked',
         revoked_at = now(),
         -- Matches `^[a-z][a-z0-9_]{0,63}$`, which the state/reason check
         -- demands of anything not active.
         revocation_reason_code = 'blocked'
   where authorization_state = 'active'
     and (
       (participant_a_user_id = new.blocker_id and participant_b_user_id = new.blocked_id)
       or (participant_a_user_id = new.blocked_id and participant_b_user_id = new.blocker_id)
     );
  return new;
end;
$$;

drop trigger if exists blocks_revoke_match_authorization on public.blocks;
create trigger blocks_revoke_match_authorization
after insert on public.blocks
for each row execute function private.revoke_match_authorization_on_block();

revoke all on function private.open_match_authorization() from public, anon, authenticated;
revoke all on function private.revoke_match_authorization_on_block() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Proven on rows made for the purpose and removed again
-- ---------------------------------------------------------------------------
--
-- **`public.conversations` is empty**, so nothing here could be checked against
-- real data — and a migration that installs a trigger and asserts only that it
-- exists is the failure this file has now shipped twice. So this builds a
-- conversation, watches the authorization appear, blocks, watches it revoke,
-- and rolls all of it back.
do $$
declare
  a uuid;
  b uuid;
  conversation uuid := extensions.gen_random_uuid();
  authorized uuid;
  state_after text;
begin
  select id into a from public.users order by created_at limit 1;
  select id into b from public.users where id <> a order by created_at limit 1;
  if a is null or b is null then
    raise notice 'fewer than two accounts; bridge unexercised';
    return;
  end if;

  -- The insert policy on `conversations` is RLS and this runs as the owner, so
  -- the row goes in directly; the trigger is what is under test.
  insert into public.conversations (id, user_a, user_b, user_a_name, user_b_name)
  values (conversation, a, b, 'probe', 'probe');

  authorized := semantic_private.active_match_authorization_id_v031(a, b);
  if authorized is null then
    raise exception 'a conversation did not open a match authorization';
  end if;

  insert into public.blocks (blocker_id, blocked_id) values (a, b);

  select authorization_state into state_after
    from semantic_private.match_authorizations where id = authorized;
  if state_after <> 'revoked' then
    raise exception 'blocking left the match authorization %', state_after;
  end if;
  if semantic_private.active_match_authorization_id_v031(a, b) is not null then
    raise exception 'an active authorization survived a block';
  end if;

  raise notice 'bridge verified: conversation opened %, block revoked it', authorized;

  -- Leave the database as it was found. The block would otherwise stand between
  -- two real accounts, and the authorization would outlive the conversation.
  delete from public.blocks where blocker_id = a and blocked_id = b;
  delete from semantic_private.match_authorizations where match_id = conversation;
  delete from public.conversations where id = conversation;
end
$$;

commit;
