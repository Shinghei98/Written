-- 0122 — a declined invitation stops opening somebody's profile.
--
-- **The defect, in one line of `0037`:**
--
--     if not exists (select 1 from public.likes l
--                     where l.liker_id = target and l.liked_id = me)
--
-- Any like row at all authorises the read. `likes.status` is
-- `pending | accepted | declined`, and the check consults none of it — so
-- **declining an invitation leaves the sender's school and bio readable to the
-- person who declined it, permanently.** Those two fields are precisely the ones
-- deliberately kept off `discovery_cards`, which every signed-in user may read;
-- `match_profile` is the gate that makes them narrower, and it was leaking
-- through a state nobody intended.
--
-- §10 of the integration plan names it: *"Match profile no longer remains
-- readable merely because any historical like row exists; current
-- invitation/match authorization is required."* This is a live authorisation
-- looseness in shipping code, not only a Phase 4 gate.
--
-- **Each state, and why it lands where it does.**
--
--   `pending`  — an open invitation, and the *reason the page exists*. The
--                avatar on `AdmirerRow` is how somebody decides whether to
--                accept, and they cannot decide about a person they may not
--                look at. Stays.
--   `accepted` — you matched. A conversation should also exist and the second
--                clause would cover it, but `ChatService.open` is a separate
--                step that can fail, and authorisation should not depend on a
--                write that might not have landed. Stays.
--   `declined` — you answered, and the answer was no. The row is a record, not
--                a standing permission. **Removed.**
--
-- **Only the recipient can set that status** — `0009` revokes update on `likes`
-- and grants back `status, responded_at` narrowly — so `declined` on a row
-- where `liked_id = me` means *I* declined *them*. Revoking my access to them is
-- the right direction, and it is the only direction this clause covers: a like
-- I sent (`liker_id = me`) never authorised anything here and still does not.
--
-- **The conversation clause is untouched.** `conversations` carries no ended or
-- blocked state, so its existence *is* the current authorisation. When blocking
-- ships, this is the second place it has to be consulted — the first being
-- `private.is_blocked` in `0120`.
--
-- **Low regression risk, and it is worth saying why.** The two callers are the
-- `AdmirerRow` avatar and the `ConversationView` banner. A declined like removes
-- the admirer row, so no shipping surface tries to open a declined person's
-- profile; what this closes is the direct RPC call, which is exactly the thing a
-- policy has to defend against.
--
-- **No assertion block, deliberately.** `public.likes` is empty in production,
-- so any check written here would pass by having nothing to examine — the
-- failure `0117` shipped and `0118` corrected. The test is named at the foot of
-- this file and needs two accounts.

begin;

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

    if not exists (
        select 1 from public.likes l
         where l.liker_id = target and l.liked_id = me
           -- **The whole change.** An invitation authorises while it is open or
           -- has been accepted; a declined one is history.
           and l.status in ('pending', 'accepted')
    ) and not exists (
        select 1 from public.conversations c
         where (c.user_a = me and c.user_b = target)
            or (c.user_a = target and c.user_b = me)
    ) then
        -- **Nothing, rather than an error.** A refusal that says "no such
        -- relationship" tells a caller whether an account exists, which is a
        -- question they have no business asking. Zero rows is the same answer
        -- as a match who filled in neither field — and now also the same answer
        -- as a declined invitation, which is the point.
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

comment on function public.match_profile(uuid) is
  'School and bio for a current match only. Authorised by an open (pending) or '
  'accepted invitation FROM the target, or an existing conversation. A declined '
  'like is history and authorises nothing (0122). Returns zero rows for a '
  'refusal and for a match who filled in neither field, deliberately: '
  'distinguishing them would disclose whether an account exists.';

commit;

-- THE TEST, which needs two accounts and cannot be run from here.
--
--   1. B likes A.                    A calls match_profile(B) -> row.  (pending)
--   2. A declines.                   A calls match_profile(B) -> ZERO. (the fix)
--   3. B likes A again, A accepts.   A calls match_profile(B) -> row.  (accepted)
--   4. Open the conversation.        A calls match_profile(B) -> row.  (conversation)
--
-- `tools/chat_e2e.py` already plays the second person over REST — `users`,
-- `like`, `reply`, `state` — which is what makes steps 1 and 3 reachable without
-- a second device. Read the database after each step rather than trusting the
-- screen: CLAUDE.md records that the first accept in such a run appeared to open
-- a conversation while writing nothing at all.
