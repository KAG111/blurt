-- Companion migration to the app-side generateUniqueCode() change: even with
-- the client checking for a free code before creating a room, stale rooms
-- piling up forever shrinks the effectively-free code space over time (and
-- wastes storage). This adds a cleanup function that deletes rooms nobody
-- has touched in a while, keyed off `updated_at` (already bumped by every
-- kvSet / RPC write, so an active room's clock never goes stale).
--
-- Ordinary rooms: deleted after 48 hours untouched.
-- Demo rooms (code LIKE 'DEMO-%', created by the "Try Demo" button and
-- never meant to be a real, shareable room) expire faster: 2 hours.
-- Both rules also cover each type's MOD- moderation-shadow row (code LIKE
-- 'MOD-DEMO-%' / a plain MOD- row alongside its 48h-rule main row) so a
-- deleted room doesn't leave an orphaned shadow row behind.
--
-- Run this in the Supabase SQL Editor after reviewing it.

begin;

create or replace function public.cleanup_expired_rooms()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.rooms
  where (code like 'DEMO-%' or code like 'MOD-DEMO-%')
    and updated_at < now() - interval '2 hours';

  delete from public.rooms
  where not (code like 'DEMO-%' or code like 'MOD-DEMO-%')
    and updated_at < now() - interval '48 hours';
end;
$$;

-- Not granted to anon/authenticated: this is an admin/maintenance
-- operation, never something a room participant's browser should be able
-- to trigger over PostgREST.
revoke all on function public.cleanup_expired_rooms() from public;

-- Best-effort: schedule it with pg_cron if that extension is enabled on
-- this project. If it isn't, this silently does nothing rather than
-- failing the migration — see the manual-step note below.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'cleanup_expired_rooms',
      '0 * * * *',
      $cron$select public.cleanup_expired_rooms();$cron$
    );
  end if;
end $$;

commit;

-- ---------------------------------------------------------------------------
-- MANUAL STEP — only needed if the do-block above couldn't schedule it
-- (pg_cron not installed/enabled on this project):
--
--   1. In the Supabase dashboard: Database -> Extensions -> enable "pg_cron".
--   2. Then in the SQL Editor, run:
--        select cron.schedule('cleanup_expired_rooms', '0 * * * *',
--          'select public.cleanup_expired_rooms();');
--
-- If pg_cron isn't available on your plan at all, call
-- `select public.cleanup_expired_rooms();` periodically some other way
-- (e.g. a Supabase Edge Function on a cron trigger, or a scheduled GitHub
-- Action hitting it via the SQL connection) — the function itself has no
-- pg_cron dependency, only the automatic scheduling above does.
--
-- Verify after running:
--   select cron.job from cron.jobs where jobname = 'cleanup_expired_rooms';
--   -- (only if pg_cron is enabled — table lives in the cron extension)
-- ---------------------------------------------------------------------------
