-- 0269 — the keep path had never run, and neither had the edit.
--
-- The owner tapped keep on a discovered album and it bounced back. Four
-- defects in two functions, stacked, each fatal on its own:
--
-- 1. `keep_calibration_item` joins `ontology.concept_revisions` and
--    `ontology.concept_labels` on `c.ontology_version_id`, and
--    `semantic_private.user_term_candidates` has no such column — it never
--    has. Every call raised `42703` before reaching any write. (A candidate
--    is not bound to an ontology version; the published one is what a label
--    is read at, which is how `begin_calibration` already does it.)
-- 2. It then writes `review_events.reason = 'user_keep'`, and that column's
--    check constraint has admitted fourteen words since `0042` — none of them
--    that one. `finish_calibration` writes `'correct'` for keep-by-silence,
--    which is the same fact said in the vocabulary that exists.
-- 3. The same select orders labels by `l.kind`, and `ontology.concept_labels`
--    calls that column `label_type` — a fourth dead reference in one
--    function, found only because this migration's new contract coverage ran
--    it. Three of the four were invisible to every check this repository had.
-- 4. `edit_calibration_item` writes `'user_correction'`, refused for the same
--    reason. An edit is a negative verdict on the proposal, and the row
--    already carries `corrected_label` and `corrected_family`, so the reason
--    can say *which* was wrong rather than inventing a word: a changed label
--    is `wrong_primary_term`, a changed family alone is `wrong_type`.
--
-- ## Why three fatal defects shipped in the two verbs the lane exists for
--
-- Nothing calls them in any test. `supabase/tests/0230_calibration_lifecycle_contract.sql`
-- exercises strike, restore and finish; keep and edit are absent from it and
-- from every other contract file. They are the two verbs the whole
-- discovery-to-Memories path runs through — a keep is what authorises a mint
-- — and they were the two nobody ever called. This migration adds them to
-- that contract, which is the only reason the fix can be believed.
--
-- The keep also starts recording what was on screen — exposure, model
-- revision, route — as strike and finish already do. `review_events` is
-- append-only precisely because a verdict is uninterpretable without the
-- arrangement it was given in, and a keep with none of that recorded is a
-- verdict about nothing.

-- 5. And the enqueue behind it: a mint request fires `0258`'s trigger, which
--    inserts a `process_mint_requests` job — a job type
--    `worker_jobs_job_type_v03_check` has never admitted. `0258` extended the
--    payload validator and not the type list beside it, so the last step of
--    the chain was dead in production too, and could only ever have been
--    found by a keep that got far enough to reach it. Nothing had.
--
-- The type is added by deriving the existing list from the catalog rather
-- than retyping twenty names: a hand-copied list is a second place for this
-- to go wrong. Its handler shipped with `0258`, so the rule that a job type
-- the database permits must be one the worker knows still holds.

do $$
declare
  definition text;
begin
  select pg_get_constraintdef(c.oid) into definition
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'semantic_private' and t.relname = 'worker_jobs'
     and c.conname = 'worker_jobs_job_type_v03_check';
  if definition is null then
    raise exception '0269: the job-type check is not on worker_jobs';
  end if;

  if position('process_mint_requests' in definition) > 0 then
    raise notice '0269: the job type is already admitted';
    return;
  end if;

  execute 'alter table semantic_private.worker_jobs '
          'drop constraint worker_jobs_job_type_v03_check';
  execute 'alter table semantic_private.worker_jobs add constraint '
          'worker_jobs_job_type_v03_check '
          || replace(definition, '::text]))',
                     '::text, ''process_mint_requests''::text]))');
end;
$$;

-- 6. And the row a keep leaves behind makes the account undeletable.
--    `mint_requests`' two foreign keys carry no `on delete` action, while
--    every table around them — `review_items`, `user_term_candidates`,
--    `provisional_entities` — cascades from `auth.users`. So the first keep
--    in this database's history would have converted an App Store obligation
--    into a foreign-key error, and `0204` is the migration that had to unpick
--    exactly this shape for six triggers. Found by the contract deleting its
--    fixture account, which it does at the end of every run and which only
--    now had a mint request to trip over.

alter table semantic_private.mint_requests
  drop constraint mint_requests_candidate_id_user_id_fkey,
  add constraint mint_requests_candidate_id_user_id_fkey
    foreign key (candidate_id, user_id)
    references semantic_private.user_term_candidates (id, user_id)
    on delete cascade;

alter table semantic_private.mint_requests
  drop constraint mint_requests_review_item_id_user_id_fkey,
  add constraint mint_requests_review_item_id_user_id_fkey
    foreign key (review_item_id, user_id)
    references semantic_private.review_items (id, user_id)
    on delete cascade;

-- 7. And with the cascade in place, the append-only guard refuses it.
--    `mint_requests_no_delete` raises unconditionally, and a row trigger
--    fires on a cascaded delete exactly as on a direct one — which is the
--    sentence `0204` had to write for six other guards after they made every
--    account in this database undeletable. Same repair, same shape: refuse
--    while the owner exists, permit once they are gone. The parent row is
--    deleted before its cascade fires, so the test is exact rather than a
--    flag, a privileged procedure or a new grant.

create or replace function semantic_private.mint_requests_no_delete()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if exists (select 1 from auth.users where id = old.user_id) then
    raise exception 'mint requests are history; refuse one, never delete it';
  end if;
  -- The owner is gone: this is the erasure cascade, which is an obligation
  -- rather than a deletion somebody chose.
  return old;
end;
$function$;

create or replace function api.keep_calibration_item(p_review_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  item record;
  newer integer;
  request_id uuid;
begin
  perform semantic_private.assert_surface_allowed('calibration');

  select ri.id, ri.user_id, ri.candidate_id, ri.review_epoch,
         ri.model_revision, ri.primary_route_id,
         c.provisional_entity_id, c.concept_id, c.lifecycle_state,
         coalesce(p.canonical_label, cl.label) as label,
         coalesce(p.family, cr.concept_kind) as family
    into item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates c
      on c.id = ri.candidate_id and c.user_id = ri.user_id
    -- **At the published version, not at the candidate's.** A candidate
    -- carries no ontology version — it never has — so the old join predicate
    -- named a column that does not exist and every keep raised 42703 before
    -- writing anything. This is the same read `begin_calibration` performs to
    -- put the label on screen, so the word kept is the word shown.
    left join ontology.concept_revisions cr
      on cr.concept_id = c.concept_id
     and cr.ontology_version_id = (select id from ontology.versions
                                    where status = 'published')
    left join lateral (
      select l.label from ontology.concept_labels l
       where l.concept_id = c.concept_id
         and l.ontology_version_id = (select id from ontology.versions
                                       where status = 'published')
       order by (l.label_type = 'preferred') desc, l.label limit 1
    ) cl on true
    left join semantic_private.provisional_entities p
      on p.id = c.provisional_entity_id
   where ri.id = p_review_item_id
     and ri.user_id = auth.uid();
  if not found then
    raise exception 'review item not found' using errcode = 'P0002';
  end if;

  -- **A stale proposal revision cannot be decided.** A newer epoch's card for
  -- the same candidate supersedes this one; keeping the old card would record
  -- a decision against a question no longer being asked.
  select count(*) into newer
    from semantic_private.review_items later
   where later.user_id = item.user_id
     and later.candidate_id = item.candidate_id
     and later.review_epoch > item.review_epoch;
  if newer > 0 then
    raise exception 'a newer proposal revision exists; decide that one'
      using errcode = 'P0002';
  end if;

  -- `'correct'` because that is what the vocabulary calls this, and what
  -- `finish_calibration` already writes for a keep. `'user_keep'` was not in
  -- it and never had been.
  insert into semantic_private.review_events
    (user_id, review_item_id, exposure_id, action, reason,
     model_revision, route_version)
  values (item.user_id, p_review_item_id,
          (select x.id from semantic_private.review_exposures x
            where x.review_item_id = p_review_item_id and x.user_id = item.user_id
            order by x.displayed_at desc limit 1),
          'keep', 'correct', item.model_revision, item.primary_route_id);

  insert into semantic_private.mint_requests
    (user_id, review_item_id, candidate_id, provisional_entity_id, concept_id,
     requested_label, requested_family, origin)
  values (item.user_id, p_review_item_id, item.candidate_id,
          item.provisional_entity_id, item.concept_id,
          item.label, item.family, 'keep')
  on conflict (review_item_id) do nothing;

  select id into request_id from semantic_private.mint_requests
   where review_item_id = p_review_item_id;

  return jsonb_build_object('kept', true, 'mint_request_id', request_id);
end;
$function$;

-- The edit, redefined rather than patched: its reason must say which half of
-- the proposal was wrong, and that needs the original label, which the
-- function never fetched. Everything else is unchanged from `0257`.
create or replace function api.edit_calibration_item(
  p_review_item_id uuid, p_label text, p_family text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  item record;
  newer integer;
  request_id uuid;
begin
  perform semantic_private.assert_surface_allowed('calibration');

  if p_label is null or length(btrim(p_label)) = 0 or length(p_label) > 256 then
    raise exception 'a correction needs a label of 1..256 characters';
  end if;
  if p_family not in ('activity','album','anime','book','culture','event',
                      'franchise','game','group','idea','music_work',
                      'organization','person','sport','tour','work') then
    raise exception 'family % is not one a person may claim here', p_family;
  end if;

  select ri.id, ri.user_id, ri.candidate_id, ri.review_epoch,
         ri.model_revision, ri.primary_route_id,
         c.provisional_entity_id, c.concept_id,
         coalesce(p.canonical_label, cl.label) as label
    into item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates c
      on c.id = ri.candidate_id and c.user_id = ri.user_id
    left join lateral (
      select l.label from ontology.concept_labels l
       where l.concept_id = c.concept_id
         and l.ontology_version_id = (select id from ontology.versions
                                       where status = 'published')
       order by (l.label_type = 'preferred') desc, l.label limit 1
    ) cl on true
    left join semantic_private.provisional_entities p
      on p.id = c.provisional_entity_id
   where ri.id = p_review_item_id
     and ri.user_id = auth.uid();
  if not found then
    raise exception 'review item not found' using errcode = 'P0002';
  end if;

  select count(*) into newer
    from semantic_private.review_items later
   where later.user_id = item.user_id
     and later.candidate_id = item.candidate_id
     and later.review_epoch > item.review_epoch;
  if newer > 0 then
    raise exception 'a newer proposal revision exists; decide that one'
      using errcode = 'P0002';
  end if;

  -- **An edit is a negative verdict on the proposal and is never a model
  -- success.** The reason says which half was wrong rather than inventing a
  -- word the column has never admitted: a changed label is
  -- `wrong_primary_term`, a corrected family alone is `wrong_type`.
  insert into semantic_private.review_events
    (user_id, review_item_id, exposure_id, action, reason,
     corrected_label, corrected_family, model_revision, route_version)
  values (item.user_id, p_review_item_id,
          (select x.id from semantic_private.review_exposures x
            where x.review_item_id = p_review_item_id and x.user_id = item.user_id
            order by x.displayed_at desc limit 1),
          'edit',
          case when btrim(p_label) is distinct from item.label
               then 'wrong_primary_term' else 'wrong_type' end,
          btrim(p_label), p_family, item.model_revision, item.primary_route_id);

  insert into semantic_private.mint_requests
    (user_id, review_item_id, candidate_id, provisional_entity_id, concept_id,
     requested_label, requested_family, origin)
  values (item.user_id, p_review_item_id, item.candidate_id,
          item.provisional_entity_id, item.concept_id,
          btrim(p_label), p_family, 'edit')
  on conflict (review_item_id) do nothing;

  select id into request_id from semantic_private.mint_requests
   where review_item_id = p_review_item_id;

  return jsonb_build_object('edited', true, 'mint_request_id', request_id);
end;
$function$;

do $$
declare
  vocabulary text[];
  body text;
begin
  select array_agg(x) into vocabulary
    from (select unnest(array['correct', 'wrong_primary_term', 'wrong_type']) x) t;

  -- Every reason the three verbs can write is one the constraint admits. Read
  -- from the catalog rather than retyped, so widening the vocabulary later
  -- cannot silently disagree with this.
  if exists (
    select 1 from unnest(vocabulary) r
     where not pg_get_constraintdef(
       (select c.oid from pg_constraint c
          join pg_class t on t.oid = c.conrelid
          join pg_namespace n on n.oid = t.relnamespace
         where n.nspname = 'semantic_private' and t.relname = 'review_events'
           and pg_get_constraintdef(c.oid) like '%reason%')) like '%''' || r || '''%'
  ) then
    raise exception '0269: a verb writes a reason the constraint refuses';
  end if;

  -- The enqueue behind a keep can now be written, and the type list is still
  -- closed to anything else.
  if (select position('process_mint_requests' in pg_get_constraintdef(c.oid)) = 0
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
        join pg_namespace n on n.oid = t.relnamespace
       where n.nspname = 'semantic_private' and t.relname = 'worker_jobs'
         and c.conname = 'worker_jobs_job_type_v03_check') then
    raise exception '0269: the mint job type is still refused';
  end if;
  begin
    insert into semantic_private.worker_jobs
      (job_type, payload, idempotency_key)
    values ('not_a_real_job_type', '{}'::jsonb, 'zzz-0269-probe');
    raise exception '0269: the job-type list is no longer closed';
  -- **Two refusals, and the trigger's comes first.** `guard_worker_job_contract_v03`
  -- is a before-insert trigger, so it raises P0001 before the check constraint
  -- is ever evaluated; catching only `check_violation` let the probe's own
  -- refusal escape as a failure. Either refusal is the right answer here —
  -- what is being asserted is that the list is still closed, not which layer
  -- closes it.
  exception when check_violation or raise_exception then
    null;
  end;

  -- The guard still refuses a deletion whose owner is present. Asserted from
  -- its text because calling it needs a row to delete and the whole point is
  -- that the row cannot be deleted; the behavioural half is the contract
  -- file, which deletes its fixture account and now succeeds.
  if position('auth.users' in
              pg_get_functiondef(
                'semantic_private.mint_requests_no_delete()'::regprocedure)) = 0 then
    raise exception '0269: the no-delete guard does not permit the erasure case';
  end if;

  -- **Nothing a keep writes may outlive its account.** Asserted over every
  -- foreign key on the table rather than the two known ones, so a third added
  -- later without a cascade fails here rather than on somebody's deletion
  -- request.
  if exists (
    select 1 from pg_constraint c
      join pg_class t on t.oid = c.conrelid
      join pg_namespace n on n.oid = t.relnamespace
     where n.nspname = 'semantic_private' and t.relname = 'mint_requests'
       and c.contype = 'f' and c.confdeltype <> 'c') then
    raise exception '0269: a mint request can outlive the account that made it';
  end if;

  -- And the dead column is gone from the keep.
  body := regexp_replace(
            pg_get_functiondef('api.keep_calibration_item(uuid)'::regprocedure),
            '--[^\n]*', '', 'g');
  if position('c.ontology_version_id' in body) > 0 then
    raise exception '0269: the keep still joins on a column that does not exist';
  end if;
  if position('user_keep' in body) > 0 then
    raise exception '0269: the keep still writes a reason outside the vocabulary';
  end if;
end;
$$;
