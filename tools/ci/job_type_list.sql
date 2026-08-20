-- The job types the database will accept, one per line, sorted.
--
-- Read from the check constraint rather than typed, because this exists to be
-- compared against two other registries — `job_contracts.py` and the worker's
-- handler map — and a list retyped here could only ever agree with itself.
select string_agg(t, ',' order by t)
  from (
    select btrim(unnest(string_to_array(
             replace(replace(substring(pg_get_constraintdef(c.oid)
                                       from 'ARRAY\[(.*)\]'),
                             '::text', ''), ' ', ''),
             ',')), '''') as t
      from pg_constraint c
      join pg_class rel on rel.oid = c.conrelid
      join pg_namespace n on n.oid = rel.relnamespace
     where n.nspname = 'semantic_private'
       and rel.relname = 'worker_jobs'
       and c.conname = 'worker_jobs_job_type_v03_check'
  ) as parsed;
