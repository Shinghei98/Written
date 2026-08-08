-- The icebreaker: what two people who just matched actually have in common.
--
-- Stored on the conversation and rendered per reader, because the sentence is
-- **asymmetric** — "You can talk about Ado, or ask them about Fujii Kaze" names
-- the reader's own thing first and the partner's second, so the version shown
-- to one of them must never be shown to the other. That rules out a `messages`
-- row twice over: `sender_id` is `not null` so a system message has no sender,
-- and one row is read by both participants.
--
-- **Ingredients here, language in Swift.** This computes set intersections; the
-- verb ("both listen to J-Pop" against "both play tennis") is chosen on the
-- device, for the same reason `Ontology.line(for:subject:)` lives there. SQL is
-- a poor place to keep prose and this schema has no business holding copy.
--
-- **Not an embedding.** The product intends to place people in an embedding
-- space and minimise distance; that stage does not exist. This is overlap
-- counting over genres, sports and creators, which produces the same shape of
-- sentence and should not be described as the same mechanism. When the ontology
-- stage lands, this scoring is what it replaces.

alter table public.conversations
    add column if not exists theme      text,
    add column if not exists theme_kind text
        check (theme_kind in ('music_genre', 'sport', 'artist')),
    add column if not exists subject_a  text,
    add column if not exists subject_b  text,
    add column if not exists pronoun_a  text,
    add column if not exists pronoun_b  text;

comment on column public.conversations.theme is
    'What the two have in common, in their own words — a genre, a sport, a '
    'creator. Null means no overlap was found, and the app then draws no card '
    'at all rather than a generic opener.';

comment on column public.conversations.subject_a is
    'The specific thing on user_a''s side. Shown to user_a as theirs and to '
    'user_b as the partner''s.';

-- **Both pronouns sit on a row both participants can read, deliberately.**
-- Gender is kept off `discovery_cards`, which every signed-in user may read;
-- this is the narrow channel instead — two people who have already matched, and
-- who are about to address each other. Written from `public.users.sex`, which
-- as of the same change means the gender somebody *chose* and no longer gets
-- overwritten by HealthKit's biological sex.
comment on column public.conversations.pronoun_a is
    'Object pronoun for user_a — him / her / them. From users.sex, which means '
    'chosen gender only. Anything unrecognised is them.';

-- ---------------------------------------------------------------------------
-- Filling them in
-- ---------------------------------------------------------------------------
--
-- `security definer` and a trigger, exactly as `0022`'s
-- `seed_invitation_message()` is: the conversation is created by the accepter,
-- and the rows being read belong to both people, so no client is in a position
-- to compute this for itself.
--
-- **Reads the base tables, never `summary_distilled_records`.** Those views are
-- `security_invoker = on`, which is load-bearing everywhere else and is exactly
-- wrong here: a definer function reading one is still filtered by the invoker's
-- RLS, so it would find the caller's rows and silently none of the partner's —
-- an icebreaker that always looked one-sided and never errored. The
-- latest-row-per-item is therefore done here with `distinct on`.
--
-- **`source <> 'youtube'` is explicit and must stay.** There are no YouTube rows
-- today — the source is archived — but an icebreaker derived from YouTube data
-- is derived data under III.E.4.h, and the filter has to be in place before the
-- source returns rather than remembered at the time.

create or replace function public.seed_icebreaker()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    chosen_theme  text;
    chosen_kind   text;
    a_subject     text;
    b_subject     text;
begin
    -- **One statement with CTEs, not a temp table.** A trigger firing per
    -- conversation is not the place to be creating and dropping relations —
    -- that is catalog churn for a query the planner can do in one pass — and
    -- `on commit drop` inside a trigger is a subtlety nobody should have to
    -- reason about later.
    --
    -- `latest` is the latest row per item for *both* people, which is exactly
    -- what `summary_distilled_records` would have given us if a definer
    -- function could read it. See the header for why it cannot.
    with latest as (
        select distinct on (d.user_id, d.source, d.data_type, d.item_id)
               d.user_id, d.creator, d.extra
          from public.distilled_records d
         where d.user_id in (new.user_a, new.user_b)
           and d.source <> 'youtube'
           and d.removed_at is null
         order by d.user_id, d.source, d.data_type, d.item_id, d.distilled_at desc
    ),
    -- `genres=Mandopop|Pop` on the device is a plain string here, so it is
    -- split rather than indexed. Carrying `creator` through means the subject
    -- can be picked by an equality join below rather than by a `like` — a genre
    -- containing `%` or `_` would otherwise match far more than itself.
    genres as (
        select l.user_id, btrim(g) as genre, l.creator
          from latest l,
               lateral unnest(string_to_array(coalesce(l.extra->>'genres', ''), '|')) as g
         where btrim(g) <> ''
    ),
    best as (
        select genre
          from genres
         group by genre
        having count(*) filter (where user_id = new.user_a) > 0
           and count(*) filter (where user_id = new.user_b) > 0
         -- Most of both libraries first; the name breaks ties so the same pair
         -- always gets the same icebreaker.
         order by count(*) desc, genre
         limit 1
    )
    select (select genre from best),
           -- Each side's own most-listened creator *inside* that genre. Their
           -- own, not the shared one: the whole point of the second half of the
           -- sentence is that it names something particular to each of them.
           (select creator from genres
             where user_id = new.user_a and creator <> ''
               and genre = (select genre from best)
             group by creator order by count(*) desc, creator limit 1),
           (select creator from genres
             where user_id = new.user_b and creator <> ''
               and genre = (select genre from best)
             group by creator order by count(*) desc, creator limit 1)
      into chosen_theme, a_subject, b_subject;

    if chosen_theme is not null then
        chosen_kind := 'music_genre';
    end if;

    -- 2. A shared sport. `health_sports` is derived, which is the only reason
    --    anything from Health is on the server at all — raw workouts never
    --    leave the device.
    if chosen_theme is null then
        select s.sport into chosen_theme
          from (
                select distinct on (user_id, sport) user_id, sport, sessions
                  from public.health_sports
                 where user_id in (new.user_a, new.user_b)
                 order by user_id, sport, distilled_at desc
               ) s
         group by s.sport
        having count(distinct s.user_id) = 2
         order by sum(s.sessions) desc, s.sport
         limit 1;

        if chosen_theme is not null then
            chosen_kind := 'sport';
            a_subject := chosen_theme;
            b_subject := chosen_theme;
        end if;
    end if;

    -- 3. A shared creator — the same artist or show on both sides. The theme is
    --    the creator itself, so both subjects collapse onto it and the card
    --    drops its second clause. See `IcebreakerCard.sentence`.
    if chosen_theme is null then
        select l.creator into chosen_theme
          from (
                select distinct on (d.user_id, d.source, d.data_type, d.item_id)
                       d.user_id, d.creator
                  from public.distilled_records d
                 where d.user_id in (new.user_a, new.user_b)
                   and d.source <> 'youtube'
                   and d.removed_at is null
                 order by d.user_id, d.source, d.data_type, d.item_id, d.distilled_at desc
               ) l
         where l.creator <> ''
         group by l.creator
        having count(distinct l.user_id) = 2
         order by count(*) desc, l.creator
         limit 1;

        if chosen_theme is not null then
            chosen_kind := 'artist';
            a_subject := chosen_theme;
            b_subject := chosen_theme;
        end if;
    end if;

    -- A genre both listen to where neither row carries an artist name leaves a
    -- theme with no subjects, and half a sentence is worse than none. The app
    -- guards this too — `ChatService.icebreaker(from:iAmA:)` is all-or-nothing
    -- — but a column that is never written wrong beats one the client has to
    -- clean up.
    if a_subject is null or b_subject is null then
        chosen_theme := null;
    end if;

    -- No overlap is an ordinary outcome, not a failure: the columns stay null
    -- and the app draws nothing.
    if chosen_theme is null then
        return new;
    end if;

    new.theme      := chosen_theme;
    new.theme_kind := chosen_kind;
    new.subject_a  := a_subject;
    new.subject_b  := b_subject;

    select case lower(coalesce(u.sex, ''))
             when 'male' then 'him'
             when 'female' then 'her'
             else 'them'
           end
      into new.pronoun_a
      from public.users u where u.id = new.user_a;

    select case lower(coalesce(u.sex, ''))
             when 'male' then 'him'
             when 'female' then 'her'
             else 'them'
           end
      into new.pronoun_b
      from public.users u where u.id = new.user_b;

    return new;
end;
$$;

-- **`before insert`, unlike `0022`'s `after`.** That one inserts a *different*
-- row and so must wait for this one to exist; this one is filling in columns on
-- the row being written, which is only possible before it lands.
drop trigger if exists conversations_seed_icebreaker on public.conversations;
create trigger conversations_seed_icebreaker
    before insert on public.conversations
    for each row execute function public.seed_icebreaker();

comment on function public.seed_icebreaker is
    'Fills the icebreaker columns at match time. Fixed thereafter: an opener '
    'that changed every time the thread opened would not be an opener.';
