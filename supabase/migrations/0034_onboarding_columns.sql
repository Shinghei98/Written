-- The four onboarding answers the launch route needs and could not ask for.
--
-- **The route is decided synchronously, and that is not negotiable** — see
-- `RootView`. It reads the Keychain and `UserDefaults`, because deciding from a
-- network round trip drew the sign-in screen for two to four seconds and then
-- replaced it. What corrects a wrong first guess is `SupabaseAuth.loadProfile`,
-- which runs inside `restoreSession` and adopts the server's answers a moment
-- later, after which `RootView` recomputes the route.
--
-- That correction only ever read two columns — `first_name` and
-- `photos_added_at` — so four of the six facts `onboardingStep` branches on had
-- nowhere on the server to be read back from:
--
--   birthday       birth_date       0003, and never read back
--   name           first_name       read
--   gender         sex              0003, and never read back
--   interest       (nothing)        a `user` record only
--   communication  (nothing)        a `user` record only
--   photos         photos_added_at  read
--   explored       (nothing)        `UserDefaults` only
--
-- The two that exist are read back by the same change that adds these; the
-- three new ones are here because a `distilled_records` row cannot answer in
-- time. `RestoreService.hydrate()` is what restores those, and it runs once
-- `AppShell` mounts — which needs `Route.home`, which is the thing being
-- decided. **The data could not unlock the route that would load the data.**
--
-- What that cost, on a phone that has the account but not the local stores — a
-- reinstall, a new device, or an App Store reviewer signing into the demo
-- account: onboarding runs a second time from the beginning, and because
-- `exploring` maps to `Route.home`, hydration lands *while the onboarding arrow
-- is still drawn* and the garden reaches full growth on the page offering to
-- grow it.
--
-- No policy is needed. `0001` gives `public.users` `for all using (auth.uid() =
-- id)`, which covers these, and `0009` — the one migration that revokes update
-- — does not touch this table.

alter table public.users
    add column if not exists has_explored  boolean not null default false,
    add column if not exists interested_in text[],
    add column if not exists flirt_level   text,
    add column if not exists response_time text;

comment on column public.users.has_explored is
    'Onboarding finished: Explore was tapped on the profile preview. Mirrors '
    'SupabaseAuth.hasExplored, which was local-only and walked every reinstall '
    'through the garden again.';

comment on column public.users.interested_in is
    'Who to be shown, from DatingPreferences.Gender — male/female/nonbinary. '
    'Not who the user is; public.users.sex is that.';

comment on column public.users.flirt_level is
    'FlirtLevel.rawValue — the flat vocabulary (Low … Extremely High), never '
    'the dashboard words. The slider position stays in the user record.';

comment on column public.users.response_time is
    'ResponseTime.rawValue — Largo, Andante, Allegro, Prestissimo.';

-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------
--
-- **`photos_added_at` is the honest proxy and the only one available.** It is
-- stamped by `markPhotoStepSeen` whether or not anybody picked a photograph, so
-- it means *reached the last page before the garden* — which is one step short
-- of explored and the closest thing on this table to it. Anyone who got that
-- far and is being asked again is exactly the person this migration is for.
--
-- Deliberately not `true` for every row. An account abandoned at the name step
-- would then skip the rest of onboarding forever, which is a worse failure than
-- the one being fixed: the first is silent and permanent, the second is a
-- sequence somebody sits through twice.
update public.users
   set has_explored = true
 where photos_added_at is not null
   and has_explored = false;
