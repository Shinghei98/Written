-- 0175 — a term that resolved to nothing left no trace.
--
-- ## The measurement, and why it is the bottom line
--
-- Resolution rate per source, both real accounts, 2026-08-14:
--
-- | source | observations | mapped | |
-- |---|---|---|---|
-- | `music_library` | 320 | 320 | **100%** |
-- | `youtube` | 1,303 | 1,159 | **89%** |
-- | `apple_music` | 3,267 | 1,099 | 34% |
-- | `spotify` | 1,500 | 81 | **5%** |
-- | `apple_calendar` | 1,046 | 0 | 0% |
-- | `google_calendar` | 151 | 0 | 0% |
-- | `outlook_calendar` | 177 | 0 | 0% |
--
-- **The spread is not about how good each source is. It is about who owns the
-- vocabulary.** YouTube resolves at 89% because it is read through the
-- platform's own labels — `topicDetails.topicCategories`, a controlled tag
-- vocabulary, `categoryId`. `music_library` resolves at 100% because the device
-- states a genre on every row. Spotify resolves at 5% because it states no genre
-- at all, so every row depends on a curated list containing a proper noun — and
-- that list is one person's Apple Music library.
--
-- So: **the system generalises exactly where it reads what the source says, and
-- overfits exactly where it requires a hand-authored list to already contain the
-- answer.** A new user whose artists nobody has typed in is invisible, and
-- nothing anywhere reports that.
--
-- ## What this migration changes
--
-- Nothing about matching. It grants the one privilege that makes the gap
-- *observable*, which is the precondition for every way of closing it.
--
-- `exact_terms_only` (`aws/worker/resolve.py`) discards every term absent from
-- `graph.aliases` before the mapper sees it, and the only trace is the integer
-- `counts['no_exact_alias']` — 2,881 on one run. The strings themselves are
-- computed and thrown away, so:
--
-- * nobody can answer *which* terms are missing, only how many;
-- * `EmergentTermMiner` cannot run even once it is wired, because its input is
--   exactly this stream;
-- * `resolve.py`'s own docstring — *"unresolved terms are emitted anyway, and
--   that is the point of emitting them"* — and the 0.02 incidental-performer
--   weight that exists "so the term still exists for `EmergentTermMiner`" are
--   both paying for something that is deleted 800 lines later.
--
-- `semantic_private.observation_mentions` is the table designed for this. It has
-- existed since `0042`, carries a partial index built for exactly this query
-- (`observation_mentions_normalized_idx ... where safe_for_global_mining`), and
-- **has never had a single row**. `semantic_worker` holds no privilege on it at
-- all — so the gap is not merely unwired, the identity that would write it
-- cannot.
--
-- ## Which sources may be written, and why the list is short
--
-- A mention is a raw string lifted out of somebody's library, so the question is
-- not "is it useful" but "is storing it a disclosure we have not already made".
--
-- **Permitted — `apple_music`, `music_library`, `apple_podcasts`, `podcast`.**
-- The string is public catalogue metadata that is *already* in
-- `observations.normalized_payload`; this table indexes what is stored rather
-- than storing anything new, and none of these four carries a term restricting
-- downstream use.
--
-- **Refused — `spotify`.** IV.2.1.a forbids ingesting Spotify Content into an
-- ML/AI model, and IV.2.5 says a user's consent does not cure it. Deriving
-- vocabulary from Spotify strings is that, whoever benefits. **This is the
-- uncomfortable one**: Spotify is the source with the worst coverage and the one
-- that most needs the vocabulary grown, and it is the one that may not feed it.
-- Its route is catalogue identity instead — `0173` — which reads a catalogue and
-- discards, rather than learning from Content.
--
-- **Refused — `youtube`.** III.E.4 requires titles and creator names deleted or
-- refreshed within 30 days, and `sweep_youtube_vault_retention` covers
-- `observations` and `raw_source_records`. A mentions row would be a copy of the
-- same strings *outside* the sweep, which is how a retention obligation stops
-- being true without anybody deciding to break it.
--
-- **Refused — every calendar.** Titles never reach the vault at all: the stored
-- payload is at most four keys and a test asserts no fragment of a title,
-- address, organiser or email domain survives into it. There is nothing here to
-- index, and a table that could hold one is exactly what that design refuses.
--
-- The gate is enforced in `resolve.py` and asserted below from the catalog, so a
-- source added later is refused by default rather than permitted by omission —
-- the failure mode of a deny-list is silence, and this is an allow-list.
--
-- **`safe_for_global_mining` stays `false` on every row this writes.** That flag
-- is `EmergentTermMiner`'s own gate and turning it on is a separate decision
-- with a five-user privacy floor behind it. Recording a term and licensing its
-- promotion are two acts, and this migration is only the first.

begin;

grant select, insert on table semantic_private.observation_mentions to semantic_worker;

do $$
declare
  granted boolean;
begin
  -- Asked of the catalog rather than trusted to the statement above:
  -- `information_schema.table_privileges` answers only for the querying role,
  -- and `semantic_worker` is `bypassrls`, which is not a grant.
  select has_table_privilege('semantic_worker', 'semantic_private.observation_mentions', 'insert')
    into granted;
  if not granted then
    raise exception '0175: semantic_worker still cannot record a mention';
  end if;

  -- And the identity that must not have gained it. `semantic_ingestor` can call
  -- exactly one function and holds zero table privileges; leaked, it writes
  -- vault rows and reads none back. A mentions table it could read would be a
  -- plaintext index of everybody's library.
  select has_table_privilege('semantic_ingestor', 'semantic_private.observation_mentions', 'select')
    into granted;
  if granted then
    raise exception '0175: semantic_ingestor was granted a read it must not have';
  end if;

  select has_table_privilege('semantic_ingestor', 'semantic_private.observation_mentions', 'insert')
    into granted;
  if granted then
    raise exception '0175: semantic_ingestor was granted a write it must not have';
  end if;
end;
$$;

commit;
