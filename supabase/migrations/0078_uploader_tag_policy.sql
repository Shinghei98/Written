-- Uploader tags: a recorded determination, and the gate that reads it.
--
-- **What was decided.** `snippet.tags` are written by the uploader and returned
-- by the API. Matching a whole tag against a controlled vocabulary — here, the
-- creator concepts an Apple Music library already produced — is *reading a
-- supplied label*, not inferring one. It is the same operation
-- `Ontology.domainForCreatorTag` has performed in the shipping app all along,
-- on the same reasoning: recognising `physics` is translation, matching `phys`
-- inside a title is a guess wearing the same clothes. `written_title_tag`, which
-- is the guessing kind, stays shut.
--
-- **Why it is worth the decision.** Measured on 639 real rows: `creator:le_sserafim`
-- appears in the tags of **10 liked videos across 9 different channels**. Not one
-- subscription — the same artist sought out across nine separate reposters, which
-- channel-name matching cannot see at all, since every one of those channels is a
-- reposter rather than the artist. Apple Music evidence for that artist sits in
-- independence group `music`; this sits in `video`. Two groups on one concept is
-- what `minimum_independence_groups >= 2` exists for, and no music source can
-- ever supply the second — `apple_music`, `music_library` and `spotify` all share
-- the `music` group by design.
--
-- **`approval_basis` is added first, and it is not bookkeeping.**
-- `ontology.youtube_policy_approvals` was built to record *Google's* acceptance
-- of the Content Categorization amendment. This row is not that: it is our own
-- reading of the base terms. Storing both kinds in one table with nothing
-- distinguishing them is this codebase's own "two columns that accept the same
-- words" defect — a later reader would see a row here and reasonably conclude
-- Google had approved something. The column makes the difference structural
-- rather than a naming convention somebody has to notice.

begin;

alter table ontology.youtube_policy_approvals
  add column if not exists approval_basis text not null default 'internal_determination';

alter table ontology.youtube_policy_approvals
  drop constraint if exists youtube_policy_approvals_basis_check,
  add constraint youtube_policy_approvals_basis_check check (
    approval_basis in ('google_amendment', 'internal_determination')
  );

comment on column ontology.youtube_policy_approvals.approval_basis is
  'google_amendment = Google accepted an amendment application and the reference '
  'is theirs. internal_determination = our own reading of the base terms, '
  'reversible by setting revoked_at. Never conflate the two.';

-- The determination itself. Scoped to exactly one permission: everything else
-- stays false, so this cannot widen by accident. `nonempty_scope_check` is
-- satisfied by the single true, and every surface flag being false satisfies
-- `surface_scope_check` trivially — this licenses *evidence*, not a bio, an
-- icebreaker or an explanation, and it does not license cross-source fusion.
insert into ontology.youtube_policy_approvals (
  approval_reference, approval_version, approval_state, approval_basis,
  allow_uploader_tags, approved_at
) values (
  'written:determination:uploader-tags:2026-08-11', '1.0', 'approved',
  'internal_determination', true, now()
) on conflict (approval_reference) do nothing;

-- The resolver this permission requires. `guard_youtube_run_policy` refuses a
-- policy naming a model that is not an *active* `youtube_resolver`, and
-- `youtube_run_policies_resolver_shape_check` refuses one that names none at
-- all — so the permission cannot be switched on without saying which code
-- exercises it.
--
-- **The parameters are the false-positive guards, recorded where the resolver
-- has to read them.** `creator:yg` matched in the measurement — YG Entertainment
-- is a label, not an artist, and a two-character tag matches noise in any
-- corpus. A minimum length and whole-tag-only comparison are the difference
-- between evidence and confident nonsense attached to the wrong concept.
insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:youtube-uploader-tag-resolver:v0.1.0'),
  'youtube_uploader_tag_resolver', '0.1.0', 'youtube_resolver', null,
  '{"match":"whole_tag_only","fuzzy":false,"case_insensitive":true,'
  '"min_tag_length":3,"vocabulary":"ontology.concept_labels",'
  '"concept_kinds":["creator"],"substring_matching":false}'::jsonb,
  'active'
) on conflict (id) do nothing;

-- **The initialiser consults the approval instead of hardcoding denial.**
--
-- Fail-closed is preserved exactly: with no active approval this inserts the
-- same all-false row it always did, so removing the determination above (or
-- setting `revoked_at`) returns every future run to `deny-all-v1` with no code
-- change. The guard still runs on the insert, so a policy that somehow exceeded
-- its approval is refused here rather than discovered later.
--
-- Existing runs are untouched: this fires `after insert` on `semantic_runs`, and
-- rows already written keep whatever policy they were created under. A run's
-- permissions are a fact about when it happened.
create or replace function semantic_private.initialize_youtube_run_policy()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  approval ontology.youtube_policy_approvals%rowtype;
  resolver_id uuid;
begin
  -- Most recently approved wins where several are active. Deterministic rather
  -- than arbitrary, and `approval_reference` breaks a same-instant tie so two
  -- rows stamped by one transaction cannot make this unstable.
  select * into approval
  from ontology.youtube_policy_approvals
  where approval_state = 'approved'
    and approved_at <= now()
    and (expires_at is null or expires_at > now())
    and revoked_at is null
  order by approved_at desc, approval_reference
  limit 1;

  select id into resolver_id from ontology.model_versions
   where model_role = 'youtube_resolver' and status = 'active'
     and model_key = 'youtube_uploader_tag_resolver'
   order by version desc limit 1;

  -- **Fall back to deny-all if either half is missing, and the resolver half is
  -- the dangerous one.** `youtube_run_policies_resolver_shape_check` refuses a
  -- policy that grants a resolution permission while naming no resolver — and
  -- this is a trigger on `semantic_runs`, so that refusal would abort the run
  -- insert itself. A retired or renamed model version would stop *every*
  -- semantic run for every source, with an error naming a YouTube constraint.
  -- Denying is always a legal policy; granting without a resolver never is.
  -- `approval.id`, not `found`: PL/pgSQL's `FOUND` reflects the most recent
  -- query, which is now the resolver lookup, so testing it here would report on
  -- the wrong select and grant permissions from an approval that was never read.
  if approval.id is null or resolver_id is null then
    insert into semantic_private.youtube_run_policies (
      semantic_run_id, user_id, ontology_version_id
    ) values (new.id, new.user_id, new.ontology_version_id)
    on conflict (semantic_run_id) do nothing;
    return new;
  end if;

  insert into semantic_private.youtube_run_policies (
    semantic_run_id, user_id, ontology_version_id,
    youtube_resolver_model_id, approval_id, policy_version,
    allow_channel_identity, allow_role_resolution, allow_uploader_tags,
    allow_title_tags, allow_cross_source_fusion, allow_bio,
    allow_icebreaker, allow_explanation
  ) values (
    new.id, new.user_id, new.ontology_version_id,
    resolver_id, approval.id, 'approval:' || approval.approval_reference,
    approval.allow_channel_identity, approval.allow_role_resolution,
    approval.allow_uploader_tags, approval.allow_title_tags,
    approval.allow_cross_source_fusion, approval.allow_bio,
    approval.allow_icebreaker, approval.allow_explanation
  ) on conflict (semantic_run_id) do nothing;
  return new;
end;
$$;

revoke all on function semantic_private.initialize_youtube_run_policy() from public;

commit;
