-- 0440 — a recording with no name still has a shelf.
--
-- **The owner found the leak: "Violin Concertos", "Symphonies Nos.
-- 5 & 7" and "Requiem" standing in Classical.** They are work-kind
-- recordings whose generic catalogue titles resolve no composer or
-- performer, so 0437's artist detector could not call them musical
-- works and the music ruling missed them. The closure is structural:
-- an inferred work under `hub:music` is a musical work whether or not
-- its artist resolves — the shelf proves what the title cannot. Works
-- outside the music hub keep the artist test, and a user's own or
-- kept term is untouched as always.

begin;

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
    -- 0440: the artist test alone let generic classical recordings
    -- through ("Symphonies Nos. 5 & 7", "Requiem") — catalogue titles
    -- whose composer never resolves. The hub is the proof the title
    -- cannot give: an inferred work under hub:music is a musical work,
    -- and its line belongs to its composer or performer.
    and not (
      revision.concept_kind = 'work'
      and (coalesce(song.artist, song2.artist, song3.artist) is not null
           or (assertion.assertion_origin = 'inferred'
               and hub.hub_key = 'hub:music'))
    )
    -- 0438: and the specific channels leave the field blocks — the
    -- fields ruling's other half, the same inversion as music: the
    -- generalized term is the row, the specifics feed its weight.
    and not (
      assertion.assertion_origin = 'inferred'
      and revision.concept_kind = 'creator'
      and coalesce(hub.hub_key, '') = 'hub:ideas_learning'
    )
    -- 0439: be specific if possible (owner, 2026-08-27) — a field
    -- parent is withheld while a shown field child points at it
    -- through a broader edge: "French (language)" retires "Language
    -- learning", physics retires generic Science. The parent's
    -- assertion and weight stand; only the less specific line yields.
    and not (
      concept.concept_key like 'subject:%'
      and hub.hub_key = 'hub:ideas_learning'
      and exists (
        select 1
          from semantic_private.user_assertions child
          join ontology.concepts cc
            on cc.id = child.concept_id and cc.concept_key like 'subject:%'
          join ontology.concept_edges ce
            on ce.subject_concept_id = child.concept_id
           and ce.object_concept_id = assertion.concept_id
           and ce.predicate_key = 'broader' and ce.status = 'active'
           and ce.ontology_version_id = coalesce(
                 score.ontology_version_id,
                 (select pv.id from ontology.versions pv
                   where pv.status = 'published'),
                 assertion.created_ontology_version_id)
         where child.user_id = assertion.user_id
           and child.machine_state in ('candidate', 'eligible'))
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
  if position('order by coalesce(score.surfacing_score, 1.0) desc' in
       pg_get_functiondef('api.list_assertions()'::regprocedure)) = 0 then
    raise exception '0440: list_assertions lost its ordering';
  end if;
end;
$$;

commit;
