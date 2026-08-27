-- 0418 — an unearned wire is a candidate, not a conductor.
--
-- **The audit's final form (owner's doctrine, GRAMMARBOOK 2.22, applied
-- with its own polarity):** an ungrounded relation edge is PROMOTED to
-- conduction by corroboration; absence of corroboration is not
-- refutation, but it is absence of earned trust, and an edge that never
-- earned conduction does not conduct. The refined audit's verdicts over
-- all 491 promotion-lane edges: 328 grounded (the entry is the witness
-- — active), 21 corroborated (the catalogue is the witness — active),
-- 21 whose witnesses the audit never found (untouched), and these
-- 120 ungrounded-uncorroborated wires — 10 checked-and-
-- unconnected, 100 identity-ambiguous, 10 unverifiable — which demote
-- to `candidate`: identity minted, conduction unearned, re-promotable
-- the day a check corroborates them. Lyn -> Persona 5 stands grounded;
-- Lyn -> One Piece goes cold, and Timi's One Piece with it.
--
-- Ends with the recompute enqueue.

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  cooled integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Unearned relation wires demote to candidate.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- The audit recorded the OLD version's edge ids; the copy-forward gave
  -- each a twin at the new version, matched by its triple.
  update ontology.concept_edges e
     set status = 'candidate',
         provenance = coalesce(e.provenance, '{}'::jsonb)
           || jsonb_build_object('demoted_by', '0418',
                'reason', 'ungrounded_uncorroborated')
    from ontology.concept_edges old_e
   where old_e.id in (
    'b8b07c37-df66-4b0f-8fc0-9abd7f407b4f'::uuid,
    'cb4c3941-24fa-49f2-bcd1-57525e2b0c23'::uuid,
    '32888e91-a528-44a5-97aa-137eb759ec50'::uuid,
    '25e3d1a2-88d1-4d52-9ef9-ed4bd21a05fd'::uuid,
    '083971da-9bd4-4271-a6c6-f6709c427f65'::uuid,
    'fa507870-8494-4b81-924e-55606e83a0b2'::uuid,
    '4ee1ebce-4afb-427e-82a2-101a518f1d64'::uuid,
    '78e57a00-bb59-49be-9f10-944a9d50d2a5'::uuid,
    '6bde3fcb-9ba3-424c-87d7-67968245a556'::uuid,
    'e0d1c61c-2980-463d-868a-199ecb57b45b'::uuid,
    '63f111fe-846c-4d30-8b42-a86e32bee113'::uuid,
    'b6e89599-7c08-463c-b137-1021405dad95'::uuid,
    '93b4ffd8-2952-4e30-94d9-822924702d61'::uuid,
    'be5e8ae2-5a29-4f22-ae16-e3e635260ce3'::uuid,
    'bd74a522-9109-4764-ad05-58ef4263b83e'::uuid,
    '5cccd97a-5f3e-48b2-86c9-2da1a215a67f'::uuid,
    '95c57e33-4891-4a5f-9708-816f0eb3d7c3'::uuid,
    'a5bd7413-25ce-4270-aca9-2c164fc15baa'::uuid,
    '60cbbe75-04ee-4c42-a2bc-1627c7f6578f'::uuid,
    'a699170e-48b4-4117-912e-587de1a4dde0'::uuid,
    '1f624570-d2aa-4a19-9083-595eebc3c607'::uuid,
    '0e454378-3ef5-403e-a774-37be4c1cd6e5'::uuid,
    'ad2a51b1-312c-4901-83e6-6901893e82b1'::uuid,
    'a15db4e1-b4e4-478f-abae-f2bad3080d4a'::uuid,
    '3ff8b292-4d19-4bea-9a4b-5bebdfe1ec89'::uuid,
    'ba00a133-8918-4a6a-80b2-b2260f540477'::uuid,
    '0f50ff58-70ea-4388-ae68-53dd2bda2f0b'::uuid,
    'b6ee2131-b7aa-4290-8fa5-5d9dc4c80ffb'::uuid,
    'd4fb3ffa-05fa-44d7-aa06-5fd23424ec1b'::uuid,
    'e6bdc334-d849-4f77-9c40-43ac031e2c74'::uuid,
    'a9505cc1-2590-4f03-a00a-c370b55e0646'::uuid,
    '920b94be-643c-4c7c-90b7-14bffede269f'::uuid,
    '5334976e-e55b-4796-be1f-386332e1fe8a'::uuid,
    '65d7aa3c-9817-4c24-b748-1da5f19f8a80'::uuid,
    'bb19d0b3-70b5-4f5f-a4ce-979cae786888'::uuid,
    '1f8f3505-8221-4527-ab31-2d5712f1c6b1'::uuid,
    'fa785b2e-df7b-44d7-96ac-9c9fbf03af98'::uuid,
    '14a0e9e5-cc1d-440a-a254-1377f2e33a34'::uuid,
    '66645419-99b6-4637-a9ba-3cfb431f371a'::uuid,
    'e4771fa1-695b-4835-b7df-ae7e8767a7db'::uuid,
    '893ee2ae-76e6-472d-a6b0-6775a61d8205'::uuid,
    '7b64e3af-628f-4797-92f6-1c7728ca7081'::uuid,
    'e9542bec-c2dc-44d1-b9c1-3b6681b5b4e8'::uuid,
    'dbcc796e-f78f-4536-8094-3e5acbb6caf9'::uuid,
    'f1ffc2b4-f358-4376-8365-07b7c4eacbe5'::uuid,
    '91328a50-5b21-4fc0-bd52-000167f3810f'::uuid,
    '6e9e8da6-c919-4ae9-ae8c-b50d44d1258f'::uuid,
    '66e4d026-e10e-457e-8cab-3fc4a60d98ee'::uuid,
    'd287cabd-aed2-4884-801a-39a86c2042e2'::uuid,
    '8737446c-7f0f-4850-bbda-550a98133355'::uuid,
    '4fcd61f4-ccb3-48cf-bdb1-c844cfcb6b66'::uuid,
    'f8099d53-f9c1-4864-8d36-24d01c72f1df'::uuid,
    '3a943e36-6c8a-4ebb-a7ba-268c3f998e26'::uuid,
    '258c9547-6264-4518-83dc-417d52b4847f'::uuid,
    '99a85ed7-2243-4973-831d-712f514d5ec4'::uuid,
    '1ad9eb38-3181-469f-98f4-8f8b35ebf44e'::uuid,
    'c01891e3-d00a-4259-83fb-d4be0254a5bc'::uuid,
    '59daa4db-d4e4-4789-9170-da30b1dc8cf7'::uuid,
    'c286715d-2517-4204-81e2-12fee22d9106'::uuid,
    '62d79096-eca8-4dc2-94ad-935776fb1494'::uuid,
    '9036dcbf-b878-4109-a029-e1bdf37ac6ff'::uuid,
    'aadaa789-4b6a-4d5f-aa33-2b979384c25e'::uuid,
    '5a52a4a1-b757-49f8-8873-17a55ee3bac9'::uuid,
    'c43d6950-6b38-4581-a355-f26eafa08b65'::uuid,
    '3d52b0e7-152c-4f96-9934-c91a53ae5a44'::uuid,
    '3cbf91e6-7af0-4349-9e46-4c10aef64684'::uuid,
    '7f45ba1d-aa09-4ed2-b350-1df41fc9001d'::uuid,
    'ad3eeb01-a256-4721-86f0-5d740bbe09a3'::uuid,
    'b56984c4-248b-4b71-a172-21d54cb0e714'::uuid,
    'e28853c6-b89a-4b93-84ba-b4ad93a4c744'::uuid,
    'b10bec6d-c6d3-4d2f-9247-db60ab78bef1'::uuid,
    '40c8d585-bcba-4876-a7b2-a69dda672149'::uuid,
    'bba5ccaf-84a5-4344-94e2-9b5cb3407575'::uuid,
    'fc2b11e9-e4af-4ec2-812c-67614386b95f'::uuid,
    'aa4f827f-393a-425b-9f6a-00352e1c6ad2'::uuid,
    'b57f31f4-1c3d-40a5-951e-aecf0cb73ac6'::uuid,
    'b84e262d-e96d-48ff-a2ff-1dda2f321df9'::uuid,
    '7bce6571-cd47-4283-8156-1e6d7abb53b9'::uuid,
    'd4753661-f233-438b-88cf-0172ed8647a4'::uuid,
    'c48a0dde-5811-47b0-b548-883f567ad114'::uuid,
    'd55424ee-243c-42cd-9b08-78839b4dbc01'::uuid,
    '5bf05799-423d-40a1-bc86-f92f7cc2b386'::uuid,
    '04b1d6e8-0c4d-45c6-bd7f-4a9229f1b978'::uuid,
    '0c14f706-29e2-40ca-9dc8-e2f1dbce8278'::uuid,
    'f4613e92-0261-41d7-a59a-42f27dc7d718'::uuid,
    '05eab46c-279c-4d61-996b-de838d551698'::uuid,
    'bfcd80e1-b405-4696-b25b-ceb4f6041fa3'::uuid,
    '86800c36-32f5-4dba-b07c-03f63197b671'::uuid,
    'd06a981f-abdd-4867-8f10-5f94599b78dc'::uuid,
    'ff61d998-8ca5-4bd7-b2c8-6c8af4f6f85c'::uuid,
    '7cbbdce0-68e6-4641-bcf9-dd56a4ea4678'::uuid,
    '79a61158-4d4f-405e-9efd-cc2c8ebbbe62'::uuid,
    '1f884675-5c9d-41c2-ace7-e145a359c0a3'::uuid,
    '7409419d-7e5b-4f50-ae3b-f193f1daa234'::uuid,
    'd6cd5a17-39e5-4806-8a48-c3bc0ddb3e03'::uuid,
    'd64381da-3855-4a5e-bb84-0596c8b1e8eb'::uuid,
    'cfe52f17-b88c-489b-841d-e3e92ca29b10'::uuid,
    'e771c768-3a8d-4039-ac3a-0379a981c0cb'::uuid,
    '41dfba55-d4ce-46bc-af22-3d1e9e14c1b1'::uuid,
    'ae567146-f6a1-41c5-a901-8bf8f8849f36'::uuid,
    '6c538ca2-8171-48c9-8efe-c08a00f65ef7'::uuid,
    '49522645-59a7-4608-a0bb-b8613c9473cc'::uuid,
    '6f93df9a-032d-4c46-ae91-1369b48508e7'::uuid,
    '400a8bce-7351-4b34-ac45-5c5cd390796a'::uuid,
    '0785afe6-4c91-4e9c-92f8-62ea385c50c8'::uuid,
    'bf5fe87f-bd7a-4154-930e-bb7408c8b83a'::uuid,
    'a39fed17-9422-4638-950d-26b68c2712a7'::uuid,
    '3135129b-bf8d-4771-80ce-a02a2d45b557'::uuid,
    '9150b953-e066-43d3-8ac5-25c549e59232'::uuid,
    '7896cc59-bafe-4b0a-8cff-244e8d49c9fa'::uuid,
    '9b691e86-685d-40bd-a492-e7d617d37652'::uuid,
    'cc868998-c765-4c80-988f-e676dce3c3c6'::uuid,
    'b195d604-4ab6-44f5-8d60-2470034e609f'::uuid,
    'c6ccb6b5-f90b-48d7-abbc-c9f67450c3d2'::uuid,
    '269f0e66-e798-46a7-ba13-7e580b991687'::uuid,
    '7164b2c5-7d00-44b6-898a-9184a51e541e'::uuid,
    'c255cd1a-126e-456d-81d7-de3a8f789681'::uuid,
    'eaf8c08e-2731-4d5b-b5f1-a5a70817c78b'::uuid,
    '7764632d-8866-46a9-921a-b3fa8c2309bd'::uuid,
    '1ad50b46-e5f1-4e15-9437-900937176c87'::uuid)
     and e.ontology_version_id = new_version_id
     and e.subject_concept_id = old_e.subject_concept_id
     and e.predicate_key = old_e.predicate_key
     and e.object_concept_id = old_e.object_concept_id
     and e.status = 'active';
  get diagnostics cooled = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || cooled
    || ' unearned wire(s) demoted to candidate');
  raise notice '0418: % published — % wires cooled', next_version, cooled;
end;
$$;

commit;
