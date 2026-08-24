-- 0327 — the raw archive is erasable by its owner and by nobody else.
--
-- **A static check cannot see who a delete reaches.** `api.forget_raw_archives`
-- is a `security definer` function that deletes storage objects, which is the
-- most dangerous shape in this schema: run as the owner, filtered by a value it
-- computes itself. The only thing that establishes it deletes *one* account's
-- objects is putting two accounts' objects in front of it.
--
-- This is also the half of the erasure that would be easiest to leave broken.
-- *"A deletion control names both schemas or it is not finished"* was written
-- when *Disconnect all* emptied four tables and named none of the ones Memories
-- reads. The archive is a third place, and a function that quietly deleted
-- nothing would look exactly like one that worked.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice  uuid := '00000000-0000-4000-8000-00000000a11c';
  bob    uuid := '00000000-0000-4000-8000-00000000b0b0';
  swept  bigint;
  left_over integer;
  raised boolean;
begin
  insert into auth.users (id, email) values
    (alice, 'alice-0327@example.invalid'),
    (bob,   'bob-0327@example.invalid')
  on conflict (id) do nothing;

  -- Two accounts, two objects each, in the shape the device writes:
  -- `<user_id>/<source>__<endpoint>__<stamp>.json.gz`.
  insert into storage.objects (bucket_id, name, owner_id)
  values
    ('raw-source-archives', alice::text || '/apple_music__library__1.json.gz', alice::text),
    ('raw-source-archives', alice::text || '/youtube__liked__2.json.gz',        alice::text),
    ('raw-source-archives', bob::text   || '/apple_music__library__3.json.gz',  bob::text),
    ('raw-source-archives', bob::text   || '/youtube__liked__4.json.gz',        bob::text)
  on conflict do nothing;

  -- -----------------------------------------------------------------------
  -- An anonymous caller is refused rather than deleting everything
  -- -----------------------------------------------------------------------
  --
  -- `auth.uid()` is null with no claim set, and a filter of
  -- `foldername(name)[1] = null::text` matches no rows — so the function would
  -- "succeed" having deleted nothing. **Refusing loudly is the difference
  -- between a no-op and a silent one**, and a caller that believes an erasure
  -- happened is the failure this whole area is about.
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  raised := false;
  begin
    perform api.forget_raw_archives();
  exception when others then
    raised := true;
  end;
  if not raised then
    raise exception '0327: an anonymous caller was not refused';
  end if;

  -- -----------------------------------------------------------------------
  -- Alice erases Alice, and only Alice
  -- -----------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', alice::text, true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', alice)::text, true);

  select api.forget_raw_archives() into swept;
  if swept <> 2 then
    raise exception '0327: expected 2 of Alice''s objects erased, got %', swept;
  end if;

  select count(*) into left_over from storage.objects
   where bucket_id = 'raw-source-archives'
     and (storage.foldername(name))[1] = alice::text;
  if left_over <> 0 then
    raise exception '0327: % of Alice''s objects survived her own erasure', left_over;
  end if;

  -- **The property that matters, and the one a single-account test cannot
  -- state.** A filter that was subtly wrong — the second path segment, a
  -- `like` on the wrong side — would pass everything above and take Bob's
  -- archive with it.
  select count(*) into left_over from storage.objects
   where bucket_id = 'raw-source-archives'
     and (storage.foldername(name))[1] = bob::text;
  if left_over <> 2 then
    raise exception
      '0327: Alice''s erasure left % of Bob''s objects instead of 2', left_over;
  end if;

  -- -----------------------------------------------------------------------
  -- A second erasure is not an error
  -- -----------------------------------------------------------------------
  --
  -- *Disconnect all* and account deletion can both run, in either order, and
  -- the second must not fail because the first already ran. Zero is a correct
  -- answer here in a way it is not above.
  select api.forget_raw_archives() into swept;
  if swept <> 0 then
    raise exception '0327: a repeat erasure reported % rather than 0', swept;
  end if;

  -- -----------------------------------------------------------------------
  -- YouTube's thirty days reach the bucket
  -- -----------------------------------------------------------------------
  --
  -- A raw YouTube body is Authorized Data under III.E.4, and the sweep is what
  -- makes the retention claim true rather than intended. Asserted with an aged
  -- object and a fresh one, so a sweep that deleted everything would fail here
  -- exactly as one that deleted nothing does.
  insert into storage.objects (bucket_id, name, owner_id, created_at)
  values
    ('raw-source-archives', bob::text || '/youtube__old__5.json.gz',
     bob::text, now() - interval '31 days'),
    ('raw-source-archives', bob::text || '/youtube__new__6.json.gz',
     bob::text, now() - interval '29 days'),
    -- Apple Music has no such clause and must survive at any age.
    ('raw-source-archives', bob::text || '/apple_music__old__7.json.gz',
     bob::text, now() - interval '400 days')
  on conflict do nothing;

  select public.sweep_youtube_raw_archives() into swept;
  if swept <> 1 then
    raise exception
      '0327: the sweep took % objects; it should take exactly the aged YouTube one',
      swept;
  end if;

  perform 1 from storage.objects
   where bucket_id = 'raw-source-archives'
     and name = bob::text || '/youtube__new__6.json.gz';
  if not found then
    raise exception '0327: the sweep took a YouTube object inside thirty days';
  end if;

  perform 1 from storage.objects
   where bucket_id = 'raw-source-archives'
     and name = bob::text || '/apple_music__old__7.json.gz';
  if not found then
    raise exception
      '0327: the sweep took an Apple Music object, which has no retention clause';
  end if;

  raise notice '0327: the archive is erasable by its owner, swept for YouTube, '
               'and untouched for everybody else';
end;
$$;

rollback;
