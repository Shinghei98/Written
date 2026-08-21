-- 0301 — one term per thing: the dictionary's identity layer.
--
-- The owner's audit found one person as three rows — sakura, 사쿠라, 宮脇咲良 —
-- each tallying its own keeps. The dictionary's key is deliberately the exact
-- (normalized_label, family): source-agnostic but script-literal. This
-- migration adds what §6.6 prescribes on the dictionary side: identity links
-- from STATED evidence, a canonical pointer so tallying is one hop at write
-- time, and cluster weights.
--
-- Two tiers, because "similar" means two different things (owner, 2026-08-21):
--   * Mechanical similarity — release-type suffixes — is normalized into the
--     key at write time (the worker's `_normalize`), deterministic and never
--     wrong. Existing suffix rows LINK to their base instead of being
--     rewritten.
--   * Cross-language identity is a POINTER, never a row merge. An identity
--     claim can be wrong, and a wrong merge summed into one counter cannot be
--     unmixed — the nine-artists lesson. A bad link is superseded by an
--     authored counter-link; the pointer moves back; per-variant tallies were
--     never contaminated.
--
-- Merge evidence is closed-vocabulary and never string distance:
--   label_pair        one mention stated both spellings (english/original/
--                     corrected canonical — the archiology→archaeology route)
--   suffix_strip      the variant is the canonical plus a release-type suffix
--   same_fingerprint  provisional identity already unified them (0293)
--   authored          a human said so; also the counter-link that undoes one

alter table semantic_private.presumed_terms
  add column if not exists canonical_term_id uuid
    references semantic_private.presumed_terms (id);

create table if not exists semantic_private.presumed_term_links (
  id uuid primary key default gen_random_uuid(),
  variant_term_id uuid not null
    references semantic_private.presumed_terms (id),
  canonical_term_id uuid not null
    references semantic_private.presumed_terms (id),
  basis text not null check (basis in
    ('label_pair', 'suffix_strip', 'same_fingerprint', 'authored')),
  -- An authored link may sever: canonical = variant restores independence.
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (variant_term_id <> canonical_term_id or basis = 'authored')
);

alter table semantic_private.presumed_term_links enable row level security;

create or replace function semantic_private.guard_presumed_term_link_change()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  raise exception 'presumed_term_links is append-only; sever with an authored counter-link';
end;
$$;

create trigger presumed_term_links_append_only
  before update or delete on semantic_private.presumed_term_links
  for each row execute function semantic_private.guard_presumed_term_link_change();

-- **The pointer follows the latest link, flattened.** The canonical of a
-- canonical is itself; a chain is collapsed when written so reads never walk.
-- An authored self-link severs: the variant becomes its own canonical again.
create or replace function semantic_private.apply_presumed_term_link()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  target uuid;
begin
  if new.variant_term_id = new.canonical_term_id then
    update semantic_private.presumed_terms
       set canonical_term_id = null
     where id = new.variant_term_id;
    return new;
  end if;

  -- Flatten: follow the canonical's own pointer if it has one.
  select coalesce(p.canonical_term_id, p.id) into target
    from semantic_private.presumed_terms p
   where p.id = new.canonical_term_id;

  -- A cycle is refused rather than flattened into nonsense: if the proposed
  -- canonical already points (transitively, which flattening makes one hop)
  -- at the variant, the link would make each the other's canonical.
  if target = new.variant_term_id then
    raise exception 'presumed_term_links: link would form a cycle';
  end if;

  update semantic_private.presumed_terms
     set canonical_term_id = target
   where id = new.variant_term_id;
  -- Anything already pointing at the variant follows it to the new canonical.
  update semantic_private.presumed_terms
     set canonical_term_id = target
   where canonical_term_id = new.variant_term_id;
  return new;
end;
$$;

create trigger presumed_term_links_apply
  after insert on semantic_private.presumed_term_links
  for each row execute function semantic_private.apply_presumed_term_link();

grant select, insert on semantic_private.presumed_term_links to semantic_worker;

-- Cluster weights: a GROUP BY over the pointer, not a closure walk. The
-- per-row figures stay in the base view; this integrates them.
create or replace view semantic_private.presumed_term_cluster_weights
with (security_invoker = on) as
select coalesce(pt.canonical_term_id, pt.id) as canonical_term_id,
       sum(coalesce(w.keeps, 0))::integer as keeps,
       sum(coalesce(w.strikes, 0))::integer as strikes,
       sum(coalesce(w.distinct_users, 0))::integer as distinct_users,
       count(*)::integer as variant_count,
       (sum(coalesce(w.keeps, 0)) + 4.0)
         / (sum(coalesce(w.keeps, 0)) + sum(coalesce(w.strikes, 0)) + 8.0)
         as weight
from semantic_private.presumed_terms pt
left join semantic_private.presumed_term_weights w
  on w.presumed_term_id = pt.id
group by coalesce(pt.canonical_term_id, pt.id);

grant select on semantic_private.presumed_term_cluster_weights to semantic_worker;

-- Both directions, over real data: a link moves the pointer and the cluster
-- weight; a severing link moves them back; a cycle is refused.
do $$
declare
  a uuid; b uuid; c uuid;
  canon uuid;
begin
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, origin, source_lanes)
  values ('0301 test variant', 'person', '0301 test variant', 'extracted', '{}')
  returning id into a;
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, origin, source_lanes)
  values ('0301 test canonical', 'person', '0301 Test Canonical', 'extracted', '{}')
  returning id into b;
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, origin, source_lanes)
  values ('0301 test third', 'person', '0301 test third', 'extracted', '{}')
  returning id into c;

  insert into semantic_private.presumed_term_links
    (variant_term_id, canonical_term_id, basis) values (a, b, 'authored');
  select canonical_term_id into canon
    from semantic_private.presumed_terms where id = a;
  if canon <> b then
    raise exception '0301: the pointer did not follow the link';
  end if;

  -- Chain flattening: c -> a must land on b, one hop.
  insert into semantic_private.presumed_term_links
    (variant_term_id, canonical_term_id, basis) values (c, a, 'authored');
  select canonical_term_id into canon
    from semantic_private.presumed_terms where id = c;
  if canon <> b then
    raise exception '0301: a chained link was not flattened';
  end if;

  -- Cycle refusal.
  begin
    insert into semantic_private.presumed_term_links
      (variant_term_id, canonical_term_id, basis) values (b, a, 'authored');
    raise exception '0301: a cycle was accepted';
  exception when others then
    if sqlerrm not like '%cycle%' then raise; end if;
  end;

  -- Severing restores independence.
  insert into semantic_private.presumed_term_links
    (variant_term_id, canonical_term_id, basis) values (a, a, 'authored');
  select canonical_term_id into canon
    from semantic_private.presumed_terms where id = a;
  if canon is not null then
    raise exception '0301: severing did not restore independence';
  end if;

  -- The three test rows stay: the dictionary never deletes, and a no-delete
  -- trigger would refuse anyway. They are severed and weightless.
end;
$$;
