-- The note sent with an invitation becomes the conversation's first message.
--
-- `0018` added `likes.message` so somebody could say something rather than only
-- like — "including a message in your invitation puts you on top of the stack".
-- Once the like was accepted that sentence had nowhere to go: the admirers row
-- disappeared with the like it belonged to, and the thread opened empty. The
-- most considered thing anybody writes in this app was shown once and thrown
-- away.
--
-- **It has to be a trigger, and that is forced rather than chosen.** The
-- conversation is created by the *accepter* (`ChatService.open`), and the
-- message must come from the *liker*. `0009` gives `messages` an insert policy
-- of `auth.uid() = sender_id`, so the only client in a position to write this
-- row is the one person forbidden from writing it. A `security definer` trigger
-- is the only place that can, which is the same argument the notification
-- triggers make.
--
-- `search_path` is pinned, as `touch_conversation` and the notify functions are:
-- a definer function resolving names through the caller's path is the classic
-- way one gets hijacked.

create or replace function public.seed_invitation_message()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    insert into public.messages (conversation_id, sender_id, body, created_at)
    select new.id, l.liker_id, l.message, l.created_at
      from public.likes l
     where l.liker_id in (new.user_a, new.user_b)
       and l.liked_id in (new.user_a, new.user_b)
       -- **Accepted only.** A declined like with a note must not surface: the
       -- pair can still end up in a conversation later, by the other person
       -- liking back and this one accepting, and a sentence somebody already
       -- said no to has no business opening that thread.
       and l.status = 'accepted'
       and l.message is not null;
    return new;
end;
$$;

-- `after insert`, so the conversation row exists for the foreign key. One
-- conversation is inserted once per pair — the unique constraint on
-- `(user_a, user_b)` guarantees it — so this needs no idempotence of its own.
create trigger conversations_seed_invitation
    after insert on public.conversations
    for each row execute function public.seed_invitation_message();

-- ---------------------------------------------------------------------------
-- And it must not notify anybody
-- ---------------------------------------------------------------------------

-- **The accepter is looking at the screen.** They tapped Accept a moment ago;
-- telling them a message has arrived is telling them what they just did. The
-- liker, meanwhile, already gets the match notification — which is the event
-- that actually happened.
--
-- The test is the timestamp, and it is exact rather than a heuristic: this
-- message is stamped with the *like's* `created_at`, which is necessarily
-- earlier than the conversation that only exists because the like was accepted.
-- A message predating its own conversation cannot be a real one. Anything typed
-- into the thread is stamped `now()` by the column default and is later by
-- construction.
create or replace function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
    conversation public.conversations;
    recipient    uuid;
    sender_name  text;
begin
    select * into conversation from public.conversations where id = new.conversation_id;
    if conversation is null then
        return new;
    end if;

    -- A seeded invitation, not a message somebody sent. See above.
    if new.created_at < conversation.created_at then
        return new;
    end if;

    if new.sender_id = conversation.user_a then
        recipient   := conversation.user_b;
        sender_name := conversation.user_a_name;
    else
        recipient   := conversation.user_a;
        sender_name := conversation.user_b_name;
    end if;

    perform private.notify(
        recipient,
        sender_name,
        new.body,
        'message',
        new.conversation_id::text
    );
    return new;
end;
$$;

-- `touch_conversation` is deliberately left alone. It fires on this insert and
-- sets `last_message` / `last_message_at` to the note and the like's timestamp,
-- which is exactly right: the chat list should show the invitation as the last
-- thing said, because it is.

-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------

-- Conversations that opened before this existed lost their invitation, and the
-- note is still sitting on the like row. Recovering it is a select away, and
-- **not** doing so would mean the feature quietly only applies to people who
-- match after today — the sort of split that is invisible until somebody asks
-- why their friend's thread opened with a sentence and theirs did not.
--
-- Safe to re-run: the `not exists` makes it idempotent, and the timestamp rule
-- above means none of these notify anybody. It does move affected threads up
-- the chat list, because `touch_conversation` fires and `last_message_at`
-- becomes the like's time — which is correct, since it is now the last thing
-- said in a thread that had nothing in it.
insert into public.messages (conversation_id, sender_id, body, created_at)
select c.id, l.liker_id, l.message, l.created_at
  from public.conversations c
  join public.likes l
    on l.liker_id in (c.user_a, c.user_b)
   and l.liked_id in (c.user_a, c.user_b)
 where l.status = 'accepted'
   and l.message is not null
   and not exists (
       select 1 from public.messages m
        where m.conversation_id = c.id
          and m.sender_id = l.liker_id
          and m.body = l.message
   );
