-- 0194 — a subscribed channel becomes vocabulary.
--
-- ## What YouTube does and does not do today
--
-- Measured 2026-08-15 across both live accounts: 1,396 active YouTube
-- observations, 8,834 mappings, **91 concepts reached** — every one of them
-- matched against vocabulary that already existed. `ontology.youtube_channels`
-- holds **298 rows, all stamped 2026-08-13 17:55:05**, the moment `0135` ran,
-- and **none has been added since** — including by a re-distillation on the 15th
-- that brought new subscriptions with it.
--
-- So YouTube *resolves* and does not *mint*. A channel about something nobody
-- has authored a concept for produces an unresolved term and nothing else, which
-- is why `Hearthstone` needed `0168` — a hand-written migration — before it
-- could exist at all. Apple Music has had the opposite property since `0177`:
-- an unseen artist becomes a concept the first time somebody plays them.
--
-- `resolve_youtube_channel` is declared in the job contract and **has no
-- handler**; only `recompute_user` and `mint_vocabulary` are registered. So the
-- gap is not a missing decision, it is a missing implementation of one already
-- taken.
--
-- ## What is minted, and the flag that says what may not be
--
-- **A channel becomes a `creator` concept and nothing finer.**
-- `allow_role_resolution` is **false**, and its own words are *"deciding what a
-- channel is — artist, reposter, label — is a judgement no code here makes"*.
-- That is respected: nothing here chooses among those, and the
-- `youtube_channel_role_resolver` stays unused.
--
-- What *is* asserted is the same thing the resolver already asserts every run:
-- the `channel_identity` lane emits its term with the type hint `creator`
-- (`resolve.py`), so a channel matching an existing creator concept is already
-- treated as one. This extends that treatment to the ones that match nothing,
-- rather than introducing a claim the system was not already making.
--
-- **Gated on `allow_channel_identity`**, which `0135` approved, and read from
-- the same query `initialize_youtube_run_policy` runs so the gate and the runs
-- cannot disagree.
--
-- ## Where the title comes from, and why not the vault
--
-- From `ontology.youtube_channels`, refreshed out of `public.distilled_records`.
-- **The vault does not hold it**: a subscription's projection is `topics`,
-- `subscriber_count` and `tags` — the title is excluded on purpose, because
-- III.E.4 requires titles deleted or refreshed within 30 days and the payload is
-- frozen. Measured on a real subscription payload while writing this.
--
-- This is the *read-derive-discard* pattern CLAUDE.md names: derive vocabulary
-- from the catalogue rather than from stored evidence. And it is what the
-- 2026-08-13 determination settled — **a channel name that has become ontology
-- vocabulary is not API Data**, so `canonical_title` and the labels minted from
-- it are unswept, while the three retention sweeps stay exactly as they are.
--
-- ## Two functions, because two identities
--
-- `semantic_worker` may read `ontology.youtube_channels` (`0137`) and may **not**
-- read `public.distilled_records` — checked rather than assumed. So the refresh
-- is `security definer` and the mint takes its rows as a parameter, because the
-- normalised form must be computed by `normalize_text` in Python: SQL cannot
-- reproduce a Unicode-category fold, and `0184` is what that costs when the
-- stored form and the computed one differ.

begin;

create or replace function semantic_private.refresh_youtube_channels()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  added integer := 0;
  from_subscriptions integer := 0;
begin
  -- `0135`'s two statements, unchanged in substance. A liked video carries the
  -- channel id in `extra` and the title in `creator`; a subscription row *is*
  -- the channel, so its `item_id` is the id and its `name` the title. Latest
  -- collection wins the identity, and `do nothing` keeps the first title rather
  -- than letting a rename fragment the concept.
  insert into ontology.youtube_channels (youtube_channel_id, canonical_title)
  select distinct on (r.extra->>'channel_id')
         r.extra->>'channel_id',
         nullif(btrim(r.creator), '')
    from public.distilled_records r
   where r.source = 'youtube'
     and r.extra ? 'channel_id'
     and r.extra->>'channel_id' ~ '^[A-Za-z0-9_-]{3,128}$'
     and nullif(btrim(r.creator), '') is not null
     and char_length(btrim(r.creator)) between 1 and 240
   order by r.extra->>'channel_id', r.collected_at desc
  on conflict (youtube_channel_id) do nothing;
  get diagnostics added = row_count;

  insert into ontology.youtube_channels (youtube_channel_id, canonical_title)
  select distinct on (r.item_id)
         r.item_id,
         nullif(btrim(r.name), '')
    from public.distilled_records r
   where r.source = 'youtube'
     and r.data_type = 'subscription'
     and r.item_id ~ '^[A-Za-z0-9_-]{3,128}$'
     and nullif(btrim(r.name), '') is not null
     and char_length(btrim(r.name)) between 1 and 240
   order by r.item_id, r.collected_at desc
  on conflict (youtube_channel_id) do nothing;
  get diagnostics from_subscriptions = row_count;

  return added + from_subscriptions;
end;
$$;

revoke all on function semantic_private.refresh_youtube_channels() from public, anon, authenticated;
grant execute on function semantic_private.refresh_youtube_channels() to semantic_worker;

create or replace function semantic_private.mint_youtube_channels(p_channels jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  allowed  boolean := false;
  to_mint  integer := 0;
  resolved integer := 0;
  refused  integer := 0;
  enqueued integer := 0;
begin
  -- The gate, read exactly as `initialize_youtube_run_policy` reads it.
  select p.allow_channel_identity into allowed
    from ontology.youtube_policy_approvals p
   where p.approval_state = 'approved'
     and p.approved_at <= now()
     and (p.expires_at is null or p.expires_at > now())
     and p.revoked_at is null
   order by p.approved_at desc, p.approval_reference
   limit 1;
  if not coalesce(allowed, false) then
    return jsonb_build_object('minted', 0, 'published', false,
                              'declined', 'channel identity is not approved');
  end if;

  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  drop table if exists channel_plan;

  create temporary table channel_plan on commit drop as
  with incoming as (
    select distinct on (c ->> 'normalized')
           c ->> 'channel_id' as channel_id,
           c ->> 'title'      as title,
           c ->> 'normalized' as normalized
      from jsonb_array_elements(coalesce(p_channels, '[]'::jsonb)) as c
     where coalesce(c ->> 'channel_id', '') <> ''
       and coalesce(c ->> 'normalized', '') <> ''
     order by c ->> 'normalized', c ->> 'channel_id'
  ), ambiguous as (
    select c ->> 'normalized' as normalized
      from jsonb_array_elements(coalesce(p_channels, '[]'::jsonb)) as c
     group by 1 having count(distinct c ->> 'channel_id') > 1
  ), any_label as (
    select distinct l.normalized_label
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
     where l.status = 'active'
  )
  select i.channel_id, i.title, i.normalized,
         'creator:yt_' || i.channel_id as concept_key
    from incoming i
   where not exists (select 1 from ambiguous a where a.normalized = i.normalized)
     -- **Already resolvable is already done.** A channel whose title matches
     -- any active label reaches that concept through `channel_identity`
     -- without help, and minting a second concept for it would split the
     -- evidence between them.
     and not exists (select 1 from any_label o where o.normalized_label = i.normalized)
     and not exists (
       select 1 from ontology.concepts existing
        where existing.concept_key = 'creator:yt_' || i.channel_id);

  select count(*) into to_mint from channel_plan;
  select count(*) - to_mint into refused
    from jsonb_array_elements(coalesce(p_channels, '[]'::jsonb));

  if to_mint = 0 then
    return jsonb_build_object('minted', 0, 'already_resolvable', refused,
                              'published', false);
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Subscribed and liked channels become vocabulary.');
  select id into new_version_id from ontology.versions where version = next_version;

  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
    from ontology.concept_revisions r where r.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l where l.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e where e.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.motif_rules (id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id, evidence_predicate_key, output_predicate_key, rule_kind, minimum_independence_groups, minimum_strength, configuration, status)
  select extensions.gen_random_uuid(), new_version_id, m.rule_key, m.evidence_target_concept_id, m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key, m.rule_kind, m.minimum_independence_groups, m.minimum_strength, m.configuration, m.status
    from ontology.motif_rules m where m.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.external_concept_links (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, x.concept_id, x.external_entity_id, x.link_type, x.confidence, x.status
    from ontology.external_concept_links x where x.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concepts (id, concept_key)
  select extensions.gen_random_uuid(), p.concept_key from channel_plan p
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, p.title, 'creator',
         'A YouTube channel this account subscribes to or liked a video from. '
         || 'The name is the channel''s own; nothing here decides what kind of '
         || 'channel it is.',
         'ordinary', 'inferable', 'active',
         jsonb_build_object('provider', 'youtube', 'external_id', p.channel_id)
    from channel_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
  on conflict do nothing;

  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, c.id, p.title, p.normalized, 'und',
         kind.label_type, 'provider', 1.0, 'active',
         jsonb_build_object('provider', 'youtube', 'external_id', p.channel_id)
    from channel_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
   cross join (values ('preferred'), ('alternate')) as kind(label_type)
  on conflict do nothing;

  -- **The parent, and it is the one thing every channel has in common.** A
  -- concept with no `broader` edge blocks as null and lands under "Other".
  -- `subject:content_creators` is where Kripparrian already sits and is the
  -- only claim available without deciding what the channel is *about* — which
  -- is what `allow_role_resolution` and III.E.4.h both forbid.
  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select distinct new_version_id, c.id, 'broader', parent.id, 1.0, 'provider',
         jsonb_build_object('source', 'mint_youtube_channels', 'provider', 'youtube'),
         'active'
    from channel_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
    join ontology.concepts parent on parent.concept_key = 'subject:content_creators'
   where c.id <> parent.id
  on conflict do nothing;

  perform ontology.publish_version(new_version_id);

  select semantic_private.enqueue_recompute_on_analysis_change(
           'mint_youtube_channels: ' || next_version
         ) into enqueued;

  return jsonb_build_object(
    'minted', to_mint, 'already_resolvable', refused, 'published', true,
    'version', next_version, 'recomputes_enqueued', enqueued
  );
end;
$$;

revoke all on function semantic_private.mint_youtube_channels(jsonb) from public, anon, authenticated;
grant execute on function semantic_private.mint_youtube_channels(jsonb) to semantic_worker;

do $$
declare
  granted boolean;
begin
  -- The two identities, asserted in both directions: the worker may call these
  -- and still may not read what the first of them reads.
  if not has_function_privilege('semantic_worker',
        'semantic_private.refresh_youtube_channels()', 'execute') then
    raise exception '0194: the worker cannot refresh the channel catalogue';
  end if;
  if not has_function_privilege('semantic_worker',
        'semantic_private.mint_youtube_channels(jsonb)', 'execute') then
    raise exception '0194: the worker cannot mint channels';
  end if;
  select has_table_privilege('semantic_worker', 'public.distilled_records', 'select')
    into granted;
  if granted then
    raise exception '0194: the worker gained a read of the legacy table it must not have';
  end if;
end;
$$;

commit;
