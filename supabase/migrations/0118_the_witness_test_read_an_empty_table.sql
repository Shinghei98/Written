-- 0118 — `0117` asked a table nothing writes, and its own assertion let it.
--
-- **The defect.** `concept_has_non_video_witness` read
-- `semantic_private.concept_source_scores`, which the contract defines and the
-- scorer has never populated: **0 rows**, against 14,629 in `concept_scores`
-- and 219,642 in `observation_mappings`. So the predicate answered `false` for
-- every concept in existence. Fail-closed, which is the survivable direction,
-- and still wrong — a rule that withholds everything is not a rule, and the
-- first Phase 4 surface to consult it would have returned an empty feed with
-- nothing anywhere saying why.
--
-- **How it shipped is the part worth keeping.** `0117`'s assertion was written
-- to compare the predicate against the rows it derives from, and guarded with
--
--     if exists (select 1 from semantic_private.concept_source_scores) then
--
-- — so on an empty table it took the `else` branch, raised a notice, and
-- passed. **A check that can be skipped will be skipped exactly when it is
-- needed**, because the condition that makes it skip is usually the bug. Worse,
-- `0117`'s own comment cited `0095` and `0102` as precedents for checks that
-- pass while measuring nothing, and then committed the same error four lines
-- below. Precedent in a comment is not a test.
--
-- **The corrected path**, which is one join further out and is where the fact
-- actually lives: a mapping names an observation, an observation names a
-- `source_code`, and `semantic_private.sources` gives that source its
-- `independence_group` (`0044`). No table in the middle needs populating by
-- anybody.
--
-- **`mapping_state = 'accepted'` is required, and it is not tidiness.** Of
-- 219,642 mappings, 7,164 are `candidate` and 2,824 `rejected`; `score.py`
-- filters both, and `0109` recorded what happens when they are read as evidence
-- — `work:re_zero`'s 52 mappings are every one a fuzzy near-miss, and the
-- concept was never a claim at all. A candidate is not a witness.
--
-- **Measured before and after, which is what `0117` failed to do.** Over the
-- latest succeeded run per user: 1,139 concepts scored, 56 touched by YouTube,
-- of which **26 have another witness and cross, and 30 are YouTube-only and are
-- withheld**; 1,083 never involve YouTube and are unaffected. The rule now
-- separates something.
--
-- `0117` is left on disk as applied. `supabase_migrations.schema_migrations`
-- stores each migration's statements, so editing it would put the file and the
-- ledger out of step — the `ARCHIVED-YOUTUBE` drift one layer down.

begin;

create or replace function semantic_private.concept_has_non_video_witness(
  p_semantic_run_id uuid,
  p_concept_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from semantic_private.observation_mappings om
      join semantic_private.observations o on o.id = om.observation_id
      join semantic_private.sources s on s.source_code = o.source_code
     where om.semantic_run_id = p_semantic_run_id
       and om.concept_id = p_concept_id
       -- A candidate is a fuzzy near-miss the scorer discards; reading one as a
       -- witness would let a mis-match license disclosure.
       and om.mapping_state = 'accepted'
       -- `video` is YouTube's group in `sources`. Named rather than joined to a
       -- provider so a future second video source falls under the rule
       -- automatically: the restriction is about the channel of evidence.
       and s.independence_group <> 'video'
  );
$$;

comment on function semantic_private.concept_has_non_video_witness(uuid, uuid) is
  'III.E.3.b: a concept may cross to another user only when a non-YouTube '
  'source accepts-maps to it, so the same row would be published with YouTube '
  'disconnected. YouTube still contributes strength and the second '
  'independence group. Called by Phase 4 surfaces; nothing calls it yet.';

revoke all on function semantic_private.concept_has_non_video_witness(uuid, uuid)
  from public;

-- **This assertion cannot be skipped, which is the whole point of it.**
--
-- `0117`'s version was conditional on the table it read being non-empty. This
-- one demands the predicate *discriminate*: over real data it must answer true
-- somewhere and false somewhere. A predicate that is uniformly false — the
-- exact state `0117` shipped — fails here by name, and so does one that is
-- uniformly true, which is the permissive failure and the more dangerous of the
-- two.
--
-- It is written against whatever the database holds rather than against fixed
-- ids, so it keeps meaning something on a fresh install as soon as there is
-- anything to mean. Only a database with no accepted mappings at all is
-- exempt, and that is stated out loud rather than passed silently.
do $$
declare
  total integer;
  crossable integer;
  withheld integer;
begin
  with latest as (
    select distinct on (user_id) id, user_id
      from semantic_private.semantic_runs
     where status = 'succeeded'
     order by user_id, started_at desc
  ),
  scored as (
    select distinct om.semantic_run_id, om.concept_id
      from latest l
      join semantic_private.observation_mappings om on om.semantic_run_id = l.id
     where om.mapping_state = 'accepted'
  )
  select count(*),
         count(*) filter (where semantic_private.concept_has_non_video_witness(
                                  semantic_run_id, concept_id)),
         count(*) filter (where not semantic_private.concept_has_non_video_witness(
                                  semantic_run_id, concept_id))
    into total, crossable, withheld
    from scored;

  if total = 0 then
    raise notice 'no accepted mappings in any succeeded run; predicate unexercised';
    return;
  end if;

  raise notice 'witness test: % concepts, % crossable, % withheld',
    total, crossable, withheld;

  if crossable = 0 then
    raise exception
      'predicate is uniformly false over % concepts — it is reading something '
      'nothing writes, which is exactly what 0117 did', total;
  end if;

  if withheld = 0 then
    raise exception
      'predicate is uniformly true over % concepts — it withholds nothing and '
      'therefore protects nothing', total;
  end if;
end
$$;

commit;
