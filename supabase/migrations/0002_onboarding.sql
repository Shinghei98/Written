-- Whether the account has been through the photo step.
--
-- Onboarding was being inferred from whether a name was known, which conflates
-- two unrelated facts: Apple volunteers a name on the first sign-in, so an
-- account can have one before it has ever seen the photo page — and then never
-- be shown it. This records the step itself.
--
-- Nullable rather than a boolean default false, because the timestamp is worth
-- having: it is also the hook the eventual Storage work needs for ordering, and
-- "never asked" and "asked and declined" are different states worth telling
-- apart later.
alter table public.users
    add column if not exists photos_added_at timestamptz;

comment on column public.users.photos_added_at is
    'When the photo step was completed or declined. Null means it has not been shown.';
