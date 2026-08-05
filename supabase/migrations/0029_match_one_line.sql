-- A face and one line: "Marco matched with you!", and nothing under it.
--
-- `0028` split the sentence across two lines — the name as the title, "Matched
-- with you!" beneath — because the title is not ours to set. This gets it onto
-- one line without giving up the photograph, and the trick is worth explaining
-- because it looks like a mistake.
--
-- **The banner's title *is* the sender's display name.**
-- `content.updating(from: intent)` replaces the title with it, and that
-- replacement is precisely what draws the avatar and renders the notification
-- as coming from a person rather than from this app. There is no flag that
-- keeps a custom title and the person styling. So for this one notification the
-- display name is the whole sentence.
--
-- **The cost is real and self-correcting.** iOS learns an `INPerson` called
-- "Marco matched with you!", and donated interactions feed Siri suggestions,
-- Focus and the share sheet — so that can briefly appear as though it were
-- somebody's name. `customIdentifier` is the user's id, so the *next*
-- notification from that person overwrites it with their real name. A match is
-- followed by messages by definition; that is what a match is for.
--
-- **Only here.** Likes and messages genuinely are from a person and keep the
-- plain name, which is correct for them and is what makes grouping work.
--
-- "Say hello." goes with the second line. It was a third statement of the same
-- fact, and the point of a match notification is the match.

create or replace function public.notify_match()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
    accepter_name text;
    headline      text;
begin
    if new.status <> 'accepted' or old.status = 'accepted' then
        return new;
    end if;

    select coalesce(nullif(btrim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), 'Someone')
      into accepter_name
      from public.users where id = new.liked_id;

    headline := accepter_name || ' matched with you!';

    perform private.notify(
        -- To the liker: they are the one learning something. The accepter just
        -- tapped it.
        new.liker_id,
        -- The fallback title, for when the service extension does not run — it
        -- has about thirty seconds and iOS may skip it under memory pressure,
        -- in which case the raw payload is delivered as it stands. Identical to
        -- the display name, so the banner reads the same either way.
        headline,
        -- No body. An empty string would draw a blank second line, which is the
        -- thing being removed; `functions/push` omits the key entirely.
        '',
        'match',
        null,
        -- The accepter is the face. The opposite of the row's `liker_name`, and
        -- easy to get backwards.
        new.liked_id,
        -- The display name, and therefore the title.
        headline,
        null
    );
    return new;
end;
$$;
