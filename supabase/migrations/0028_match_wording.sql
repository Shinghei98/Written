-- "Marco / Matched with you!" rather than "You matched with Marco".
--
-- The notification goes to the person who *sent* the invitation, at the moment
-- the invitee accepts it and the conversation opens. It said "You matched with
-- Marco", which is written from the app's point of view rather than from the
-- reader's: what happened is that Marco answered.
--
-- **The title cannot carry it, and that is a property of the medium.**
-- `content.updating(from: intent)` replaces the title with the sender's display
-- name — that replacement is precisely what makes the banner render as a person,
-- with their face, instead of as this app. So on arrival the title reads "Marco"
-- whatever is sent, and the sentence has to go beneath it. Together they read
-- as intended:
--
--     Marco
--     Matched with you!
--
-- The payload title is still written as the full sentence, because it is the
-- fallback: if the service extension does not run — it has about thirty seconds
-- and iOS may skip it under memory pressure — the raw payload is delivered as
-- it stands, and "Marco matched with you!" reads correctly on its own where
-- "You matched with Marco" beside a body of "Matched with you!" would not.
--
-- The subtitle goes. It said "It's a match", which is the same fact a third
-- time.

create or replace function public.notify_match()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
    accepter_name text;
begin
    if new.status <> 'accepted' or old.status = 'accepted' then
        return new;
    end if;

    select coalesce(nullif(btrim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), 'Someone')
      into accepter_name
      from public.users where id = new.liked_id;

    perform private.notify(
        -- To the liker: they are the one learning something. The accepter just
        -- tapped it.
        new.liker_id,
        -- Fallback title, for the case where the extension does not run.
        accepter_name || ' matched with you!',
        'Matched with you!',
        'match',
        null,
        -- The accepter is the face, which is the opposite of the row's
        -- `liker_name` and easy to get backwards.
        new.liked_id,
        accepter_name,
        null
    );
    return new;
end;
$$;
