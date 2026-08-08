-- One rule, one place: the trigger reads the subject the device stamped.
--
-- `0038` decided composer-or-performer here, in SQL, and `Ontology` decided it
-- again in Swift for the dynamic profile's three figures. Two implementations
-- of one rule, and the day they drifted the profile would have said Bach while
-- the thread said English Baroque Soloists about the same listening — the exact
-- disagreement `ChatService.conversation(from:me:)` exists to prevent for the
-- reader's side of the sentence.
--
-- **`AppleMusicDistiller` now stamps `subject=` on every song row** — composer
-- for classical, performer otherwise, decided at the point where the source
-- data is richest and the genre list is right there. This function and
-- `Ontology.subjects` both read that field and both fall back to `creator`, so
-- neither carries the rule and they cannot disagree, even while a library is
-- half re-distilled.
--
-- Same shape as `cal_type` and `booked=1`, and self-healing the same way: a
-- re-stamped row differs from its stored version, `append_source_records`
-- treats a difference as a change, and one re-distill re-labels a library.
--
-- **Until that re-distill, classical names the performer again.** Rows written
-- before the stamp have no `subject` and fall back to `creator`, which loses
-- the 42-of-481 classical rows that carried a composer. That is a real
-- regression and it is bounded, temporary and self-correcting — and it was
-- already the outcome for the other 439, since those rows never had a composer
-- for `0038` to find.
--
-- Same signature, so `create or replace` replaces rather than overloading.

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
    -- split rather than indexed. Carrying the subject through means it can be
    -- picked by an equality join below rather than by a `like` — a genre
    -- containing `%` or `_` would otherwise match far more than itself.
    --
    -- **This reads a decision, it does not make one.** The composer-for-
    -- classical rule is `Ontology.musicSubject`, applied by
    -- `AppleMusicDistiller` when the row is written. Whatever this function
    -- knows about what a song is *about*, `Ontology.subjects` knows the same,
    -- because both read the same stamped field.
    --
    -- **The fallback matters as much as the stamp.** A row written before the
    -- stamp existed keeps its performer rather than dropping out — losing it
    -- would leave a subject null, and the guard below discards the whole theme
    -- when either side has none, so a half-re-distilled library would silently
    -- get no icebreaker at all. `nullif` rather than a plain `coalesce`,
    -- because an empty string is a present key with nothing in it and would
    -- otherwise beat the performer.
    genres as (
        select l.user_id,
               btrim(g) as genre,
               coalesce(nullif(btrim(l.extra ->> 'subject'), ''), l.creator) as subject
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
    --    **Deliberately still `creator`, not the stamped subject.** This
    --    branch only runs when the two share no genre at all, and its theme is
    --    the shared name itself rather than one name per side — "you both
    --    listen to Bach" would need the *composers* to intersect, which is a
    --    different query from the one above rather than a substitution inside
    --    it. Worth revisiting once libraries are re-distilled and the stamp is
    --    dense enough to intersect on.
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
    'that changed every time the thread opened would not be an opener. Names '
    'each side by the subject AppleMusicDistiller stamped — composer for '
    'classical, performer otherwise — so this and Ontology.subjects agree.';
