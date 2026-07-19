-- New "Quiz" room type (type = 'quiz'): a teacher-paced, scored, multi-
-- question quiz with per-question phases (answering -> reveal ->
-- leaderboard) and anti-cheat. This is a new room type, not a rename of
-- the existing 'poll' or 'mc' types — both of those are untouched by this
-- migration and keep working exactly as before.
--
-- ANTI-CHEAT DATA MODEL
-- The single biggest problem with the old approach (poll's correctIndex
-- living in plain `config`, which every participant can read) is that
-- correctness is visible to anyone who reads the room before they've
-- answered. This migration never lets a correct answer enter a column any
-- ordinary participant can select:
--
--   - The MAIN room row's `config.questions[i]` holds only `prompt` and
--     `options` — no correctIndex, ever. Set once at room creation by the
--     teacher's own client (which already has host_secret and does this as
--     a plain kvSet, like every other single-writer config field in this
--     app — no RPC needed for that step).
--   - The correct answer for every question lives ONLY in the MOD-<code>
--     shadow row, at `config.answerKey` (an array of correct option
--     indices, parallel to the main row's `questions` array). Reading or
--     writing a MOD- row requires the room's host_secret — the same RLS
--     boundary that already protects moderation-pending content (see
--     20260717000000_room_isolation_and_pending_secrecy.sql). A student's
--     browser never holds host_secret, so it structurally cannot read
--     config.answerKey via an ordinary REST call, no matter which columns
--     it asks for.
--   - submit_quiz_answer() below is the only thing that ever compares a
--     student's selection to the answer key. It runs SECURITY DEFINER (so
--     it can read the MOD- row despite the caller not having
--     host_secret), and it returns only 'ok' (or a rejection status) —
--     never whether the answer was correct. Per-student detailed results
--     (selected option, correct/wrong, points, timestamp) are written into
--     the MOD- row's `config.quizResponses`, not the main row — so even
--     mid-quiz, no participant can read another participant's answers or
--     correctness by polling the room.
--   - The teacher's own client reveals a question by copying that
--     question's answer + aggregate vote counts from the MOD- row into the
--     main row's `config.revealStats` (again a plain kvGet/kvSet — the
--     teacher already legitimately holds host_secret). Only at that point
--     does the correct answer become visible to participants, which is the
--     intended moment for it to become visible.
--   - "How many have answered" on the teacher board (without revealing
--     what they answered) comes from `config.answeredNames` on the MAIN
--     row — a list of names only, written by submit_quiz_answer alongside
--     the real (hidden) record, safe to expose because it carries no
--     information about which option was picked.
--
-- SCORING
-- Correct answers score: 500 base (or a flat 1000 if the question has no
-- timer, matching the brief's "no timer = flat 1000") + a speed bonus up
-- to 500 more, scaled by the fraction of the timer window remaining when
-- the answer arrived + a streak bonus of 100 per consecutive correct
-- answer, capped at 500. All computed server-side from the room's own
-- phaseStartedAt/timerSeconds — never trusts a client-supplied timestamp.
--
-- PACING / ANTI-CHEAT ENFORCEMENT
-- An answer is only accepted when the main room row's `config.phase` is
-- 'answering' AND `config.currentIndex` matches the question being
-- answered, and (if a timer is set) within the timer window plus a small
-- fixed grace period for network latency. One answer per nickname per
-- question is enforced by checking for an existing (non-null) entry in
-- that student's `perQuestion[qIndex]` before accepting a new one, under a
-- row lock so two near-simultaneous submissions can't both slip through.
--
-- Run this in the Supabase SQL Editor after reviewing it.

begin;

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

revoke all on function public.submit_quiz_answer(text, text, int, int, text) from public;
grant execute on function public.submit_quiz_answer(text, text, int, int, text) to anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Verify after running:
--
--   select routine_name, data_type from information_schema.routines
--   where routine_schema = 'public' and routine_name = 'submit_quiz_answer';
--   -- data_type should read 'text'.
--
-- This migration depends on check_rate_limit() from
-- 20260718040000_roster_join_filter_rate_limits.sql already being applied.
-- ---------------------------------------------------------------------------
