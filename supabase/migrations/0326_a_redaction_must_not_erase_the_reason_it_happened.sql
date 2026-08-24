-- 0326 — redaction erased the key the guard joined on.
--
-- `0324` refuses a card whose spelling carries an `excluded_reason`, matching
-- `provisional_entities.normalized_label` against
-- `presumed_terms.normalized_label`. `0323` and `0325` redact an excluded term
-- by overwriting **that same column** with `'redacted:' || id`, because the
-- normalized label *is* the name and leaving it readable in a cross-user table
-- is the thing the redaction exists to prevent.
--
-- So the two are at odds, and the second silently disarms the first: **the
-- moment a term is redacted it stops being findable, and a later candidate
-- with that spelling is drawn.** Measured immediately after `0325`: `阮育志` —
-- a channel with two subscribers belonging to somebody the owner knows —
-- became a drawable card, and the card count rose by exactly one at the moment
-- the redaction landed. A guard that is defeated by the remedy it is paired
-- with is worse than no guard, because the count going *up* after a privacy
-- fix reads as unrelated noise.
--
-- **The exclusion becomes a fact of its own instead of a property of a row.**
-- `semantic_private.excluded_term_keys` holds one digest per excluded
-- spelling. It is not redacted, because it holds no name; it survives the
-- redaction of every row that produced it; and a term minted next month with
-- the same spelling meets it without anybody re-running a sweep.
--
-- **Why a digest is honest here, and where it would not be.** This project
-- keys `source_item_hmac` rather than hashing it, on the argument that source
-- ids are guessable and an unkeyed digest would let anyone with read access
-- confirm a fact about a person. That argument does not transfer: every
-- spelling in this table is **already plaintext** in `public.distilled_records`
-- — the calendar titles, the channel names, the playlist owners — so the digest
-- discloses nothing that a reader of this database cannot already read. What it
-- buys is that the exclusion list itself is not a legible roster of the
-- owner's acquaintances.

create table if not exists semantic_private.excluded_term_keys (
  label_key   text primary key,
  reason      text not null
    check (reason in ('private_calendar', 'account_owner', 'private_channel')),
  recorded_at timestamptz not null default now()
);

comment on table semantic_private.excluded_term_keys is
  'One md5 per spelling that may never become a card. Separate from '
  'presumed_terms because redacting a term destroys its label, and the guard '
  'must outlive the redaction (0326). Append-only in practice: a spelling '
  'stops being excluded by deleting its row, which is a deliberate act.';

revoke all on semantic_private.excluded_term_keys from public;
grant select on semantic_private.excluded_term_keys to semantic_worker;

do $$
declare
  recorded integer;
  owners text[];
  channels text[];
  shelves text[];
begin
  -- **Every marked spelling that is still readable.** `0323` marked 1,175 and
  -- redacted 174 of them, so most marked rows still carry their label and can
  -- be recorded directly.
  insert into semantic_private.excluded_term_keys (label_key, reason)
  select distinct md5(lower(btrim(pt.normalized_label))), pt.excluded_reason
    from semantic_private.presumed_terms pt
   where pt.excluded_reason is not null
     and pt.normalized_label not like 'redacted:%'
     and coalesce(btrim(pt.normalized_label), '') <> ''
  on conflict (label_key) do nothing;

  -- **And the ones whose label the redaction already destroyed, recovered from
  -- the source rather than from the row.** `0325`'s three sets are computed
  -- from `public.distilled_records`, so they can be derived again at any time —
  -- which is the whole reason that migration derived them instead of listing
  -- names. `0323`'s calendar residue cannot be recovered this way and does not
  -- need to be: the calendar gate now refuses those rows at the source, so no
  -- candidate with those spellings can be minted again.
  select coalesce(array_agg(distinct lower(btrim(creator))), '{}') into owners
    from public.distilled_records
   where source = 'youtube' and data_type in ('playlist', 'playlist_item')
     and coalesce(btrim(creator), '') <> '';

  select coalesce(array_agg(distinct lower(btrim(name))), '{}') into channels
    from public.distilled_records
   where source = 'youtube' and data_type = 'subscription'
     and coalesce(btrim(name), '') <> ''
     and coalesce(nullif(regexp_replace(
           coalesce(extra ->> 'subscriber_count', ''), '[^0-9]', '', 'g'), ''),
         '0')::bigint < 150;

  select coalesce(array_agg(distinct lower(btrim(extracted))), '{}') into shelves
    from (
      select regexp_replace(creator, '^Apple Music for\s+', '') as extracted
        from public.distilled_records
       where source = 'apple_music' and data_type = 'recommendation'
         and creator ~ '^Apple Music for\s+\S'
      union all
      select regexp_replace(name, '(’|'')s Station$', '')
        from public.distilled_records
       where source = 'apple_music' and data_type = 'recommendation'
         and name ~ '(’|'')s Station$'
    ) templates
   where coalesce(btrim(extracted), '') <> '';

  insert into semantic_private.excluded_term_keys (label_key, reason)
  select md5(spelling), 'private_channel' from unnest(channels) as spelling
  on conflict (label_key) do nothing;

  insert into semantic_private.excluded_term_keys (label_key, reason)
  select md5(spelling), 'account_owner' from unnest(owners || shelves) as spelling
  on conflict (label_key) do nothing;

  select count(*) into recorded from semantic_private.excluded_term_keys;
  raise notice '0326: % excluded spellings recorded', recorded;
end;
$$;

-- ---------------------------------------------------------------------------
-- The guard reads the fact, not the row
-- ---------------------------------------------------------------------------

create or replace function semantic_private.review_item_is_coarse(p_candidate_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce((
    select case
             -- **A spelling this system has excluded is never a card**, and
             -- the test survives the redaction of every row that produced it
             -- (0326). `excluded_reason` is still consulted below for a term
             -- marked but not yet recorded here.
             when exists (
               select 1 from semantic_private.excluded_term_keys k
                where k.label_key = md5(lower(btrim(pe.normalized_label))))
               then false

             when exists (
               select 1 from semantic_private.presumed_terms pt
                where pt.normalized_label = pe.normalized_label
                  and pt.excluded_reason is not null)
               then false

             -- A variant defers to its canonical (0302). Matched on the
             -- identity alone now that `0317` links across families: a row
             -- pointing at a canonical in another family is still a variant.
             when exists (
               select 1 from semantic_private.presumed_terms pt
                where pt.normalized_label = pe.normalized_label
                  and pt.family = pe.family
                  and pt.canonical_term_id is not null)
               then false

             -- **A stub is not a card.** Nothing named this term; it exists
             -- because something else was said to relate to it.
             when exists (
               select 1 from semantic_private.presumed_terms pt
                where pt.normalized_label = pe.normalized_label
                  and pt.family = pe.family
                  and pt.origin = 'inferred')
               then false

             -- **A character's card is its franchise.** One hop, to a
             -- franchise that is not an axis and is not itself a stub.
             when exists (
               select 1
                 from semantic_private.presumed_terms pt
                 join semantic_private.presumed_term_relations rel
                   on rel.subject_term_id = coalesce(pt.canonical_term_id, pt.id)
                 join semantic_private.presumed_terms parent
                   on parent.id = rel.object_term_id
                where pt.normalized_label = pe.normalized_label
                  and pt.family = pe.family
                  and rel.predicate = 'part_of_franchise'
                  and parent.family = 'franchise'
                  and parent.origin = 'extracted'
                  and parent.canonical_term_id is null
                  and parent.id <> coalesce(pt.canonical_term_id, pt.id)
                  -- **Not an axis**, folding hyphens and underscores on both
                  -- sides: the dictionary keys `k-pop` while `genre:k_pop`
                  -- carries `k pop`, and that one character was the whole of
                  -- why the corpus's largest container read as a franchise.
                  and not exists (
                    select 1
                      from ontology.concepts c
                      join ontology.concept_labels cl on cl.concept_id = c.id
                     where translate(lower(btrim(cl.normalized_label)), '-_', '  ')
                           = translate(parent.normalized_label, '-_', '  ')
                       and c.concept_key ~ '^(genre|era|sphere|scene|hub):'))
               then false

             when pe.family is not null
               then pe.family not in ('work', 'album', 'music_work')
             when utc.concept_id is not null
               then exists (
                 select 1 from ontology.concept_revisions kcr
                  where kcr.concept_id = utc.concept_id
                    and kcr.ontology_version_id =
                        (select id from ontology.versions where status = 'published')
                    and kcr.concept_kind <> 'work')
             else false
           end
      from semantic_private.user_term_candidates utc
      left join semantic_private.provisional_entities pe
        on pe.id = utc.provisional_entity_id
     where utc.id = p_candidate_id), false)
$function$;

do $$
declare
  body text;
  leaked integer;
begin
  select pg_get_functiondef(p.oid) into body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private' and p.proname = 'review_item_is_coarse';

  if body not like '%excluded_term_keys%' then
    raise exception '0326: the durable exclusion branch is not there';
  end if;
  if body not like '%excluded_reason is not null%' then
    raise exception '0326: 0324''s exclusion branch is gone';
  end if;
  if body not like '%canonical_term_id is not null%' then
    raise exception '0326: the variant branch is gone';
  end if;
  if body not like '%origin = ''inferred''%' then
    raise exception '0326: the stub branch is gone';
  end if;
  if body not like '%part_of_franchise%' then
    raise exception '0326: the franchise branch is gone';
  end if;
  if body not like '%music_work%' then
    raise exception '0326: the granular-family branch is gone';
  end if;
  if body not like '%(genre|era|sphere|scene|hub):%' then
    raise exception '0326: the axis exclusion is gone';
  end if;

  -- **The behaviour, not the text.** Every candidate whose spelling this
  -- system has excluded must now be refused — which is exactly what was untrue
  -- five minutes ago, and a text check would not have noticed.
  select count(*) into leaked
    from semantic_private.user_term_candidates utc
    join semantic_private.provisional_entities pe on pe.id = utc.provisional_entity_id
    join semantic_private.excluded_term_keys k
      on k.label_key = md5(lower(btrim(pe.normalized_label)))
   where semantic_private.review_item_is_coarse(utc.id);
  if leaked > 0 then
    raise exception
      '0326: % candidates name an excluded spelling and are still drawn', leaked;
  end if;

  raise notice '0326: the exclusion outlives the redaction';
end;
$$;
