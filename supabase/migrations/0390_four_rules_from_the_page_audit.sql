-- 0390 — four second-order fixes the page audit caught, each a rule.
--
-- 1. **A person's original label never carries channel decoration** —
--    the dictionary held ちゃんねる宮脇咲良 as Miyawaki Sakura's original;
--    the same strip the concept rename used applies to the data.
-- 2. **A group outranks a member as a song's performer** — the prefix
--    fallback ordered by observation count and a fancam relation put
--    karina ahead of aespa.
-- 3. **Label shelving reads the dictionary's relations, not catalogue
--    edges** — agencies have no incoming edges; the 12k stated relations
--    know exactly whose subjects feed them.
-- 4. **An album may follow its performer through its own evidence** —
--    where no performed_by relation was stated, the observation whose
--    album field names the album carries primary_performer directly.

begin;

-- 1. The dictionary sheds channel decorations from person names.
update semantic_private.presumed_terms
   set original_label = btrim(regexp_replace(original_label,
         '^(ちゃんねる|チャンネル|[Cc]hannel)\s*', '')),
       canonical_label = btrim(regexp_replace(canonical_label,
         '^(ちゃんねる|チャンネル|[Cc]hannel)\s*', ''))
 where family = 'person'
   and (original_label ~ '^(ちゃんねる|チャンネル|[Cc]hannel)\s*\S'
        or canonical_label ~ '^(ちゃんねる|チャンネル|[Cc]hannel)\s*\S');

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  n integer;
  music_id uuid; ent_id uuid;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  select id into music_id from ontology.concepts where concept_key='subject:music_labels';
  select id into ent_id from ontology.concepts where concept_key='subject:entertainment_labels';
  if music_id is null then
    raise notice '0390: shelves absent on this chain; classification waits';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Shelving by dictionary relations; albums follow evidence performers.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- 3. Shelving through the stated relations.
  create temporary table _orgs on commit drop as
  select c.id, c.concept_key,
    (select count(*) from semantic_private.presumed_term_relations rel
      join semantic_private.presumed_terms st on st.id = rel.subject_term_id
      join ontology.concepts sc on sc.id = coalesce(st.promoted_concept_id, st.proposed_parent_concept_id)
      where rel.object_term_id = t.id
        and semantic_private.concept_hub(sc.id, new_version_id) = 'hub:music') as music_feeders,
    (select count(*) from semantic_private.presumed_term_relations rel
      join semantic_private.presumed_terms st on st.id = rel.subject_term_id
      join ontology.concepts sc on sc.id = coalesce(st.promoted_concept_id, st.proposed_parent_concept_id)
      where rel.object_term_id = t.id
        and semantic_private.concept_hub(sc.id, new_version_id) = 'hub:film_video') as screen_feeders
  from semantic_private.presumed_terms t
  join ontology.concepts c on c.id = t.promoted_concept_id
  where t.family = 'organization'
    and not exists (select 1 from ontology.concept_edges e
      where e.ontology_version_id = new_version_id and e.status='active'
        and e.subject_concept_id = c.id and e.predicate_key = 'broader');

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, o.id, 'broader',
         case when o.music_feeders >= o.screen_feeders and o.music_feeders > 0
              then music_id
              when o.screen_feeders > 0 then ent_id end,
         0.8, 'learned', '{"source":"0390_label_shelves"}'::jsonb, 'active'
    from _orgs o where o.music_feeders > 0 or o.screen_feeders > 0
  on conflict do nothing;
  get diagnostics n = row_count;
  raise notice '0390: % organization(s) shelved via relations', n;

  -- 4. Albums/tours follow their evidence performer.
  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select distinct on (ac.id)
         new_version_id, ac.id, 'broader', h.id, 0.75, 'learned',
         '{"source":"0390_album_follows_evidence"}'::jsonb, 'active'
    from semantic_private.presumed_terms t
    join ontology.concepts ac on ac.id = t.promoted_concept_id
    join ontology.concept_revisions ar
      on ar.concept_id = ac.id and ar.ontology_version_id = new_version_id
     and ar.status = 'active'
    join semantic_private.observations o
      on lower(btrim(coalesce(o.normalized_payload->>'album',
                              o.normalized_payload->>'title')))
         = lower(btrim(ar.preferred_label))
     and nullif(btrim(o.normalized_payload->>'primary_performer'), '') is not null
    join ontology.concept_labels pl
      on pl.ontology_version_id = new_version_id and pl.status = 'active'
     and pl.normalized_label = lower(btrim(split_part(
           o.normalized_payload->>'primary_performer', ',', 1)))
    join ontology.concepts pc on pc.id = pl.concept_id
    cross join lateral (
      select c2.id from ontology.concepts c2
       where c2.concept_key = semantic_private.concept_block(pc.id, new_version_id)
         and c2.concept_key not like 'hub:%') as h
   where t.family in ('album', 'tour')
     and not exists (select 1 from ontology.concept_edges e
       where e.ontology_version_id = new_version_id and e.status='active'
         and e.subject_concept_id = ac.id and e.predicate_key = 'broader')
   order by ac.id, o.id
  on conflict do nothing;
  get diagnostics n = row_count;
  raise notice '0390: % album/tour(s) follow their evidence performer', n;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': shelves and albums, second pass');
  raise notice '0390: % published', next_version;
end;
$$;

-- 2. The prefix fallback prefers the group.
create or replace function api.list_assertions()
returns table(
  assertion_id uuid, predicate_key text, label text, origin text,
  display_state text, strength double precision, confidence double precision,
  breadth integer, stability double precision,
  surfacing_score double precision, display_payload jsonb,
  assertion_score_version_id uuid, ontology_version_id uuid,
  block_key text, block_label text
)
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select
    assertion.id,
    assertion.predicate_key,
    -- 0364: the designated syntax — official name (original language
    -- name) — composed from the dictionary, which is the one store that
    -- knows both halves of a foreign term's identity.
    coalesce(coalesce(song.artist, song2.artist) || ' - ', '') ||
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
     -- 0390: the group is the song's performer; a member's fancam
     -- relation must not outrank the group (measured: karina - Next
     -- Level where aespa performs it).
     order by (ot.family = 'group') desc,
              rel.observed_count desc nulls last, ot.id
     limit 1
  ) as song2 on true
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
    )
    -- 0375: place, travel and culture are too broad a layer for Memories
    -- (owner, 2026-08-25) — cultural preference is internal marking. They
    -- keep their assertions and weights and leave the page, every origin
    -- included: an internal marking is internal whoever put it there.
    -- (Supersedes 0373's travel rows, same day, by the owner's word.)
    and coalesce(revision.concept_kind, '') not in ('place', 'culture')
    and coalesce(concept.concept_key, '') not like 'travel:%'
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
    and coalesce(score.surfacing_score, 1.0)
        >= semantic_private.active_memories_cutoff(assertion.user_id, hub.hub_key)
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$function$;

do $$
begin
  if position('order by coalesce(score.surfacing_score, 1.0) desc' in
       pg_get_functiondef('api.list_assertions()'::regprocedure)) = 0 then
    raise exception '0390: list_assertions lost its ordering';
  end if;
end;
$$;

commit;
