-- Classical names the composer; every other genre names the performer.
--
-- `0036` picked each side's subject from `distilled_records.creator`, which is
-- right for almost all music and wrong for exactly one genre. Apple Music's
-- artist for a Bach partita is whoever played it, so the icebreaker read:
--
--     You two both listen to Classical. You can talk about English Baroque
--     Soloists, Monteverdi Choir & John Eliot Gardiner, or ask her about
--     Rachel Podger & Arte dei Suonatori!
--
-- Two ensembles nobody outside the genre could place, at 62 and 34 characters,
-- where the terms a person actually recognises are Bach and Vivaldi. This is
-- the same fact that put `composerName` into `extra` in the first place —
-- `AppleMusicDistiller` keeps it precisely because the performer is not the
-- subject for this repertoire — and the trigger was reading past it.
--
-- **Scoped to classical on purpose.** Apple Music fills a composer on pop
-- tracks too, so preferring it everywhere would tell a Taylor Swift listener to
-- ask their match about Max Martin. The songwriter is not what a pop listener
-- thinks they are into; the composer is exactly what a classical listener
-- thinks they are into. That asymmetry is the whole reason this is a special
-- case rather than a general rule.
--
-- Everything else is untouched: the genre is still chosen by how much of both
-- libraries it covers, the sport and shared-creator branches are unchanged, and
-- a theme whose subjects come back empty is still discarded.
--
-- Same signature, so `create or replace` genuinely replaces rather than
-- overloading — see `0026`/`0027` for what a *changed* signature costs.

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
    -- split rather than indexed. `subject` is resolved per row rather than at
    -- the end, because which field to read depends on the genre the row is in
    -- and one row can carry several.
    --
    -- **The classical test is `ilike '%classical%'`**, which takes Classical
    -- Crossover and Classical Era with it and is right to: they are the same
    -- repertoire. It will not take `Klassik`, `Clásica` or 古典音樂, and cannot
    -- — Apple Music localises genre names to the account's storefront. That is
    -- incomplete by construction, in the way `PublicHolidays` and
    -- `CalendarDistiller.isGenerated` are: the failure is falling back to the
    -- performer, which is what shipped before this migration, so a missed
    -- locale is no worse than yesterday.
    --
    -- **The fallback matters as much as the rule.** A classical row whose
    -- `composer` is empty keeps its performer rather than dropping out. Losing
    -- it would leave a subject null, and the guard below discards the whole
    -- theme when either side has none — so a library with patchy composer
    -- metadata would silently get no icebreaker at all, which is a worse
    -- outcome than an ensemble's name.
    genres as (
        select l.user_id,
               btrim(g) as genre,
               case
                   when btrim(g) ilike '%classical%'
                        and coalesce(btrim(l.extra ->> 'composer'), '') <> ''
                   then btrim(l.extra ->> 'composer')
                   else l.creator
               end as subject
          from latest l,
               lateral unnest(string_to_array(coalesce(l.extra ->> 'genres', ''), '|')) as g
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
           -- Each side's own most-listened subject *inside* that genre. Their
           -- own, not the shared one: the whole point of the second half of the
           -- sentence is that it names something particular to each of them.
           (select subject from genres
             where user_id = new.user_a and subject <> ''
               and genre = (select genre from best)
             group by subject order by count(*) desc, subject limit 1),
           (select subject from genres
             where user_id = new.user_b and subject <> ''
               and genre = (select genre from best)
             group by subject order by count(*) desc, subject limit 1)
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
    --
    --    **Deliberately still `creator`, not the composer.** This branch only
    --    runs when the two share no genre at all, so there is no classical
    --    genre in play to special-case; and "you both listen to Bach" as a
    --    *theme* would need the composer to be shared, which is a different
    --    query from the one above rather than a substitution inside it.
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

    -- A genre both listen to where neither row carries a subject leaves a theme
    -- with no specifics, and half a sentence is worse than none. The app guards
    -- this too — `ChatService.icebreaker(from:iAmA:)` is all-or-nothing — but a
    -- column that is never written wrong beats one the client has to clean up.
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

comment on function public.seed_icebreaker is
    'Fills the icebreaker columns at match time. Fixed thereafter: an opener '
    'that changed every time the thread opened would not be an opener. '
    'Classical names the composer, every other genre the performer.';
