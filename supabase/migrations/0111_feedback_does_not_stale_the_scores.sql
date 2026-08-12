-- 0111 — answering a claim must not empty the page.
--
-- **Reported as "why did the data section disappear from the Memories page".**
-- Measured: the account on the device had state revision 10 against a newest
-- semantic run computed at 9, and `api.list_assertions` requires
-- `score_run.input_revision = user_state.revision` for every inferred
-- assertion. So it correctly withheld all of them, and the card went blank.
--
-- **What moved the revision was the suppression itself.**
-- `feedback_event_bump_semantic_revision` fires on every insert into
-- `feedback_events`, so the act of answering one claim invalidated every score
-- the person had — a page that empties the moment somebody uses it.
--
-- **The fix is not to enqueue a re-score after feedback**, which was the
-- obvious move and is wrong twice over. It would re-resolve thousands of
-- mappings to produce identical numbers, because the scorer does not read
-- `assertion_preferences` at all; and it would do that once per tap, so
-- confirming ten rows would queue ten full recomputations of the same answer.
--
-- **The revision means "the state the scores were computed against", and an
-- opinion is not one of the scorer's inputs.** Confirming, suppressing and
-- restoring change `display_state` — which of the same scores a person wants
-- shown — and change no evidence. `explicit_add` is different in kind: it
-- creates a `user_term` and an assertion that did not exist, which genuinely is
-- new state, so it keeps the bump.
--
-- That is the same distinction `0104` drew for ingestion runs, one table over:
-- a write that changes no input must not invalidate everything derived from
-- the inputs. Both were the same trigger firing on an event that looked like a
-- change and was not.
--
-- A `when` clause on the trigger rather than a test inside
-- `bump_user_state_revision`: that function is shared by seven triggers across
-- six tables, and teaching it the vocabulary of one of them would put
-- `feedback_events`' action names inside a function that also fires for
-- `source_coverage`.

begin;

drop trigger if exists feedback_event_bump_semantic_revision
  on semantic_private.feedback_events;

create trigger feedback_event_bump_semantic_revision
after insert on semantic_private.feedback_events
for each row
when (new.action = 'explicit_add')
execute function semantic_private.bump_user_state_revision();

-- **Asserted from the catalog, and the behavioural proof is the device.**
--
-- A probe that wrote a feedback event by hand was tried first and abandoned
-- after four rounds, each teaching one more requirement: an exposure needs a
-- score version, the score must be the *current* one, the exposure must carry
-- the score's ontology version, and then the feedback event must faithfully
-- match all of it. Those guards are right and the probe was the wrong tool —
-- the app reaches them through `api.confirm_assertion`, which copies the
-- exposure's fields itself and needs an `auth.uid()` no migration has.
--
-- So this asserts the one thing that changed, which is structural rather than
-- behavioural: the trigger fires for `explicit_add` and for nothing else. The
-- function it calls is untouched, and `0104` already proves that function's
-- other exemption behaviourally.
--
-- The real check is a person confirming a row on a device and the revision not
-- moving, which is how the defect was found in the first place.
do $$
declare
  definition text;
begin
  select pg_get_triggerdef(t.oid) into definition
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal
     and c.relname = 'feedback_events'
     and t.tgname = 'feedback_event_bump_semantic_revision';

  if definition is null then
    raise exception 'the feedback revision trigger is missing';
  end if;
  if definition not like '%WHEN ((new.action = ''explicit_add''::text))%' then
    raise exception
      'the trigger fires for more than explicit_add: %', definition;
  end if;
end
$$;

commit;
