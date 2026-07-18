-- The phone-remote's `beforeunload` handler previously did `await kvGet` then
-- `await kvSet` to mark remoteConnected=false when the tab closed — browsers
-- don't wait for async beforeunload handlers, so the page unloads before
-- either request completes; the flag was essentially never actually cleared
-- this way. The client now fires a `fetch(..., { keepalive: true })` call to
-- this RPC instead, which the browser is specifically designed to let
-- complete after the page starts unloading.
--
-- A dedicated single-field RPC (rather than a raw REST PATCH) because the
-- client has no synchronous access to the rest of the `config` JSON to send
-- back without clobbering it, and there's no time for a read-then-write
-- round trip during unload.

begin;

create or replace function public.set_remote_disconnected(p_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.rooms
  set config = jsonb_set(coalesce(config, '{}'::jsonb), '{remoteConnected}', 'false'::jsonb),
      updated_at = now()
  where code = p_code;
end;
$$;

revoke all on function public.set_remote_disconnected(text) from public;
grant execute on function public.set_remote_disconnected(text) to anon, authenticated;

commit;
