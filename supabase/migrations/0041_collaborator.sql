-- Who a training corpus is allowed to contain.
--
-- Training data comes from willing collaborators rather than from real users,
-- which settles the consent question: the published policy governs users, and a
-- separate agreement governs collaborators. What it does not settle is telling
-- the two apart. Collaborators sign up by phone through the ordinary flow, so
-- their rows land in `distilled_records` beside everybody else's and nothing
-- marks them.
--
-- The synthetic accounts had a handle — `seed_synthetic.py` matches the seeded
-- email domain, which is exactly what makes `--wipe` unable to touch a real
-- account. Collaborators have no such thing, so a corpus would be built from a
-- list of uuids held somewhere outside the database. **That failure is quiet**:
-- one real user's rows in a training set, and nothing afterwards able to notice.
--
-- **`private`, not a column on `public.users`, and that is a hole rather than a
-- preference.** `0001`'s policy on that table is `auth.uid() = id`, and `0009`
-- is the only migration in this schema that revokes update — so `authenticated`
-- keeps its default privilege there. A column would be settable by the very
-- account it describes: anyone could mark themselves a collaborator and put
-- their own rows in the corpus. `private.push_config` is the established
-- pattern here for a fact the app must never touch.
create schema if not exists private;

create table if not exists private.collaborators (
    user_id  uuid primary key references public.users (id) on delete cascade,
    -- Who they are and how they were asked, in whatever words are useful. The
    -- consent itself lives outside this database; this is only the pointer.
    note     text,
    added_at timestamptz not null default now()
);

-- **No policy and no grants, deliberately.** Nothing is granted on `private`,
-- so `service_role` reaches this and no client role can see it exists. There is
-- no row-level security to get right because there is no access to secure —
-- which is the whole reason for putting it here rather than beside the data it
-- describes.
--
-- `on delete cascade` so a deleted account leaves no marker behind pointing at
-- a user that is gone. Every foreign key in this schema leads back to
-- `public.users` for that reason.

comment on table private.collaborators is
    'Accounts whose distillations may be used as training data, by separate '
    'agreement with the person. Filled in by hand. Not readable by any client '
    'role: a self-settable flag would let anyone put their own rows in a corpus.';

-- The corpus query, written down here because the *source* exclusions belong
-- with it rather than in somebody's memory:
--
--     select d.*
--       from public.distilled_records d
--       join private.collaborators c on c.user_id = d.user_id
--      where d.source not in ('youtube', 'spotify');
--
-- **Those two are excluded by their own terms, and consent cannot reach them**
-- — the rights were never the collaborator's to give.
--
--   * Spotify IV.2.1.a: "using the Spotify Platform or any Spotify Content to
--     train a machine learning or AI model or otherwise ingesting Spotify
--     Content into a machine learning or AI model". IV.2.5 adds that derived
--     and aggregate data count too, "even if a user consents to such transfer
--     or use".
--   * YouTube: III.E.3.b and III.E.4.h, and the Content Categorization and
--     Tagging amendment anything derived would need first.
--
-- Apple Music, Apple Podcasts, Apple Calendar and HealthKit carry no such term.
