-- Let voice memos through Storage's door.
--
-- `0010` created `chat-media` with an explicit `allowed_mime_types` list —
-- images and video — because an allow-list is the right shape for a bucket
-- anybody in a conversation can write to. Audio was simply not a thing the app
-- sent yet, so it was not on it, and a memo upload is refused by Storage before
-- any policy is consulted:
--
--     mime type audio/mp4 is not supported
--
-- **A second `insert … on conflict do nothing` cannot fix this.** That is how
-- `0010` writes the row, so re-running it is a no-op and the list would stay as
-- it was. The bucket already exists; the list has to be updated in place.

update storage.buckets
   set allowed_mime_types = array[
        'image/jpeg', 'image/png', 'image/heic',
        'video/mp4', 'video/quicktime',
        -- `audio/mp4` is what `MediaService.uploadVoice` sends: AAC in an m4a
        -- container, which is a registered type. `audio/x-m4a` is here as well
        -- because it is what some tooling labels the same file, and a bucket
        -- that accepts the bytes but not the label is the failure this
        -- migration exists to remove.
        'audio/mp4', 'audio/x-m4a'
   ]
 where id = 'chat-media';

-- Deliberately still an allow-list rather than `null`, which would accept
-- anything. Whoever adds the next kind of attachment has to come here and say
-- so — the same reasoning as `0011` widening `attachment_kind` rather than
-- dropping its check.
