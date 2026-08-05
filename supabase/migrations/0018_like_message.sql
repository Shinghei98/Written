-- A note sent with an invitation.
--
-- Two ways to like somebody: the heart, which says only that, and the speech
-- bubble, which says something. The note rides on the like rather than becoming
-- a message, because there is no conversation yet — a conversation exists only
-- once the like has been accepted, and this is what is meant to persuade
-- somebody to accept it.
--
-- **This column is why `0009`'s grants had to be widened, and the widening is
-- deliberately as narrow as it can be.** That migration revoked `update` on this
-- table and granted back only `(status, responded_at)`, so a recipient answering
-- a like cannot rewrite `liker_id` and forge one. Nothing about that changes
-- here. What is added is the *liker's* own ability to attach a note to their own
-- pending like, and nothing else.
--
-- The cost of getting this wrong is known rather than imagined: a merge upsert
-- on this table demands `update` on every column at plan time, and shipped once
-- as **42501 on every like, silently**, because the heart fills optimistically
-- and the error was recorded and never read. See `LikeService.like`.

alter table public.likes
    add column if not exists message text
        -- An empty string is not a note. Without this, a confirm on an untouched
        -- field would store `''`, and every reader would then have to decide
        -- whether that means "no message" or "a message that says nothing" —
        -- which is exactly the ambiguity `null` already answers.
        check (message is null or length(btrim(message)) > 0);

-- Beside `0009`'s grant, not replacing it. `(status, responded_at)` is the
-- recipient answering; this is the sender writing. Column-level grants are
-- additive and the two never overlap.
grant update (message) on public.likes to authenticated;

-- A second update policy, permissive alongside "the recipient may answer".
-- Postgres OR's permissive policies, so this adds a case rather than widening
-- the existing one.
--
-- **`status = 'pending'` in both `using` and `with check`**, and both are
-- needed. `using` decides which rows may be touched — so an answered like is
-- already closed to this. `with check` decides what the row may become, and
-- without it a liker could edit the note of a row *while* it is pending in a way
-- that leaves it no longer pending. Belt and braces on a table where the
-- privilege model is the whole defence.
create policy "your own pending note" on public.likes
    for update
    using (auth.uid() = liker_id and status = 'pending')
    with check (auth.uid() = liker_id and status = 'pending');

comment on column public.likes.message is
    'Optional note sent with the invitation. Null for a plain heart. Writable by the liker while pending; see 0018.';
