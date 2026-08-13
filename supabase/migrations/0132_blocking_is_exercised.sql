-- 0132 — blocking, actually run.
--
-- **`0123` and `0129` installed six triggers and not one had ever fired.**
-- `public.blocks` has held zero rows since it was created: the revoke, the
-- freeze, the two refusals and the authorization revocation were all verified
-- by reading the code and by asserting privileges, which is the state `0117`
-- was in when it shipped a predicate that answered `false` for everything.
--
-- Blocking is also the one feature here where being wrong is not a bad
-- afternoon. It is the control somebody reaches for when another person is
-- frightening them.
--
-- **Ships no behaviour and leaves no state**, which is `0103`'s shape: it flips
-- the flags, proves the answer changes, and puts everything back. This builds a
-- conversation, a pending like and an accepted like between the two real
-- accounts, blocks, checks every consequence, and deletes all of it. A failure
-- rolls the transaction back, so the database is unchanged either way.
--
-- `match_profile` cannot be called here — it reads `auth.uid()`, which is null
-- in a migration, so it would return early on the wrong branch. Its condition
-- is `private.may_see_match`, which takes both users explicitly, and `0126`
-- made that the single condition behind both halves of the page. Testing it is
-- testing them.

begin;

do $$
declare
  a uuid;          -- the blocker
  b uuid;          -- the blocked
  c uuid := extensions.gen_random_uuid();   -- their conversation
  authorized uuid;
  observed text;
  refused boolean;
begin
  select id into a from public.users order by created_at limit 1;
  select id into b from public.users where id <> a order by created_at limit 1;
  if a is null or b is null then
    raise notice 'fewer than two accounts; blocking unexercised';
    return;
  end if;

  -- ---------------------------------------------------------------- setup ---
  -- **Only rows that do not already exist**, and the first draft of this file
  -- got that wrong in the most instructive way: it upserted a like `a -> b`,
  -- and `a` is the older account — so it overwrote the one real invitation this
  -- database holds, the declined `Demo -> David` that `0122` was proven
  -- against, and then deleted it on the way out. The final check caught it and
  -- the transaction rolled back, but a probe that rewrites the data it is
  -- measuring is worse than no probe.
  --
  -- No like is needed for the conversation: `0009`'s insert policy requires an
  -- accepted one, and a policy is RLS, which the owner running this migration
  -- does not go through. `0129`'s test relied on the same thing.
  insert into public.conversations (id, user_a, user_b, user_a_name, user_b_name)
  values (c, a, b, 'probe', 'probe');

  authorized := semantic_private.active_match_authorization_id_v031(a, b);
  if authorized is null then
    raise exception 'setup: the conversation did not authorize a match';
  end if;

  -- A pending invitation, which blocking must revoke. `b -> a` is the free
  -- direction: the only like here runs `a -> b`, so nothing is overwritten.
  insert into public.likes (liker_id, liked_id, status, liker_name)
  values (b, a, 'pending', 'probe');

  -- A message must be possible *before* the block, or "refused after" proves
  -- nothing about the block.
  insert into public.messages (conversation_id, sender_id, body)
  values (c, a, 'before the block');

  if not private.may_see_match(a, b) then
    raise exception 'setup: an accepted like did not authorize the profile';
  end if;

  -- ---------------------------------------------------------------- block ---
  insert into public.blocks (blocker_id, blocked_id) values (a, b);

  -- 1. Symmetric. Whichever of the two pressed it, neither may reach the other.
  if not private.is_blocked(a, b) or not private.is_blocked(b, a) then
    raise exception 'is_blocked is not symmetric';
  end if;

  -- 2. The pending invitation is revoked.
  select status into observed from public.likes
   where liker_id = b and liked_id = a;
  if observed <> 'revoked' then
    raise exception 'a pending like survived the block as %', observed;
  end if;

  -- 3. **And only a pending one.** `0123` revokes `status = 'pending'` alone,
  -- because un-accepting a like would make the surviving frozen thread
  -- unexplainable. Checked against the declined invitation this database
  -- already holds, so the assertion needs no row of its own.
  select status into observed from public.likes
   where liker_id = a and liked_id = b;
  if observed is not null and observed <> 'declined' then
    raise exception 'blocking rewrote a non-pending like to %', observed;
  end if;

  -- 4. A new invitation between them is refused.
  refused := false;
  begin
    insert into public.likes (liker_id, liked_id, status, liker_name)
    values (b, a, 'pending', 'probe2');
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception 'a blocked person could still send an invitation';
  end if;

  -- 5. **The freeze.** The thread stays readable — its select policies are
  -- untouched — and neither side may add to it.
  refused := false;
  begin
    insert into public.messages (conversation_id, sender_id, body)
    values (a, a, 'after the block');
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception 'the blocker could still send into a frozen thread';
  end if;

  refused := false;
  begin
    insert into public.messages (conversation_id, sender_id, body)
    values (c, b, 'after the block');
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception 'the blocked person could still send into a frozen thread';
  end if;

  if not exists (select 1 from public.messages where conversation_id = c) then
    raise exception 'the freeze removed the thread rather than freezing it';
  end if;

  -- 6. The profile closes, both halves, in both directions.
  if private.may_see_match(a, b) or private.may_see_match(b, a) then
    raise exception 'a blocked pair can still read each other''s match profile';
  end if;

  -- 7. The match authorization is revoked, so no dyad may be computed for them.
  select authorization_state into observed
    from semantic_private.match_authorizations where id = authorized;
  if observed <> 'revoked' then
    raise exception 'the match authorization survived the block as %', observed;
  end if;

  -- 8. Unblocking restores reachability. It does not restore the revoked
  -- invitation or the messages nobody sent — `BlockService.unblock` says so.
  delete from public.blocks where blocker_id = a and blocked_id = b;
  if private.is_blocked(a, b) then
    raise exception 'unblocking left the block standing';
  end if;

  raise notice 'blocking verified: revoke, refuse, freeze, close, authorize, lift';

  -- --------------------------------------------------------------- unwind ---
  -- Left exactly as found. Messages before conversations, and the
  -- authorization before the conversation that opened it.
  delete from public.messages where conversation_id = c;
  delete from semantic_private.match_authorizations where match_id = c;
  delete from public.conversations where id = c;
  -- Only the invitation this test created. The `a -> b` row is real and is
  -- left exactly where it was found.
  delete from public.likes where liker_id = b and liked_id = a;
end
$$;

-- **The database must be as it was.** The unwind above is part of the test: a
-- probe that left a block, a revoked invitation or a conversation between two
-- real accounts would have changed the thing it was measuring.
do $$
begin
  if (select count(*) from public.blocks) <> 0 then
    raise exception 'a block was left behind';
  end if;
  if (select count(*) from public.conversations) <> 0 then
    raise exception 'a conversation was left behind';
  end if;
  if (select count(*) from semantic_private.match_authorizations) <> 0 then
    raise exception 'a match authorization was left behind';
  end if;
  -- The one like this database legitimately holds is the declined invitation
  -- from 2026-08-12, which `0122` was proven against on a device.
  if (select count(*) from public.likes) <> 1
     or not exists (select 1 from public.likes where status = 'declined') then
    raise exception 'the likes table is not as it was found';
  end if;
end
$$;

commit;
