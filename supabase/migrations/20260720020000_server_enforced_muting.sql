-- Server-enforced device muting. blockDevice() (index.html) previously only
-- ever wrote blockedSessions into config and relied on the *blocked
-- browser's own copy of the app* to notice its sessionId is on that list
-- and show a "muted" screen (isBlockedSession/renderBlockedScreen) — a
-- client that simply refreshes gets a brand-new sessionId (see
-- s.mySessionId generation at submission time) and walks straight past
-- that check, since nothing server-side ever enforced it. This migration
-- makes every student-facing write RPC check the caller's session id
-- against the room's own blockedSessions list and refuse the write with a
-- new 'blocked' status — the mute now holds even across a refresh, a new
-- tab, or a direct RPC call that skips the browser's own UI entirely.
--
-- This is a deterrent, not a hard identity ban (there's no login, so a
-- muted person could still generate an entirely fresh sessionId by
-- clearing storage) — same threat model the client-side version already
-- had, just no longer defeated by an ordinary refresh.
--
-- Run this in the Supabase SQL Editor after reviewing it. Depends on
-- check_rate_limit/contains_blocked_word from
-- 20260718040000_roster_join_filter_rate_limits.sql already being applied.

begin;

-- Internal helper — not granted to anon/authenticated, same as
-- contains_blocked_word/check_rate_limit (only callable from other
-- SECURITY DEFINER functions in this schema).
create or replace function public.session_is_blocked(
  p_code text,
  p_session_id text
)
returns boolean
language plpgsql
as $$
declare
  blocked jsonb;
begin
  if p_session_id is null or p_session_id = '' then
    return false;
  end if;

  select config -> 'blockedSessions' into blocked from public.rooms where code = p_code;
  if blocked is null or jsonb_typeof(blocked) <> 'array' then
    return false;
  end if;

  return blocked @> jsonb_build_array(p_session_id);
end;
$$;

revoke all on function public.session_is_blocked(text, text) from public;

-- ---------------------------------------------------------------------------
-- Re-create each student-facing write RPC with a blocked-session check
-- added right up front. Signatures are unchanged (so plain CREATE OR
-- REPLACE is enough) except record_student_response, which never took a
-- session id before now — that one needs a DROP first since it's gaining a
-- parameter.
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
  if public.session_is_blocked(p_code, p_session_id) then
    return 'blocked';
  end if;

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
  if public.session_is_blocked(p_code, p_session_id) then
    return 'blocked';
  end if;

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
  if public.session_is_blocked(p_code, session_key) then
    return 'blocked';
  end if;

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
  if public.session_is_blocked(p_code, p_session_id) then
    return 'blocked';
  end if;

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
  if public.session_is_blocked(p_code, p_session_id) then
    return 'blocked';
  end if;

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
  if public.session_is_blocked(p_code, p_session_id) then
    return 'blocked';
  end if;

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

-- Gaining a p_session_id parameter it never had before, so the old
-- signature has to go first.
drop function if exists public.record_student_response(text, text, int, jsonb);
create or replace function public.record_student_response(
  p_code text,
  p_name text,
  p_qindex int,
  p_selected jsonb,
  p_session_id text default null
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
  if public.session_is_blocked(p_code, p_session_id) then
    return 'blocked';
  end if;

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

  if public.session_is_blocked(p_code, session_key) then
    return 'blocked';
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

create or replace function public.submit_quiz_answer(
  p_code text,
  p_name text,
  p_qindex int,
  p_selected int,
  p_session_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  mod_code text := 'MOD-' || p_code;
  main_cfg jsonb;
  mod_cfg jsonb;
  clean_name text := lower(trim(both from p_name));
  phase text;
  current_q int;
  timer_seconds int;
  phase_started timestamptz;
  grace_seconds constant numeric := 2;
  answer_key jsonb;
  correct_idx int;
  quiz_responses jsonb;
  found_idx int := null;
  i int;
  is_correct boolean;
  prior_streak int;
  new_streak int;
  base_points int;
  speed_points int;
  streak_points int;
  total_points int;
  elapsed_ms numeric;
  remaining_frac numeric;
  per_q jsonb;
  answered jsonb;
  already_listed boolean := false;
begin
  if public.session_is_blocked(p_code, p_session_id) then
    return 'blocked';
  end if;

  -- 10/30s rather than the stricter 3/30s "votes" tier: this app's existing
  -- client-side retry pattern (retry up to 3x on a transient 'error') can
  -- otherwise burn most of a tight budget answering a single question,
  -- unfairly rate-limiting the next question's genuine first attempt.
  if not public.check_rate_limit(p_code, p_session_id, 'submit_quiz_answer', 10, 30) then
    return 'rate_limited';
  end if;

  if clean_name = '' then
    return 'error';
  end if;

  -- Lock the main row first (consistent ordering with the MOD- row lock
  -- below avoids a deadlock if anything else ever needs both).
  select config into main_cfg from public.rooms where code = p_code for update;
  if not found then
    return 'room_not_found';
  end if;

  phase := main_cfg ->> 'phase';
  current_q := coalesce((main_cfg ->> 'currentIndex')::int, 0);
  if phase is distinct from 'answering' or current_q is distinct from p_qindex then
    return 'not_answering_phase';
  end if;

  timer_seconds := coalesce((main_cfg ->> 'timerSeconds')::int, 0);
  if main_cfg ->> 'phaseStartedAt' is not null then
    phase_started := to_timestamp((main_cfg ->> 'phaseStartedAt')::bigint / 1000.0);
    if timer_seconds > 0 and now() > phase_started + make_interval(secs => timer_seconds) + make_interval(secs => grace_seconds) then
      return 'time_expired';
    end if;
  end if;

  select config into mod_cfg from public.rooms where code = mod_code for update;
  if not found then
    return 'room_not_found';
  end if;

  answer_key := coalesce(mod_cfg -> 'answerKey', '[]'::jsonb);
  if jsonb_typeof(answer_key) <> 'array' or jsonb_array_length(answer_key) <= p_qindex then
    return 'error';
  end if;
  correct_idx := (answer_key ->> p_qindex)::int;

  quiz_responses := coalesce(mod_cfg -> 'quizResponses', '[]'::jsonb);
  if jsonb_typeof(quiz_responses) <> 'array' then
    quiz_responses := '[]'::jsonb;
  end if;

  for i in 0 .. jsonb_array_length(quiz_responses) - 1 loop
    if lower(trim(both from (quiz_responses -> i ->> 'name'))) = clean_name then
      found_idx := i;
      exit;
    end if;
  end loop;

  if found_idx is not null
     and jsonb_typeof(quiz_responses -> found_idx -> 'perQuestion' -> p_qindex) = 'object' then
    return 'already_answered';
  end if;

  if found_idx is null then
    quiz_responses := quiz_responses || jsonb_build_array(jsonb_build_object(
      'name', p_name, 'totalScore', 0, 'streak', 0, 'perQuestion', '[]'::jsonb
    ));
    found_idx := jsonb_array_length(quiz_responses) - 1;
  end if;

  is_correct := (p_selected = correct_idx);
  prior_streak := coalesce((quiz_responses -> found_idx ->> 'streak')::int, 0);

  if is_correct then
    if timer_seconds > 0 then
      base_points := 500;
      elapsed_ms := extract(epoch from (now() - phase_started)) * 1000;
      remaining_frac := greatest(0, least(1, 1 - (elapsed_ms / (timer_seconds * 1000))));
      speed_points := round(500 * remaining_frac);
    else
      base_points := 1000;
      speed_points := 0;
    end if;
    streak_points := least(500, prior_streak * 100);
    new_streak := prior_streak + 1;
  else
    base_points := 0;
    speed_points := 0;
    streak_points := 0;
    new_streak := 0;
  end if;

  total_points := base_points + speed_points + streak_points;

  per_q := coalesce(quiz_responses -> found_idx -> 'perQuestion', '[]'::jsonb);
  while jsonb_array_length(per_q) <= p_qindex loop
    per_q := per_q || 'null'::jsonb;
  end loop;
  per_q := jsonb_set(per_q, array[p_qindex::text], jsonb_build_object(
    'selected', p_selected,
    'correct', is_correct,
    'basePoints', base_points,
    'speedPoints', speed_points,
    'streakPoints', streak_points,
    'pointsEarned', total_points,
    'answeredAtMs', (extract(epoch from now()) * 1000)::bigint
  ));
  quiz_responses := jsonb_set(quiz_responses, array[found_idx::text, 'perQuestion'], per_q);
  quiz_responses := jsonb_set(quiz_responses, array[found_idx::text, 'totalScore'],
    to_jsonb(coalesce((quiz_responses -> found_idx ->> 'totalScore')::int, 0) + total_points));
  quiz_responses := jsonb_set(quiz_responses, array[found_idx::text, 'streak'], to_jsonb(new_streak));

  update public.rooms
  set config = jsonb_set(coalesce(config, '{}'::jsonb), '{quizResponses}', quiz_responses),
      updated_at = now()
  where code = mod_code;

  -- Public-safe "who has answered" tally on the MAIN row (names only).
  answered := coalesce(main_cfg -> 'answeredNames', '[]'::jsonb);
  for i in 0 .. jsonb_array_length(answered) - 1 loop
    if lower(trim(both from (answered ->> i))) = clean_name then
      already_listed := true;
      exit;
    end if;
  end loop;
  if not already_listed then
    update public.rooms
    set config = jsonb_set(coalesce(config, '{}'::jsonb), '{answeredNames}', answered || jsonb_build_array(p_name)),
        updated_at = now()
    where code = p_code;
  end if;

  return 'ok';
end;
$$;

-- Grants are unaffected by CREATE OR REPLACE, but record_student_response
-- needs re-granting since it was dropped and recreated with a new
-- signature above.
revoke all on function public.record_student_response(text, text, int, jsonb, text) from public;
grant execute on function public.record_student_response(text, text, int, jsonb, text) to anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Verify after running:
--
--   select routine_name from information_schema.routines
--   where routine_schema = 'public' and routine_name = 'session_is_blocked';
--
--   select routine_name, data_type from information_schema.routines
--   where routine_schema = 'public'
--   and routine_name in ('join_roster','submit_word','append_post',
--     'increment_votes','append_ranking','like_post',
--     'record_student_response','append_pending_item','submit_quiz_answer');
--   -- every one of these should still show data_type = 'text'.
--
--   -- Manually test the mute: with a room open, add a session id to
--   -- config.blockedSessions (or use the app's own "Mute" button), then
--   -- try any of the RPCs above with that session id — expect 'blocked'.
-- ---------------------------------------------------------------------------
