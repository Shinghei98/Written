-- 0114 — scorer 0.6.0: a rejection redistributes the evidence it explains.
--
-- **The owner's model.** Liking a song admits three readings — the singer and
-- the song, the singer only, the song only. Striking off the singer eliminates
-- the first two, so what remains must be carried by whatever else the row
-- names. It is the classical composer/performer/work dilemma with a pop name on
-- it, which `classical_performer_min_albums` already solves one corner of.
--
-- **The schema had named this and nothing acted on it.** A suppression is
-- written `label_semantics = 'ambiguous_rejection'` — the vocabulary says the
-- rejection does not tell you which reading it was. Redistributing among the
-- concepts that shared the row is disambiguating it, and is **not** a
-- concept-level negative: nothing asserts that the person dislikes the
-- struck-off concept, only that its rows are better explained by something else
-- on them. `user_suppressions` remains empty and is where a real negative would
-- live.
--
-- **Recipients are the `composer` and `source_work` roles, never sibling
-- creators**, and the data decided that rather than the idea. Cynthia Erivo's
-- rows also carry Ariana Grande, Idina Menzel, Kristin Chenoweth and the Wicked
-- Movie Cast — boosting every co-occurring name would let striking off one cast
-- member promote the other five, who are in the same ambiguous position. And
-- the Berlin Philharmonic's rows carry **no work at all**: 108 creator mappings,
-- zero `source_work`, so in classical the gainer is the composer. Writing the
-- rule in the resolver's *roles* rather than in `concept_kind` is what makes
-- both cases one rule.
--
-- Genre, era, scene and sphere are excluded: "I don't like the singer" says
-- nothing new about the genre, which the row already supported.
--
-- **Conservation rather than a constant, which is the part worth keeping.** The
-- freed weight is exactly what the suppressed concept drew from those rows,
-- apportioned by what each recipient already rests on them. Nothing was tuned.
-- Measured before it was written: Erivo frees 4.247 against Wicked's 9.580 and
-- Stephen Schwartz's 4.416; the Berlin Philharmonic frees 13.894 across
-- Beethoven at 13.99 and Mahler at 13.84. A multiplier would have needed a
-- number nobody measured; this says something truer — the listening did not
-- change, only the account of it.
--
-- **Added before saturation.** `strength` is `w/(w+6)` and nearly flat where a
-- well-evidenced concept sits, so adding to its *output* would give a large
-- transfer almost no effect there and a small one a large effect on a weak
-- concept. A flat performer weight failed on exactly that arithmetic once.
--
-- **This makes feedback an input again, which `0113` said it was not.** That
-- was true of the system as it stood and false from this deploy: a suppression
-- now changes what the scorer computes. The rule `0113` states survives — the
-- revision moves when the scorer's inputs move — and what changed is which
-- writes are inputs. `0115` restores the bump for `suppress` and `restore`,
-- and not for `explicit_add`, which still adds a row the scorer never reads.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.6.0'),
  'missing_aware_late_fusion', '0.6.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0,'
  ' "eligible_strength": 0.35, "eligible_strength_by_kind": {"work": 0.25},'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"], "withdraws_assertions": true,'
  ' "suppression_transfer": {'
  '   "from_role": "creator", "to_roles": ["composer", "source_work"],'
  '   "rule": "conservation: the freed weight is what the suppressed concept'
  ' drew from those rows, apportioned by each recipient''s existing weight on'
  ' them; no constant",'
  '   "applied": "before saturation",'
  '   "not": "a concept-level negative, and never to sibling creators or to'
  ' genre, era, scene or sphere"}}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.5.0' and status = 'active';

do $$
declare
  active_scorers integer;
  newest text;
  enqueued integer;
begin
  select count(*) into active_scorers
  from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if active_scorers <> 1 then
    raise exception 'expected exactly one active scorer, found %', active_scorers;
  end if;

  select version into newest
  from ontology.model_versions
  where model_role = 'scorer' and status = 'active'
  order by created_at desc, id
  limit 1;
  if newest <> '0.6.0' then
    raise exception 'finalization would pick scorer %, not 0.6.0', newest;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.6.0: a suppressed creator transfers its weight to composer and work'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for the 0.6.0 scorer', enqueued;
end
$$;

commit;
