-- 0306 — a presumed term may state a relation, and it is never traversed.
--
-- The model states far more than it is currently allowed to record. One RIS
-- run over the full distillation produced **6,982 distinct relation edges** —
-- 3,631 `performed_by`, 2,995 `part_of_franchise`, 252 `composed_by` — and
-- every one was discarded, because `candidate_relation_proposals` requires a
-- concept or a provisional as its subject and a presumed term is neither.
-- That is the graph the dictionary has been missing: this album by that
-- group, this character in that franchise.
--
-- **Presumed, exactly as the terms are.** A relation here is what a model
-- said, not what anyone verified, so it carries the same discipline
-- `presumed_terms` does: append-only, never deleted, and — the important
-- one — **never traversable**. `candidate_relation_proposals` pins
-- `traversable` false unless `authority_state = 'verified_relation'` so a
-- proposed relation can never be walked for inference; the same rule holds
-- here by construction, because nothing reads this table into the ontology.
-- It is evidence for a later governance pass, not a shortcut into one.
--
-- The predicate vocabulary is the wire's own twelve, plus `broader`, which
-- `0295` already admitted for a chosen parent.

create table if not exists semantic_private.presumed_term_relations (
  id uuid primary key default gen_random_uuid(),
  subject_term_id uuid not null
    references semantic_private.presumed_terms (id),
  predicate text not null check (predicate in
    ('part_of_franchise', 'features', 'about', 'performed_by',
     'composed_by', 'recording_of', 'soundtrack_of', 'member_of_group',
     'played_for', 'official_channel_of', 'represented_team_in',
     'located_in', 'broader')),
  object_term_id uuid not null
    references semantic_private.presumed_terms (id),
  basis text not null default 'model_stated'
    check (basis in ('model_stated', 'authored')),
  evidence jsonb not null default '{}'::jsonb,
  observed_count integer not null default 1 check (observed_count > 0),
  created_at timestamptz not null default now(),
  -- One edge per (subject, predicate, object): the same claim seen twice is
  -- the same claim, and its weight belongs in `observed_count` rather than
  -- in duplicate rows nobody can aggregate.
  unique (subject_term_id, predicate, object_term_id),
  -- A term does not relate to itself; that is a spelling, and 0301's links
  -- are where a spelling belongs.
  check (subject_term_id <> object_term_id)
);

alter table semantic_private.presumed_term_relations enable row level security;

create or replace function semantic_private.guard_presumed_term_relation_change()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  -- The count may rise as the same claim is seen again; nothing else moves,
  -- because a relation is a record of what was said at a moment.
  if tg_op = 'UPDATE'
     and new.subject_term_id = old.subject_term_id
     and new.predicate = old.predicate
     and new.object_term_id = old.object_term_id
     and new.basis = old.basis
     and new.created_at = old.created_at
     and new.observed_count >= old.observed_count then
    return new;
  end if;
  raise exception 'presumed_term_relations is append-only';
end;
$$;

create trigger presumed_term_relations_append_only
  before update or delete on semantic_private.presumed_term_relations
  for each row execute function
    semantic_private.guard_presumed_term_relation_change();

grant select, insert, update (observed_count)
  on semantic_private.presumed_term_relations to semantic_worker;

-- Both directions over real rows: an edge is recorded, a second sighting
-- raises its count, a self-edge is refused, and a rewrite is refused.
do $$
declare
  a uuid; b uuid; n integer;
begin
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, origin, source_lanes)
  values ('0306 test subject', 'album', '0306 test subject', 'extracted', '{}')
  returning id into a;
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, origin, source_lanes)
  values ('0306 test object', 'group', '0306 test object', 'extracted', '{}')
  returning id into b;

  insert into semantic_private.presumed_term_relations
    (subject_term_id, predicate, object_term_id) values (a, 'performed_by', b);

  insert into semantic_private.presumed_term_relations
    (subject_term_id, predicate, object_term_id) values (a, 'performed_by', b)
  on conflict (subject_term_id, predicate, object_term_id) do update
     set observed_count = semantic_private.presumed_term_relations.observed_count + 1;
  select observed_count into n from semantic_private.presumed_term_relations
   where subject_term_id = a and object_term_id = b;
  if n <> 2 then
    raise exception '0306: a second sighting did not raise the count (%)', n;
  end if;

  begin
    insert into semantic_private.presumed_term_relations
      (subject_term_id, predicate, object_term_id) values (a, 'performed_by', a);
    raise exception '0306: a term related to itself';
  exception when check_violation then null;
  end;

  begin
    update semantic_private.presumed_term_relations
       set predicate = 'about' where subject_term_id = a;
    raise exception '0306: a relation was rewritten';
  exception when others then
    if sqlerrm not like '%append-only%' then raise; end if;
  end;
end;
$$;
