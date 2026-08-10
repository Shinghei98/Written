-- Adapted from the v0.3.1 reference `sql/tests/006_surface_fact_upgrade_contract.sql`.
-- Gates application migration 0047.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 18 `private.` -> `semantic_private.`
-- and 2 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after applying 006 twice to a database seeded under 005 with
-- fixtures/005_surface_fact_upgrade_fixture.sql.

begin;

do $surface_fact_upgrade_contract$
declare
  fixture_viewer_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-viewer'
  );
  fixture_subject_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-subject'
  );
  fixture_run_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-run'
  );
  subject_assertion_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-subject-assertion'
  );
  score_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-score'
  );
  bio_fact_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-bio-fact'
  );
  subject_icebreaker_fact_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-subject-icebreaker-fact'
  );
  viewer_icebreaker_fact_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-viewer-icebreaker-fact'
  );
  dyad_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-dyad'
  );
  bio_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-bio'
  );
  authorization_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-authorization'
  );
  frame_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-frame'
  );
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'semantic_private'
      and table_name = 'validated_surface_facts'
      and column_name = 'assertion_score_version_id'
  ) or not exists (
    select 1
    from information_schema.columns
    where table_schema = 'semantic_private'
      and table_name = 'validated_surface_facts'
      and column_name = 'attested_revision'
  ) then
    raise exception '006 surface-fact binding columns are missing after upgrade';
  end if;

  -- The inferred fact had a genuinely current pre-006 score. Its null binding
  -- therefore proves the migration refused to invent historical attestation,
  -- rather than simply having no score pointer available to copy.
  if not exists (
    select 1
    from semantic_private.assertion_current_scores as current_score
    where current_score.assertion_id = subject_assertion_id
      and current_score.user_id = fixture_subject_id
      and current_score.assertion_score_version_id = score_id
      and current_score.semantic_run_id = fixture_run_id
  ) then
    raise exception '006 removed the valid historical current-score pointer';
  end if;
  if not exists (
    select 1
    from semantic_private.validated_surface_facts
    where id = bio_fact_id and user_id = fixture_subject_id
      and assertion_id = subject_assertion_id
      and state = 'retired'
      and not may_name and not may_explain
      and assertion_score_version_id is null
      and attested_revision is null
  ) then
    raise exception '006 fabricated provenance or failed to retire the legacy inferred fact';
  end if;
  if (
    select count(*)
    from semantic_private.validated_surface_facts
    where id in (
      bio_fact_id, subject_icebreaker_fact_id, viewer_icebreaker_fact_id
    )
      and state = 'retired'
      and not may_name and not may_explain
      and assertion_score_version_id is null
      and attested_revision is null
  ) <> 3 then
    raise exception '006 did not fail closed on every pre-attestation surface fact';
  end if;
  if semantic_private.validated_surface_fact_is_current(bio_fact_id)
     or semantic_private.validated_surface_fact_is_current(subject_icebreaker_fact_id)
     or semantic_private.validated_surface_fact_is_current(viewer_icebreaker_fact_id) then
    raise exception 'a pre-006 fact remained current after retirement';
  end if;

  if not exists (
    select 1
    from semantic_private.bio_variants as bio
    where bio.id = bio_id and bio.viewer_user_id = fixture_viewer_id
      and bio.subject_user_id = fixture_subject_id
      and bio.state = 'stale' and bio.finalized_at is not null
  ) or not exists (
    select 1
    from semantic_private.bio_variant_facts as link
    where link.bio_variant_id = bio_id
      and link.surface_fact_id = bio_fact_id
      and link.subject_user_id = fixture_subject_id
  ) or semantic_private.bio_variant_is_current_v031(bio_id) then
    raise exception 'legacy ready bio remained current or lost its audit links';
  end if;

  if not exists (
    select 1
    from semantic_private.icebreaker_frames
    where id = frame_id and match_authorization_id = authorization_id
      and state = 'stale' and finalized_at is not null
      and exposed_at is null and rendered_text is not null
  ) or (
    select count(*)
    from semantic_private.icebreaker_frame_facts
    where icebreaker_frame_id = frame_id
      and surface_fact_id in (
        subject_icebreaker_fact_id, viewer_icebreaker_fact_id
      )
  ) <> 2 or semantic_private.icebreaker_frame_is_current_candidate_v031(frame_id) then
    raise exception 'legacy unexposed icebreaker remained current or lost its audit links';
  end if;

  -- Keep the dyad and authorization live so fact retirement is proven to be
  -- the reason the linked outputs became stale.
  if not exists (
    select 1 from semantic_private.dyad_runs
    where id = dyad_id and status = 'succeeded'
  ) or not semantic_private.dyad_run_is_current(dyad_id)
     or not exists (
       select 1 from semantic_private.match_authorizations
       where id = authorization_id and authorization_state = 'active'
     ) or (select revision from semantic_private.user_state_versions
           where user_id = fixture_subject_id) <> 0
     or (select revision from semantic_private.user_state_versions
           where user_id = fixture_viewer_id) <> 0 then
    raise exception 'upgrade fixture was invalidated by auth/revision instead of fact retirement';
  end if;

  begin
    perform semantic_private.mark_icebreaker_exposed(frame_id);
    raise exception 'legacy stale icebreaker crossed first exposure';
  exception
    when raise_exception then
      if sqlerrm = 'legacy stale icebreaker crossed first exposure' then
        raise;
      end if;
      if sqlerrm <> 'icebreaker is not current and authorized for first exposure' then
        raise;
      end if;
  end;
end
$surface_fact_upgrade_contract$;

rollback;
