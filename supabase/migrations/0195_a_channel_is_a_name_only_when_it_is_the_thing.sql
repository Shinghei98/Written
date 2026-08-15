-- 0195 — a channel is a name only when the channel is the thing.
--
-- ## What `0194` got wrong
--
-- It gave YouTube the minting it had never had — 254 channels became concepts —
-- and minted **every** channel's name, including the ones whose names mean
-- nothing. The owner's rule, stated the same day:
--
-- > celebrity/content creator is important for both the name of content creator
-- > and their content; repost and small channels are only relevant to their
-- > content
--
-- **The damage is specific and measurable.** One person's IZ*ONE fandom is now
-- split across five minted concepts while the real one sits beside them:
--
--     creator:iz_one      IZ*ONE                                  <- already existed
--     creator:yt_UC4JcC…  WIZONE PD48 + (Fearnot Daily Update)
--     creator:yt_UCJCv0…  iz*one then & now
--     creator:yt_UCsO8O…  愛你一萬年IZ*ONE臺灣站
--     creator:yt_UCTg4e…  WIZ*ONE搬運頻道
--     creator:yt_UCZxeG…  With12_IZONEChina
--
-- Five concepts holding weight that belongs on one. `LE SSERAFIM` and `Kazuha`
-- are in the vocabulary too, so this is not a shortage of concepts — it is fan
-- channels competing with the thing they are about.
--
-- ## The test, and it is the one this codebase already chose and shelved
--
-- **Subscribed, and at least 100,000 subscribers.** `subscriber_count` is on
-- every subscription observation and on no liked-video row — which is itself
-- the first half of the rule, since a channel somebody merely liked a video
-- from is content rather than identity. 224 of the 254 minted came from liked
-- videos.
--
-- `0084` stored that number and wrote **"The number may be stored; the label may
-- not be made."** `0142` named it exactly — *"The right one is the
-- `subscriber_count`… **Not built here**"* — and declined. It has been present
-- on all 446 subscription rows and read by nothing. This is that deferral taken
-- up, now that somebody has decided.
--
-- **It is a statistic, which is why it may be used at all.** III.E.4 lets the
-- subscriber count outlive thirty days precisely because it is a statistic
-- rather than a description, and nothing here infers what a channel *is*:
-- `allow_role_resolution` stays false and the `FAN_REPOST` model in
-- `written_ontology/youtube.py` stays dormant. A size is read; no label is made.
--
-- ## The repair
--
-- `0180`'s shape, which is this codebase's established answer to a concept
-- minted wrongly: the concept **keeps its id and its mappings**, its revision
-- becomes `deprecated`, its labels become `deprecated` so nothing resolves to it
-- again, and the assertions resting on it are retired `inactive`. Nothing is
-- deleted and no history is rewritten — a term somebody saw yesterday remains a
-- thing that was shown.
--
-- ## What this does not do
--
-- It does not yet route a repost channel's weight to what it reposts. That is
-- the other half of the rule and needs vocabulary the tags can reach, which
-- needs its own written determination — the 2026-08-13 settlement covered
-- channel *names*, not video tags. Stage 1 removes the noise; the signal is
-- Stage 2.

begin;

create or replace function semantic_private.mint_youtube_channels(p_channels jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- **Named once.** A threshold repeated in a comment and a predicate is two
  -- numbers waiting to disagree.
  min_subscribers constant bigint := 100000;
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  allowed  boolean := false;
  to_mint  integer := 0;
  refused  integer := 0;
  enqueued integer := 0;
begin
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
           c ->> 'normalized' as normalized,
           coalesce((c ->> 'subscribed')::boolean, false) as subscribed,
           nullif(c ->> 'subscribers', '')::bigint as subscribers
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
  select i.channel_id, i.title, i.normalized, i.subscribers,
         'creator:yt_' || i.channel_id as concept_key
    from incoming i
   where i.subscribed
     and coalesce(i.subscribers, 0) >= min_subscribers
     and not exists (select 1 from ambiguous a where a.normalized = i.normalized)
     and not exists (select 1 from any_label o where o.normalized_label = i.normalized)
     and not exists (
       select 1 from ontology.concepts existing
        where existing.concept_key = 'creator:yt_' || i.channel_id);

  select count(*) into to_mint from channel_plan;
  select count(*) - to_mint into refused
    from jsonb_array_elements(coalesce(p_channels, '[]'::jsonb));

  if to_mint = 0 then
    return jsonb_build_object('minted', 0, 'not_notable_or_resolvable', refused,
                              'published', false);
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Channels that are themselves the thing become vocabulary.');
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
         'A YouTube channel this account subscribes to, large enough that the '
         || 'channel is itself the thing rather than a carrier of somebody '
         || 'else''s. The name is the channel''s own; nothing here decides what '
         || 'kind of channel it is.',
         'ordinary', 'inferable', 'active',
         -- **The count is recorded, so a later reader can see why it
         -- qualified** rather than having to re-derive a threshold from a
         -- comment.
         jsonb_build_object('provider', 'youtube', 'external_id', p.channel_id,
                            'subscriber_count', p.subscribers)
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
    'minted', to_mint, 'not_notable_or_resolvable', refused, 'published', true,
    'version', next_version, 'recomputes_enqueued', enqueued
  );
end;
$$;

revoke all on function semantic_private.mint_youtube_channels(jsonb) from public, anon, authenticated;
grant execute on function semantic_private.mint_youtube_channels(jsonb) to semantic_worker;

-- ---------------------------------------------------------------------------
-- The repair: every channel `0194` minted that the rule would now refuse.
-- ---------------------------------------------------------------------------
do $$
declare
  min_subscribers constant bigint := 100000;
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  failing   integer;
  keeping   integer;
  retired   integer;
  remaining integer;
  enqueued  integer;
  iz_one_alive boolean;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- Who fails, decided once and held, because the same set is needed three
  -- times and re-deriving it three ways is how two of them disagree.
  drop table if exists failing_channel;
  create temporary table failing_channel on commit drop as
  select c.id as concept_id, c.concept_key,
         replace(c.concept_key, 'creator:yt_', '') as channel_id
    from ontology.concepts c
   where c.concept_key like 'creator:yt_%';

  delete from failing_channel f
   where exists (
     select 1
       from semantic_private.observations o
      where o.source_code = 'youtube'
        and o.data_type = 'subscription'
        and o.lifecycle_state = 'active'
        and o.normalized_payload ->> 'channel_id' = f.channel_id
        and (o.normalized_payload ->> 'subscriber_count')::bigint >= min_subscribers
   );

  select count(*) into failing from failing_channel;
  select count(*) - failing into keeping
    from ontology.concepts where concept_key like 'creator:yt_%';

  if failing = 0 then
    raise exception '0195: nothing fails the new rule, which is not the measured state';
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Channel names that are not the thing are withdrawn.');
  select id into new_version_id from ontology.versions where version = next_version;

  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy,
         case when exists (select 1 from failing_channel f where f.concept_id = r.concept_id)
              then 'deprecated' else r.status end,
         r.metadata
    from ontology.concept_revisions r where r.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence,
         case when exists (select 1 from failing_channel f where f.concept_id = l.concept_id)
              then 'deprecated' else l.status end,
         l.external_ref
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

  -- The claims resting on them. `inferred` only: nothing here touches what
  -- somebody typed, which is the same line `forget_distillation` draws.
  update semantic_private.user_assertions a
     set machine_state = 'inactive', updated_at = now()
   where a.assertion_origin = 'inferred'
     and a.machine_state <> 'inactive'
     and exists (select 1 from failing_channel f where f.concept_id = a.concept_id);
  get diagnostics retired = row_count;

  -- What must be true before this is published.
  select count(*) into remaining
    from ontology.concept_labels l
    join failing_channel f on f.concept_id = l.concept_id
   where l.ontology_version_id = new_version_id and l.status = 'active';
  if remaining <> 0 then
    raise exception '0195: % label(s) of a withdrawn channel are still active', remaining;
  end if;

  -- **The thing the fan channels were competing with must be untouched.**
  select exists (
    select 1
      from ontology.concepts c
      join ontology.concept_revisions r
        on r.concept_id = c.id and r.ontology_version_id = new_version_id
     where c.concept_key = 'creator:iz_one' and r.status = 'active'
  ) into iz_one_alive;
  if not iz_one_alive then
    raise exception '0195: creator:iz_one was withdrawn, which is the opposite of the point';
  end if;

  perform ontology.publish_version(new_version_id);

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': channel names that are not the thing'
         ) into enqueued;

  raise notice '0195: % published, % channel(s) withdrawn, % kept, % assertion(s) retired, % recompute job(s)',
    next_version, failing, keeping, retired, enqueued;
end;
$$;

commit;
