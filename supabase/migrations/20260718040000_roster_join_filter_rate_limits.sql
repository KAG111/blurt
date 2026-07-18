-- Three server-side hardening gaps left after the atomic-mutation round
-- (20260718010000 / 20260718020000 / 20260718030000):
--
-- 1. ATOMIC ROSTER JOIN — the nickname join in renderStudentNamePrompt's
--    proceed() still did read-roster -> check-taken -> push -> write-roster
--    client-side, the same race append_pending_item/submit_word/etc. were
--    built to fix for other columns. Thirty students scanning a QR code at
--    once can silently clobber each other's roster writes; a lost name also
--    silently drops that student from the final leaderboard, since results
--    are filtered to roster membership. join_roster() below moves this
--    server-side under a row lock, the same shape as submit_word/append_post.
--
-- 2. SERVER-SIDE CONTENT FILTER — the BAD_WORDS list lived only in the
--    client's isClean(), which (a) ships the slur list in view-source for
--    any student to read, and (b) does nothing at all against a direct RPC
--    call that skips the browser entirely. contains_blocked_word() below is
--    a private helper (never granted to anon/authenticated — cannot be
--    called via PostgREST, only from other SECURITY DEFINER functions in
--    this file) that the write RPCs now check before accepting free text.
--
-- 3. RATE LIMITING — every write RPC is callable by anyone holding the
--    public anon key. check_rate_limit() below is a small internal helper
--    backed by a new rate_limits table (one row per room/session/action,
--    sliding-ish fixed window) that each write RPC consults before doing
--    its real work. A per-room hard ceiling on array length backstops
--    against runaway growth even from many distinct sessions.
--
-- Because several existing RPCs (submit_word, append_post, increment_votes,
-- append_ranking, like_post, record_student_response, append_pending_item)
-- need to start RETURNING a status ('ok' / 'blocked_word' / 'rate_limited'
-- / 'room_full') instead of void, and some need a new p_session_id
-- parameter, they can't all be updated with plain CREATE OR REPLACE
-- (Postgres won't let OR REPLACE change a return type, and adding a
-- parameter changes the signature) — this migration explicitly DROPs each
-- one first. Room-not-found stays an exception exactly as before for all
-- of these (unchanged client behaviour); only join_roster returns
-- 'room_not_found' as a normal status, per the spec below.
--
-- Run this in the Supabase SQL Editor after reviewing it.

begin;

-- ---------------------------------------------------------------------------
-- 0. Internal helpers — neither is granted to anon/authenticated, so
-- neither is callable via PostgREST (only from other SECURITY DEFINER
-- functions in this schema, which run as the owner regardless of the
-- calling client's own grants).
-- ---------------------------------------------------------------------------

-- Mirrors the word list that used to live in the client's isClean(). Kept
-- as simple case-insensitive substring matches, same as the JS version.
create or replace function public.contains_blocked_word(p_text text)
returns boolean
language sql
immutable
as $$
  select p_text is not null and (
    lower(p_text) like '%fuck%'    or
    lower(p_text) like '%shit%'    or
    lower(p_text) like '%cunt%'    or
    lower(p_text) like '%bitch%'   or
    lower(p_text) like '%asshole%' or
    lower(p_text) like '%dick%'    or
    lower(p_text) like '%pussy%'   or
    lower(p_text) like '%nigger%'  or
    lower(p_text) like '%faggot%'  or
    lower(p_text) like '%whore%'   or
    lower(p_text) like '%slut%'
  );
$$;

revoke all on function public.contains_blocked_word(text) from public;

create table if not exists public.rate_limits (
  room_code    text        not null,
  session_key  text        not null,
  action       text        not null,
  window_start timestamptz not null default now(),
  count        int         not null default 0,
  primary key (room_code, session_key, action)
);

alter table public.rate_limits enable row level security;
-- No policies granted at all: this table is only ever touched by
-- SECURITY DEFINER functions (which bypass RLS as the owning role), never
-- directly by anon/authenticated over PostgREST. RLS being enabled with
-- zero policies means even an accidental future grant on this table
-- defaults to "nobody can see or touch it".

-- Returns true if the caller is still within (p_max) actions per
-- (p_window_seconds) for this (room, session, action) combo, and records
-- the attempt either way. Fixed-window (not sliding): a burst right at a
-- window boundary can momentarily allow closer to 2x p_max, which is an
-- acceptable trade for a single upsert with no extra round trip.
create or replace function public.check_rate_limit(
  p_code text,
  p_session_key text,
  p_action text,
  p_max int,
  p_window_seconds int
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  new_count int;
begin
  -- Opportunistic cleanup of long-stale rows so this table doesn't grow
  -- forever — piggybacks on normal write traffic, no cron needed.
  delete from public.rate_limits
  where window_start < now() - interval '1 hour';

  insert into public.rate_limits as rl (room_code, session_key, action, window_start, count)
  values (p_code, coalesce(p_session_key, ''), p_action, now(), 1)
  on conflict (room_code, session_key, action) do update
    set count = case
          when rl.window_start < now() - make_interval(secs => p_window_seconds) then 1
          else rl.count + 1
        end,
        window_start = case
          when rl.window_start < now() - make_interval(secs => p_window_seconds) then now()
          else rl.window_start
        end
  returning count into new_count;

  return new_count <= p_max;
end;
$$;

revoke all on function public.check_rate_limit(text, text, text, int, int) from public;

-- ---------------------------------------------------------------------------
-- 1. Atomic roster join.
-- ---------------------------------------------------------------------------
create or replace function public.join_roster(
  p_code text,
  p_name text,
  p_session_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := trim(both from p_name);
  current_roster jsonb;
  i int;
  affected int;
begin
  if clean_name = '' then
    return 'blocked_word'; -- empty name after trim: treat like any other rejected input
  end if;

  if not public.check_rate_limit(p_code, coalesce(p_session_id, clean_name), 'join_roster', 3, 30) then
    return 'rate_limited';
  end if;

  if public.contains_blocked_word(clean_name) then
    return 'blocked_word';
  end if;

  select roster into current_roster from public.rooms where code = p_code for update;
  if not found then
    return 'room_not_found';
  end if;

  current_roster := coalesce(current_roster, '[]'::jsonb);
  if jsonb_typeof(current_roster) <> 'array' then
    current_roster := '[]'::jsonb;
  end if;

  for i in 0 .. jsonb_array_length(current_roster) - 1 loop
    if lower(trim(both from (current_roster ->> i))) = lower(clean_name) then
      return 'taken';
    end if;
  end loop;

  update public.rooms
  set roster = current_roster || jsonb_build_array(clean_name),
      updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    return 'room_not_found';
  end if;

  return 'ok';
end;
$$;

revoke all on function public.join_roster(text, text, text) from public;
grant execute on function public.join_roster(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2 & 3. Re-create the existing write RPCs with content filtering and rate
-- limiting folded in, and a text status return instead of void.
-- ---------------------------------------------------------------------------

drop function if exists public.submit_word(text, text);
create or replace function public.submit_word(
  p_code text,
  p_text text,
  p_session_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  current_words jsonb;
  i int;
  found_idx int := null;
  existing_count int;
  affected int;
begin
  if not public.check_rate_limit(p_code, p_session_id, 'submit_word', 10, 30) then
    return 'rate_limited';
  end if;

  if public.contains_blocked_word(p_text) then
    return 'blocked_word';
  end if;

  select words into current_words from public.rooms where code = p_code for update;
  if not found then
    raise exception 'submit_word: room % not found', p_code;
  end if;

  current_words := coalesce(current_words, '[]'::jsonb);
  if jsonb_typeof(current_words) <> 'array' then
    current_words := '[]'::jsonb;
  end if;

  for i in 0 .. jsonb_array_length(current_words) - 1 loop
    if lower(current_words -> i ->> 'text') = lower(p_text) then
      found_idx := i;
      exit;
    end if;
  end loop;

  if found_idx is not null then
    existing_count := coalesce((current_words -> found_idx ->> 'count')::int, 0);
    current_words := jsonb_set(current_words, array[found_idx::text, 'count'], to_jsonb(existing_count + 1));
  else
    if jsonb_array_length(current_words) >= 500 then
      return 'room_full';
    end if;
    current_words := current_words || jsonb_build_array(jsonb_build_object('text', p_text, 'count', 1));
  end if;

  update public.rooms
  set words = current_words, updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'submit_word: room % not found on write', p_code;
  end if;

  return 'ok';
end;
$$;

revoke all on function public.submit_word(text, text, text) from public;
grant execute on function public.submit_word(text, text, text) to anon, authenticated;

drop function if exists public.append_post(text, jsonb, boolean);
create or replace function public.append_post(
  p_code text,
  p_post jsonb,
  p_dedupe boolean default true
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  current_posts jsonb;
  i int;
  found_idx int := null;
  post_text text := p_post ->> 'text';
  session_key text := coalesce(p_post ->> 'sessionId', '');
  existing_count int;
  merged_owners jsonb;
  affected int;
begin
  if not public.check_rate_limit(p_code, session_key, 'append_post', 10, 30) then
    return 'rate_limited';
  end if;

  if public.contains_blocked_word(post_text) then
    return 'blocked_word';
  end if;

  select posts into current_posts from public.rooms where code = p_code for update;
  if not found then
    raise exception 'append_post: room % not found', p_code;
  end if;

  current_posts := coalesce(current_posts, '[]'::jsonb);
  if jsonb_typeof(current_posts) <> 'array' then
    current_posts := '[]'::jsonb;
  end if;

  if p_dedupe and post_text is not null and post_text <> '' then
    for i in 0 .. jsonb_array_length(current_posts) - 1 loop
      if lower(current_posts -> i ->> 'text') = lower(post_text) then
        found_idx := i;
        exit;
      end if;
    end loop;
  end if;

  if found_idx is not null then
    existing_count := coalesce((current_posts -> found_idx ->> 'count')::int, 1);
    select coalesce(jsonb_agg(distinct value), '[]'::jsonb)
      into merged_owners
      from jsonb_array_elements_text(
        coalesce(current_posts -> found_idx -> 'ownerSessionIds', '[]'::jsonb)
        || coalesce(p_post -> 'ownerSessionIds', '[]'::jsonb)
      ) value;

    current_posts := jsonb_set(current_posts, array[found_idx::text, 'count'], to_jsonb(existing_count + 1));
    current_posts := jsonb_set(current_posts, array[found_idx::text, 'ownerSessionIds'], merged_owners);
  else
    if jsonb_array_length(current_posts) >= 500 then
      return 'room_full';
    end if;
    current_posts := current_posts || jsonb_build_array(p_post);
  end if;

  update public.rooms
  set posts = current_posts, updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'append_post: room % not found on write', p_code;
  end if;

  return 'ok';
end;
$$;

revoke all on function public.append_post(text, jsonb, boolean) from public;
grant execute on function public.append_post(text, jsonb, boolean) to anon, authenticated;

drop function if exists public.increment_votes(text, int, int[]);
create or replace function public.increment_votes(
  p_code text,
  p_qindex int,
  p_option_indices int[],
  p_session_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  current_votes jsonb;
  target jsonb;
  idx int;
  affected int;
begin
  if not public.check_rate_limit(p_code, p_session_id, 'increment_votes', 3, 30) then
    return 'rate_limited';
  end if;

  select votes into current_votes from public.rooms where code = p_code for update;
  if not found then
    raise exception 'increment_votes: room % not found', p_code;
  end if;

  current_votes := coalesce(current_votes, '[]'::jsonb);
  if jsonb_typeof(current_votes) <> 'array' then
    current_votes := '[]'::jsonb;
  end if;

  if p_qindex is null then
    target := current_votes;
  else
    target := current_votes -> p_qindex;
  end if;

  if target is null or jsonb_typeof(target) <> 'array' then
    target := '[]'::jsonb;
  end if;

  foreach idx in array p_option_indices loop
    while jsonb_array_length(target) <= idx loop
      target := target || to_jsonb(0);
    end loop;
    target := jsonb_set(target, array[idx::text], to_jsonb(coalesce((target ->> idx)::int, 0) + 1));
  end loop;

  if p_qindex is null then
    current_votes := target;
  else
    while jsonb_array_length(current_votes) <= p_qindex loop
      current_votes := current_votes || 'null'::jsonb;
    end loop;
    current_votes := jsonb_set(current_votes, array[p_qindex::text], target);
  end if;

  update public.rooms
  set votes = current_votes, updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'increment_votes: room % not found on write', p_code;
  end if;

  return 'ok';
end;
$$;

revoke all on function public.increment_votes(text, int, int[], text) from public;
grant execute on function public.increment_votes(text, int, int[], text) to anon, authenticated;

drop function if exists public.append_ranking(text, jsonb);
create or replace function public.append_ranking(
  p_code text,
  p_ranking jsonb,
  p_session_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  current_votes jsonb;
  affected int;
begin
  if not public.check_rate_limit(p_code, p_session_id, 'append_ranking', 3, 30) then
    return 'rate_limited';
  end if;

  select votes into current_votes from public.rooms where code = p_code for update;
  if not found then
    raise exception 'append_ranking: room % not found', p_code;
  end if;

  current_votes := coalesce(current_votes, '[]'::jsonb);
  if jsonb_typeof(current_votes) <> 'array' then
    current_votes := '[]'::jsonb;
  end if;

  if jsonb_array_length(current_votes) >= 2000 then
    return 'room_full';
  end if;

  update public.rooms
  set votes = current_votes || jsonb_build_array(p_ranking),
      updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'append_ranking: room % not found on write', p_code;
  end if;

  return 'ok';
end;
$$;

revoke all on function public.append_ranking(text, jsonb, text) from public;
grant execute on function public.append_ranking(text, jsonb, text) to anon, authenticated;

drop function if exists public.like_post(text, text);
create or replace function public.like_post(
  p_code text,
  p_post_id text,
  p_session_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  current_posts jsonb;
  i int;
  found_idx int := null;
  existing_likes int;
begin
  if not public.check_rate_limit(p_code, p_session_id, 'like_post', 10, 30) then
    return 'rate_limited';
  end if;

  select posts into current_posts from public.rooms where code = p_code for update;
  if not found then
    raise exception 'like_post: room % not found', p_code;
  end if;

  current_posts := coalesce(current_posts, '[]'::jsonb);
  if jsonb_typeof(current_posts) <> 'array' then
    current_posts := '[]'::jsonb;
  end if;

  for i in 0 .. jsonb_array_length(current_posts) - 1 loop
    if (current_posts -> i ->> 'id') = p_post_id then
      found_idx := i;
      exit;
    end if;
  end loop;

  if found_idx is not null then
    existing_likes := coalesce((current_posts -> found_idx ->> 'likes')::int, 0);
    current_posts := jsonb_set(current_posts, array[found_idx::text, 'likes'], to_jsonb(existing_likes + 1));

    update public.rooms
    set posts = current_posts, updated_at = now()
    where code = p_code;
  end if;

  return 'ok';
end;
$$;

revoke all on function public.like_post(text, text, text) from public;
grant execute on function public.like_post(text, text, text) to anon, authenticated;

drop function if exists public.record_student_response(text, text, int, jsonb);
create or replace function public.record_student_response(
  p_code text,
  p_name text,
  p_qindex int,
  p_selected jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  current_responses jsonb;
  i int;
  found_idx int := null;
  answers jsonb;
  affected int;
begin
  if not public.check_rate_limit(p_code, lower(trim(both from p_name)), 'record_student_response', 3, 30) then
    return 'rate_limited';
  end if;

  select responses into current_responses from public.rooms where code = p_code for update;
  if not found then
    raise exception 'record_student_response: room % not found', p_code;
  end if;

  current_responses := coalesce(current_responses, '[]'::jsonb);
  if jsonb_typeof(current_responses) <> 'array' then
    current_responses := '[]'::jsonb;
  end if;

  for i in 0 .. jsonb_array_length(current_responses) - 1 loop
    if lower(trim(both from (current_responses -> i ->> 'name'))) = lower(trim(both from p_name)) then
      found_idx := i;
      exit;
    end if;
  end loop;

  if found_idx is null then
    current_responses := current_responses || jsonb_build_array(jsonb_build_object('name', p_name, 'answers', '[]'::jsonb));
    found_idx := jsonb_array_length(current_responses) - 1;
  end if;

  answers := coalesce(current_responses -> found_idx -> 'answers', '[]'::jsonb);
  if jsonb_typeof(answers) <> 'array' then
    answers := '[]'::jsonb;
  end if;
  while jsonb_array_length(answers) <= p_qindex loop
    answers := answers || 'null'::jsonb;
  end loop;
  answers := jsonb_set(answers, array[p_qindex::text], p_selected);

  current_responses := jsonb_set(current_responses, array[found_idx::text, 'answers'], answers);

  update public.rooms
  set responses = current_responses, updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'record_student_response: room % not found on write', p_code;
  end if;

  return 'ok';
end;
$$;

revoke all on function public.record_student_response(text, text, int, jsonb) from public;
grant execute on function public.record_student_response(text, text, int, jsonb) to anon, authenticated;

drop function if exists public.append_pending_item(text, text, jsonb);
create or replace function public.append_pending_item(
  p_code text,
  p_column text,
  p_item jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  mod_code text := 'MOD-' || p_code;
  session_key text := coalesce(p_item ->> 'sessionId', '');
  item_text text := p_item ->> 'text';
  current_col jsonb;
  ceiling int;
  affected int;
begin
  if p_column not in ('posts', 'words', 'votes', 'responses') then
    raise exception 'append_pending_item: invalid column %', p_column;
  end if;

  if not public.check_rate_limit(p_code, session_key, 'append_pending_item_' || p_column,
       case when p_column in ('posts', 'words') then 10 else 3 end, 30) then
    return 'rate_limited';
  end if;

  if p_column in ('posts', 'words') and public.contains_blocked_word(item_text) then
    return 'blocked_word';
  end if;

  ceiling := case
    when p_column in ('posts', 'words') then 500
    when p_column = 'votes' then 2000
    else null
  end;

  if ceiling is not null then
    execute format('select %I from public.rooms where code = $1', p_column)
      into current_col
      using mod_code;
    current_col := coalesce(current_col, '[]'::jsonb);
    if jsonb_typeof(current_col) = 'array' and jsonb_array_length(current_col) >= ceiling then
      return 'room_full';
    end if;
  end if;

  update public.rooms
  set
    updated_at = now(),
    posts     = case when p_column = 'posts'     then coalesce(posts, '[]'::jsonb) || jsonb_build_array(p_item) else posts end,
    words     = case when p_column = 'words'     then coalesce(words, '[]'::jsonb) || jsonb_build_array(p_item) else words end,
    votes     = case when p_column = 'votes'     then coalesce(votes, '[]'::jsonb) || jsonb_build_array(p_item) else votes end,
    responses = case when p_column = 'responses' then coalesce(responses, '[]'::jsonb) || jsonb_build_array(p_item) else responses end
  where code = mod_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'append_pending_item: room % not found or not initialized for moderation', p_code;
  end if;

  return 'ok';
end;
$$;

revoke all on function public.append_pending_item(text, text, jsonb) from public;
grant execute on function public.append_pending_item(text, text, jsonb) to anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Verify after running:
--
--   select routine_name, data_type from information_schema.routines
--   where routine_schema = 'public'
--   and routine_name in ('join_roster','contains_blocked_word','check_rate_limit',
--     'submit_word','append_post','increment_votes','append_ranking','like_post',
--     'record_student_response','append_pending_item');
--   -- data_type should read 'text' for every write RPC except
--   -- contains_blocked_word (boolean) and check_rate_limit (boolean).
--
--   select * from public.rate_limits order by window_start desc limit 20;
--
-- Known caveat: contains_blocked_word/check_rate_limit are deliberately not
-- granted to anon/authenticated, so calling them directly via
-- supabase.rpc(...) from a browser console will fail with a permission
-- error — that's the intended behaviour, not a bug to fix.
-- ---------------------------------------------------------------------------
