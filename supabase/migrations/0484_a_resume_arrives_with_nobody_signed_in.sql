-- ---------------------------------------------------------------------------
-- Job applications: the first table anyone may write to with no account
-- ---------------------------------------------------------------------------
--
-- Every insert policy so far reads `auth.uid()` — a row belongs to whoever is
-- signed in. `/en-us/careers/apply/` has no session to offer: the site makes
-- no auth call today and this does not change that, so the check here is
-- `true`, scoped to `anon` alone. That is also the whole of its new risk, and
-- the mitigation sits on the read side rather than the write side — there is
-- no select policy for `anon` or `authenticated` at all, so a submission is
-- invisible to every caller but `service_role`, which bypasses RLS and is how
-- a human reads these back (the Table Editor, or a script holding
-- `sb_secret_…`, never the published anon key).
--
-- Resumes live beside it in a private bucket with the same shape: anyone may
-- upload an object, nobody may read one back except `service_role`. The
-- object path is `<application id>/<filename>`, the id minted client-side
-- with `crypto.randomUUID()` before the upload starts, so the file and the
-- row can be matched without a round trip in between — if a browser dies
-- between the two writes the row simply never arrives, and an orphaned
-- resume with no row naming it carries nothing of this reviewer's.
--
-- No rate limit sits in front of either write, unlike Twilio's geo and hourly
-- caps on phone verification. That is a known gap, tracked in
-- docs/NEXT-STEPS.md rather than here, since whether it has been closed is a
-- status and this file holds no statuses.
-- ---------------------------------------------------------------------------

create table if not exists public.job_applications (
    id                 uuid primary key,
    department         text not null check (department in ('engineering', 'marketing')),
    role_slug          text not null check (char_length(role_slug) <= 80),
    role_title         text not null check (char_length(role_title) <= 120),
    full_name          text not null check (char_length(btrim(full_name)) between 1 and 200),
    pronoun            text check (pronoun is null or char_length(pronoun) <= 40),
    email              text not null check (char_length(btrim(email)) between 3 and 320),
    phone              text not null check (char_length(btrim(phone)) between 3 and 40),
    current_location   text not null check (char_length(btrim(current_location)) between 1 and 200),
    linkedin_url       text check (linkedin_url is null or char_length(linkedin_url) <= 500),
    github_url         text check (github_url is null or char_length(github_url) <= 500),
    resume_object_path text not null check (char_length(resume_object_path) <= 500),
    created_at         timestamptz not null default now()
);

alter table public.job_applications enable row level security;

-- Deliberately the only policy on this table. No select, update or delete
-- policy exists for any role — an applicant cannot read back their own row,
-- let alone anyone else's, and the anon key cannot be used to enumerate who
-- has applied.
create policy "anyone may submit an application" on public.job_applications
    for insert
    to anon
    with check (true);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'job-application-resumes',
    'job-application-resumes',
    -- Not public, matching `profile-photos`' reasoning: a private bucket plus
    -- a policy means a reader needs a grant, not just the object's URL.
    false,
    -- 10 MB. A resume is a document, not a photograph; nothing here re-encodes
    -- it, so this is the only size guard it gets.
    10485760,
    array[
        'application/pdf',
        'application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    ]
)
on conflict (id) do nothing;

create policy "anyone may upload a resume" on storage.objects
    for insert
    to anon
    with check (bucket_id = 'job-application-resumes');
