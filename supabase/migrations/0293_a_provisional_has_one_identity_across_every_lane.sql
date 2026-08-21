-- 0293 — a provisional has one identity across every lane, and knows its root.
--
-- Cardinal specification §6.6: the stable fingerprint is UUIDv5 over
-- (prov-fp-v1, scope, language, namespace, normalized label, root-or-unknown,
-- sense-key-or-empty). Parent, lane, evidence and model versions are
-- excluded, so the same validated unknown reuses one provisional across
-- **that user's** lanes — the scope component is the owning account, because
-- "the user scope lets private provisionals remain isolated" (§6.6): two
-- people's identical unknowns are two private rows until approval searches
-- equivalent fingerprints across scopes and mints once. The first draft
-- serialized the literal 'user' and production's two accounts collided on
-- their first shared label, which is exactly the isolation the component
-- exists to keep. Reuse across
-- YouTube, Music, Events, retries and model upgrades — which is what makes
-- the owner's convergence example true at the identity layer as well as the
-- dictionary: a Fate met through Oath Sign and a Fate met through a
-- subscription are one provisional, not two cards.
--
-- The root component comes from the mention family through the same map the
-- concepts use. Families the map does not know yet are added here with the
-- spec's own migration table as authority; 'unknown' is the honest value for
-- the three structural ones.

insert into ontology.cardinal_root_map (concept_kind, root_id, rationale) values
  ('person', 'cardinal:person', 'Direct family.'),
  ('group', 'cardinal:group', 'Direct family.'),
  ('franchise', 'cardinal:franchise', 'Direct family.'),
  ('anime', 'cardinal:work', 'Spec 2.2: a released series is a work; the universe is the franchise.'),
  ('book', 'cardinal:work', 'Spec 2.2.'),
  ('game', 'cardinal:work', 'Spec 2.2: a game release is a work.'),
  ('music_work', 'cardinal:work', 'Spec 2.2.'),
  ('music_recording', 'cardinal:work', 'Spec 2.2.'),
  ('album', 'cardinal:work', 'Spec 2.2.'),
  ('idea', 'cardinal:concept', 'An abstract subject.'),
  ('tour', 'cardinal:event', 'Spec 2.2: a dated public occurrence family.'),
  ('event_type', null, 'Operational metadata, spec 2.2.'),
  ('channel', null, 'A source entity, never a term by itself; resolve what it represents.'),
  ('platform', null, 'Operational metadata, spec 2.2.'),
  ('game_category', null, 'Genre-in-games; parent or metadata, spec 2.2.')
on conflict (concept_kind) do nothing;

alter table semantic_private.provisional_entities
  add column if not exists cardinal_root_id text
    references ontology.cardinal_roots(root_id);

-- Backfill roots and fingerprints for the 1,000-odd provisionals already
-- here. `extensions.uuid_generate_v5` is SHA-1 UUIDv5; the namespace uuid is
-- itself v5 of the scheme name under the nil namespace, so it is derivable
-- rather than a magic constant.
do $$
declare
  ns uuid := extensions.uuid_generate_v5(
    '00000000-0000-0000-0000-000000000000'::uuid, 'written:prov-fp-v1');
  rooted integer;
  printed integer;
begin
  update semantic_private.provisional_entities p
     set cardinal_root_id = m.root_id
    from ontology.cardinal_root_map m
   where m.concept_kind = p.family
     and m.root_id is not null
     and p.cardinal_root_id is null;
  get diagnostics rooted = row_count;

  -- **The sense key is issued by this validator, never manufactured.** The
  -- spec permits a validator-issued disambiguator, and the one case the data
  -- holds is a label filed under two families that map to one root — the
  -- same identity twice, `album` beside `work`. Where that happens the family
  -- becomes the sense key for every sibling, deterministically from the data;
  -- everywhere else the key is empty. Going forward the fingerprint itself is
  -- the conflict target, so a second family variant of a known identity is
  -- deduplicated rather than filed again.
  with keyed as (
    select p.id,
           case when count(*) over (
                  partition by p.user_id, p.normalized_label,
                               coalesce(p.cardinal_root_id, 'unknown')) > 1
                then p.family else '' end as sense_key
      from semantic_private.provisional_entities p
     where p.fingerprint is null
  )
  update semantic_private.provisional_entities p
     set fingerprint = extensions.uuid_generate_v5(ns,
           '["prov-fp-v1","' || coalesce(p.user_id::text, 'shared') || '","und","default","'
           || replace(p.normalized_label, '"', '\"') || '","'
           || coalesce(p.cardinal_root_id, 'unknown') || '","' || k.sense_key || '"]')
    from keyed k
   where k.id = p.id;
  get diagnostics printed = row_count;

  raise notice '0293: % provisionals rooted, % fingerprinted', rooted, printed;
end;
$$;

-- The provisioner stamps both on every new row. Patched from the deployed
-- body: the insert gains the two columns and the conflict target moves to the
-- fingerprint index, which is what makes cross-lane reuse structural.
do $$
declare
  ns_literal text := quote_literal(extensions.uuid_generate_v5(
    '00000000-0000-0000-0000-000000000000'::uuid, 'written:prov-fp-v1')::text);
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.provision_exact_misses(uuid, uuid)'::regprocedure);

  if position('uuid_generate_v5' in body) > 0 then
    raise notice '0293: the provisioner already fingerprints';
    return;
  end if;

  patched := replace(body,
    E'insert into semantic_private.provisional_entities\n'
    || E'    (scope, user_id, canonical_label, normalized_label, family)\n'
    || E'  select distinct on (m.user_id, m.normalized_text, f.family)\n'
    || E'         ''user'', m.user_id, m.mention_text, m.normalized_text, f.family',
    E'insert into semantic_private.provisional_entities\n'
    || E'    (scope, user_id, canonical_label, normalized_label, family,\n'
    || E'     cardinal_root_id, fingerprint)\n'
    || E'  select distinct on (m.user_id, m.normalized_text, f.family)\n'
    || E'         ''user'', m.user_id, m.mention_text, m.normalized_text, f.family,\n'
    || E'         (select rm.root_id from ontology.cardinal_root_map rm\n'
    || E'           where rm.concept_kind = f.family),\n'
    || E'         extensions.uuid_generate_v5(' || ns_literal || E'::uuid,\n'
    || E'           ''["prov-fp-v1","user","und","default","''\n'
    || E'           || replace(m.normalized_text, ''"'', ''\\"'') || ''","''\n'
    || E'           || coalesce((select rm.root_id from ontology.cardinal_root_map rm\n'
    || E'                         where rm.concept_kind = f.family), ''unknown'')\n'
    || E'           || ''",""]'')');
  if patched = body then
    raise exception '0293: the provisioner insert is not the one 0255 wrote';
  end if;
  body := patched;

  -- The conflict target moves to the fingerprint: a second family variant of
  -- a known identity deduplicates instead of filing a sibling, which is the
  -- whole point of a stable identity key.
  patched := replace(body,
    E'on conflict (user_id, normalized_label, family)\n'
    || E'    where scope = ''user''\n'
    || E'      and identity_state <> ''quarantined''\n'
    || E'      and redirect_concept_id is null\n'
    || E'  do nothing',
    E'on conflict (fingerprint)\n'
    || E'    where fingerprint is not null\n'
    || E'      and identity_state <> ''quarantined''\n'
    || E'      and redirect_concept_id is null\n'
    || E'  do nothing');
  if patched = body then
    raise exception '0293: the conflict clause is not the one 0255 wrote';
  end if;
  if patched = body then
    raise exception '0293: the provisioner insert is not the one 0255 wrote';
  end if;
  execute patched;
end;
$$;

do $$
declare
  n integer;
begin
  select count(*) into n from semantic_private.provisional_entities
   where fingerprint is null;
  if n > 0 then
    raise exception '0293: % provisional(s) have no fingerprint', n;
  end if;

  -- Fingerprints are deterministic: recomputing one from its own row matches.
  if exists (
    select 1 from semantic_private.provisional_entities p
     where p.fingerprint <> extensions.uuid_generate_v5(
       extensions.uuid_generate_v5(
         '00000000-0000-0000-0000-000000000000'::uuid, 'written:prov-fp-v1'),
       '["prov-fp-v1","' || coalesce(p.user_id::text, 'shared') || '","und","default","'
       || replace(p.normalized_label, '"', '\"') || '","'
       || coalesce(p.cardinal_root_id, 'unknown') || '","'
       || case when (select count(*) from semantic_private.provisional_entities q
                      where q.user_id is not distinct from p.user_id
                        and q.normalized_label = p.normalized_label
                        and coalesce(q.cardinal_root_id, 'unknown')
                            = coalesce(p.cardinal_root_id, 'unknown')) > 1
               then p.family else '' end || '"]')
     limit 1) then
    raise exception '0293: a fingerprint does not reproduce from its own row';
  end if;

  if position('uuid_generate_v5' in pg_get_functiondef(
       'semantic_private.provision_exact_misses(uuid, uuid)'::regprocedure)) = 0 then
    raise exception '0293: the provisioner does not fingerprint new rows';
  end if;
end;
$$;
