-- 0438 — a field shows its name, not its channels.
--
-- **The owner's fields ruling (2026-08-27): the Science block showed
-- PanSci and Professor Dave Explains; it should show the generalized
-- terms — computer science, science, statistics, psychology,
-- literature — from the curated subject vocabulary.** Three rules:
--
--   * **The field marker is structural**: a subject whose hub is
--     `ideas_learning` is a field (~230 curated entries); music
--     labels, travel and content creators live under other hubs and
--     are untouched. No name list.
--   * **The channel-to-field affiliation is a read, not an
--     inference**: the uploader's own tags ("Machine learning|Data
--     science|linear algebra"), matched WHOLE and lowercased against
--     the curated vocabulary — exactly the `uploader_tag` treatment
--     III.E.4 permits — become `broader` edges with provider
--     provenance. λ propagation then carries the channels' weight
--     into the fields on the next run, the same route that already
--     wrote subject:science. Ambiguous channel names are refused.
--   * **The display inverts like music did**: the generalized subject
--     is the row, the specific channels leave the field blocks, and a
--     field passes the cutoff on its channels' behalf — it stands in
--     for hidden rows, not for its own propagated fraction.

begin;

-- Edges join the ontology through its own discipline: a draft patch
-- version, copy-forward, the mint, publish (0391's shape) — a
-- published version is immutable and the guard said so.
do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  n integer;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          '0438: channel-to-field edges from uploader tags');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  with chan as (
    select distinct lower(d.name) as lname, d.extra ->> 'keywords' as kw
      from public.summary_distilled_records d
     where d.source = 'youtube' and d.data_type = 'subscription'
       and coalesce(d.extra ->> 'keywords', '') <> ''
  ),
  resolved as (
    select c.lname, c.kw, min(l.concept_id::text)::uuid as concept_id
      from chan c
      join ontology.concept_labels l
        on l.normalized_label = c.lname and l.status = 'active'
       and l.ontology_version_id = new_version_id
      join ontology.concept_revisions r
        on r.concept_id = l.concept_id and r.status = 'active'
       and r.concept_kind = 'creator'
       and r.ontology_version_id = new_version_id
     group by 1, 2
    having count(distinct l.concept_id) = 1
  ),
  tags as (
    select r.concept_id, lower(replace(btrim(t.tag), '_', ' ')) as tag
      from resolved r,
           unnest(string_to_array(r.kw, '|')) as t(tag)
  ),
  fields as (
    select distinct tg.concept_id as channel_id, fc.id as field_id
      from tags tg
      join ontology.concept_revisions fr
        on lower(fr.preferred_label) = tg.tag and fr.status = 'active'
       and fr.concept_kind = 'topic'
       and fr.ontology_version_id = new_version_id
      join ontology.concepts fc
        on fc.id = fr.concept_id and fc.concept_key like 'subject:%'
     where semantic_private.concept_hub(fc.id, new_version_id)
             = 'hub:ideas_learning'
       and tg.concept_id <> fc.id
  )
  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key,
     object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, f.channel_id, 'broader', f.field_id, 0.7, 'provider',
         jsonb_build_object('source', 'uploader_tags',
                            'rule', '0438 whole-tag match'),
         'active'
    from fields f
   where not exists (
     select 1 from ontology.concept_edges e
      where e.ontology_version_id = new_version_id
        and e.subject_concept_id = f.channel_id
        and e.predicate_key = 'broader'
        and e.object_concept_id = f.field_id
        and e.provenance_type = 'provider');
  get diagnostics n = row_count;
  raise notice '0438: % channel-to-field edge(s) minted', n;

  perform ontology.publish_version(new_version_id);
  raise notice '0438: % published', next_version;
end;
$$;

CREATE OR REPLACE FUNCTION api.list_assertions()
 RETURNS TABLE(assertion_id uuid, predicate_key text, label text, origin text, display_state text, strength double precision, confidence double precision, breadth integer, stability double precision, surfacing_score double precision, display_payload jsonb, assertion_score_version_id uuid, ontology_version_id uuid, block_key text, block_label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select
    assertion.id,
    assertion.predicate_key,
    -- 0364: the designated syntax — official name (original language
    -- name) — composed from the dictionary, which is the one store that
    -- knows both halves of a foreign term's identity.
    coalesce(coalesce(song.artist, song3.artist, song2.artist) || ' - ', '') ||
    case
      -- 0367: natively English — the dictionary's original IS the english
      -- (Loki/Loki) — reads as the english alone, whatever script the
      -- concept's own label happens to be in. 洛基 is a surface, not a name.
      when native.english_label is not null
           and native.english_label !~ '[^\x00-\x7F]'
           and native.original_label = native.english_label
      then native.english_label
      -- A foreign original beside a foreign-scripted preferred label:
      -- english leads, the original follows — Sword Art Online
      -- (ソードアート・オンライン).
      when coalesce(revision.preferred_label, user_term.label) ~ '[^\x00-\x7F]'
           and native.english_label is not null
           and native.english_label !~ '[^\x00-\x7F]'
           and native.original_label ~ '[^\x00-\x7F]'
           and native.english_label <> coalesce(revision.preferred_label, user_term.label)
      then native.english_label || ' ('
             || coalesce(revision.preferred_label, user_term.label) || ')'
      -- 0365's case: an English-named concept with a genuinely foreign
      -- original appends it — Jay Chou (周杰倫); a same-script echo never
      -- composes.
      when native.original_label is not null
           and native.original_label ~ '[^\x00-\x7F]'
           and native.original_label <> coalesce(revision.preferred_label, user_term.label)
      then coalesce(revision.preferred_label, user_term.label)
             || ' (' || native.original_label || ')'
      else coalesce(revision.preferred_label, user_term.label)
    end,
    assertion.assertion_origin,
    coalesce(preference.display_state, 'default'),
    score.strength,
    score.confidence,
    score.breadth,
    score.stability,
    score.surfacing_score,
    score.display_payload,
    score.id,
    coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'), assertion.created_ontology_version_id),
    block.concept_key,
    block_revision.preferred_label
  from semantic_private.user_assertions as assertion
  left join semantic_private.assertion_preferences as preference
    on preference.assertion_id = assertion.id
   and preference.user_id = assertion.user_id
  left join semantic_private.user_terms as user_term
    on user_term.id = assertion.user_term_id
   and user_term.user_id = assertion.user_id
  left join semantic_private.assertion_current_scores as current_score
    on current_score.assertion_id = assertion.id
   and current_score.user_id = assertion.user_id
  left join semantic_private.user_state_versions as user_state
    on user_state.user_id = assertion.user_id
  left join semantic_private.semantic_runs as score_run
    on score_run.id = current_score.semantic_run_id
   and score_run.user_id = assertion.user_id
   and score_run.status = 'succeeded'
   and score_run.input_revision = coalesce(user_state.revision, 0)
  left join semantic_private.assertion_score_versions as score
    on score.id = current_score.assertion_score_version_id
   and score.user_id = current_score.user_id
   and score.assertion_id = current_score.assertion_id
   and score.semantic_run_id = score_run.id
  left join ontology.concept_revisions as revision
    on revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
   and revision.concept_id = assertion.concept_id
   -- 0403: active only. A deprecated revision (a fold's loser, a retired
   -- fragment) must stop supplying the kind that passes the allowlist —
   -- Episode 25 stayed on the page because this join read its deprecated
   -- revision as happily as an active one.
   and revision.status = 'active'
  -- **The concept's own key, which the filter below needs and nothing here had.**
  -- A primary-key lookup, and `left` rather than `inner` because a user's own
  -- term has no concept at all and an inner join would delete every one of them.
  left join ontology.concepts as concept
    on concept.id = assertion.concept_id
  -- The block, and its label at the same version the term is read at, so a
  -- heading can never come from a different ontology than the row under it.
  left join lateral (
    select c.id, c.concept_key
      from ontology.concepts c
     where c.concept_key = coalesce(
             semantic_private.concept_block(
               assertion.concept_id,
               coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'),
                        assertion.created_ontology_version_id)),
             -- 0373: a trip with no edges files under the travel heading
             -- rather than "Other" — the card the parallel listing needs.
             case when concept.concept_key like 'travel:%'
                  then 'subject:travel' end)
  ) as block on true
  left join ontology.concept_revisions as block_revision
    on block_revision.concept_id = block.id
   and block_revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
   and block_revision.status = 'active'
  -- 0360: the topical hub this row buckets under, for the cutoff. Null for
  -- a user's own term (no concept) and for a concept outside every hub.
  left join lateral (
    select semantic_private.concept_hub(
             assertion.concept_id,
             coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'),
                      assertion.created_ontology_version_id)) as hub_key
  ) as hub on true
  -- 0364: the entity's own-language name, from `presumed_terms` — reached
  -- by the promotion link where one exists, else by exact normalized-label
  -- match at this version. Only a name that genuinely differs is shown; an
  -- English-native term keeps its single name.
  -- 0367: both halves of the term's identity, from the dictionary. The
  -- contract's rule decides what is drawn: the original is the language the
  -- entity *belongs to*, not the script a title used — so a natively
  -- English entity's row has original = english and earns no parenthesis,
  -- while a foreign entity's original differs and is shown. Matched by
  -- promotion link, by identity (a concept whose preferred label IS the
  -- original), or by exact label.
  left join lateral (
    select t.original_label, t.english_label
      from semantic_private.presumed_terms t
     where t.original_label is not null
       and t.english_label is not null
       and (t.promoted_concept_id = assertion.concept_id
            or t.original_label = coalesce(revision.preferred_label, '')
            or exists (
              select 1 from ontology.concept_labels l
               where l.concept_id = assertion.concept_id
                 and l.status = 'active'
                 and l.ontology_version_id = coalesce(
                       score.ontology_version_id,
                       assertion.created_ontology_version_id)
                 and l.normalized_label = t.normalized_label))
     order by (t.original_label = coalesce(revision.preferred_label, '')) desc,
              (t.promoted_concept_id = assertion.concept_id) desc,
              t.mention_support desc nulls last, t.id
     limit 1
  ) as native on true
  -- 0373: the owner's song syntax — "performer - song name", composer for
  -- classical. A work row is a *song* exactly when an accepted mapping's
  -- own observation carries the row's label as its title; a franchise or
  -- film never does, so nothing else is prefixed. Classical is read off
  -- the row's own stated genres, the same asymmetry 0038 established.
  left join lateral (
    select case
             when o.normalized_payload -> 'genres' ? 'Classical'
                  and nullif(btrim(o.normalized_payload ->> 'composer'), '') is not null
             then btrim(o.normalized_payload ->> 'composer')
             else nullif(btrim(o.normalized_payload ->> 'primary_performer'), '')
           end as artist
      from semantic_private.observation_mappings m
      join semantic_private.observations o
        on o.id = m.observation_id and o.user_id = m.user_id
     where revision.concept_kind = 'work'
       and m.concept_id = assertion.concept_id
       and m.user_id = assertion.user_id
       and m.mapping_state = 'accepted'
       -- 0375: extraction rightly splits the artist out of an album title
       -- ("Kiroro No Ichiban..." names the work "Ichiban..."), so exact
       -- equality misses precisely the rows whose performer is best
       -- known. The match: the title IS the label, or the album field is,
       -- or the title contains the label and names the performer — the
       -- remainder accounted for, not guessed.
       and (lower(btrim(o.normalized_payload ->> 'title'))
              = lower(btrim(revision.preferred_label))
            or lower(btrim(coalesce(o.normalized_payload ->> 'album', '')))
              = lower(btrim(revision.preferred_label))
            or (position(lower(btrim(revision.preferred_label))
                  in lower(o.normalized_payload ->> 'title')) > 0
                and nullif(btrim(o.normalized_payload ->> 'primary_performer'), '') is not null
                and position(lower(split_part(o.normalized_payload ->> 'primary_performer', ' ', 1))
                  in lower(o.normalized_payload ->> 'title')) > 0))
     order by m.evidence_weight * m.recency_weight desc
     limit 1
  ) as song on true
  -- 0387: the performer fallback — YouTube evidence carries no
  -- primary_performer field, so a song kept off a decorated video title
  -- drew bare. The dictionary's own performed_by relation names the
  -- artist deterministically.
  left join lateral (
    select ot.canonical_label as artist
      from semantic_private.presumed_terms t
      join semantic_private.presumed_term_relations rel
        on rel.subject_term_id = t.id and rel.predicate = 'performed_by'
      join semantic_private.presumed_terms ot on ot.id = rel.object_term_id
     where revision.concept_kind = 'work'
       and song.artist is null
       and t.promoted_concept_id = assertion.concept_id
     -- 0390: the group is the song's performer. 0391: and where only a
     -- member was stated (a fancam relation), the member's own
     -- member_of_group resolves to the group — karina stands in for
     -- aespa only until the join runs.
     order by (ot.family = 'group') desc,
              rel.observed_count desc nulls last, ot.id
     limit 1
  ) as song2 on true
  left join lateral (
    select gt.canonical_label as artist
      from semantic_private.presumed_terms mt
      join semantic_private.presumed_term_relations mg
        on mg.subject_term_id = mt.id and mg.predicate = 'member_of_group'
      join semantic_private.presumed_terms gt on gt.id = mg.object_term_id
     where song2.artist is not null
       and mt.normalized_label = lower(btrim(song2.artist))
       and mt.family = 'person' and gt.family = 'group'
     order by mg.observed_count desc nulls last, gt.id
     limit 1
  ) as song3 on true
  where assertion.user_id = auth.uid()
    and assertion.machine_state in ('candidate', 'eligible')
    and coalesce(preference.display_state, 'default') <> 'suppressed'
    -- Nameable things only. A term the person typed has no concept and no kind,
    -- and is always theirs to see.
    --
    -- `topic` joins the allowlist, less the three axis families: an axis is
    -- something the scorer reasons with, not a claim anybody would make about
    -- themselves, and striking one off would silently reweigh everything else.
    --
    -- 0360: `genre` and `culture` join it, and that is the owner deciding
    -- they belong (2026-08-25) — the propagated tail's whole point is that
    -- genre:pop and culture:taiwan are terms a person keeps or strikes, and
    -- an allowlist that withheld them would hide exactly what the bootstrap
    -- exists to price. The axis exclusions stand; `medium` and `hub` stay
    -- out, being structure rather than taste.
    -- 0367: an entry is a specific entity — a person, an organization, a
    -- group (a channel represented by more than one person is a group), a
    -- work, or a franchise (owner, 2026-08-25). The summarizing parents —
    -- genres, subjects, cultures — are the cards' *titles*, drawn by the
    -- block machinery, never rows beside their own children. A term the
    -- person typed or kept stays theirs to see whatever its kind.
    and (
      assertion.user_term_id is not null
      or assertion.assertion_origin <> 'inferred'
      or (
        revision.concept_kind in ('creator', 'work')
        and concept.concept_key not like 'era:%'
        and concept.concept_key not like 'sphere:%'
        and concept.concept_key not like 'scene:%'
      )
      -- 0436: trips return, by their own key (owner, 2026-08-27) —
      -- "a trip is a term like any other" supersedes 0375's travel
      -- half. Narrow on purpose: 0367's entity ruling on other
      -- activity concepts is not reopened.
      or concept.concept_key like 'travel:%'
      -- 0438: the fields show as terms (owner, 2026-08-27) — the
      -- generalized subjects, structurally marked: a subject whose hub
      -- is ideas_learning is a field; music_labels, travel and
      -- content_creators live under other hubs and are untouched.
      or (concept.concept_key like 'subject:%'
          and hub.hub_key = 'hub:ideas_learning')
    )
    -- 0375: place, travel and culture are too broad a layer for Memories
    -- (owner, 2026-08-25) — cultural preference is internal marking. They
    -- keep their assertions and weights and leave the page, every origin
    -- included: an internal marking is internal whoever put it there.
    -- (Supersedes 0373's travel rows, same day, by the owner's word.)
    -- 0375's place/culture halves stand; its travel half is superseded
    -- (owner, 2026-08-27) — see the allowlist above.
    and coalesce(revision.concept_kind, '') not in ('place', 'culture')
    -- 0437: for music, only persons and groups (owner, 2026-08-27). A
    -- work that resolves a performer or composer — through the same
    -- three laterals that compose its "artist - title" label — is a
    -- musical work, and its line on the page is the artist's, not its
    -- own. Films and franchises resolve no artist and stay. The strike
    -- cascade is the scorer's (0.23.0): a suppressed artist's works are
    -- derived-suppressed and demote on the next run.
    and not (
      revision.concept_kind = 'work'
      and coalesce(song.artist, song2.artist, song3.artist) is not null
    )
    -- 0438: and the specific channels leave the field blocks — the
    -- fields ruling's other half, the same inversion as music: the
    -- generalized term is the row, the specifics feed its weight.
    and not (
      assertion.assertion_origin = 'inferred'
      and revision.concept_kind = 'creator'
      and coalesce(hub.hub_key, '') = 'hub:ideas_learning'
    )
    and (
      assertion.assertion_origin <> 'inferred' or
      (
        score.id is not null
        and score_run.status = 'succeeded'
        and score_run.input_revision = coalesce(user_state.revision, 0)
      )
    )
    and not exists (
      select 1
      from semantic_private.user_suppressions as suppression
      where suppression.user_id = assertion.user_id
        and suppression.predicate_key = assertion.predicate_key
        and suppression.surface = 'memories'
        and suppression.active
        and (
          (assertion.concept_id is not null and suppression.concept_id = assertion.concept_id) or
          (assertion.user_term_id is not null and suppression.user_term_id = assertion.user_term_id)
        )
    )
    -- 0360: the cutoff. A display decision, per (user, hub), from the one
    -- active release. `coalesce(..., 1.0)` is deliberate twice over: a
    -- declared term has no score row and passes any cutoff at the top score
    -- (the same fallback the order by already uses), and a concept outside
    -- every hub resolves through the release default.
    and (coalesce(score.surfacing_score, 1.0)
        >= semantic_private.active_memories_cutoff(assertion.user_id, hub.hub_key)
      -- 0438: a field term passes at any score — the cutoff was fitted
      -- to leaf terms, and a generalized subject standing in for its
      -- hidden channels is shown because they were, not by its own
      -- propagated fraction.
      or (concept.concept_key like 'subject:%'
          and hub.hub_key = 'hub:ideas_learning'))
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$function$
;

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0438: the fields show their names — tag edges minted, display inverted');
end;
$$;

commit;
