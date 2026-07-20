-- Atomic moderation (approve / dismiss / approve-all). Student submissions
-- already go through atomic RPCs (append_pending_item et al.), but the
-- teacher side of moderation — approveSubmission/dismissSubmission/
-- undoDismiss/approveAllSubmissions in index.html — still did
-- read-MOD-array -> modify -> write-MOD-array, then read-main-array ->
-- merge -> write-main-array, entirely client-side. Two moderating devices
-- open at once (a teacher's laptop and their own phone remote, say) can
-- both read the same starting arrays and race to write back, silently
-- losing whichever write lands first — same shape of bug the earlier
-- atomic-mutation migrations fixed for student writes.
--
-- moderate_item() and moderate_all() below move both the shadow-row removal
-- and the main-row merge into one SECURITY DEFINER call each, under a row
-- lock, exactly like append_post/submit_word/increment_votes already do for
-- ordinary submissions. Unlike those, the caller here is the room's
-- teacher, not an anonymous student, so both functions check the caller's
-- x-host-secret request header against the room's stored host_secret before
-- doing anything — the same header-based check the rooms_select_scoped /
-- rooms_update_scoped RLS policies use for MOD- rows (see
-- 20260717000000_room_isolation_and_pending_secrecy.sql). SECURITY DEFINER
-- functions bypass RLS entirely, so this check has to be done explicitly in
-- the function body rather than left to a policy.
--
-- Run this in the Supabase SQL Editor after reviewing it.

begin;

-- ---------------------------------------------------------------------------
-- Internal helpers — not granted to anon/authenticated. They do no table
-- access themselves (pure jsonb transforms), so this isn't a security
-- boundary, just consistency with the other private helpers in this schema
-- (contains_blocked_word, check_rate_limit): only moderate_item/moderate_all
-- are meant to be called directly over PostgREST.
-- ---------------------------------------------------------------------------

-- Merges one approved pending item into a main-row column, using the same
-- rules the client used to apply itself: word-cloud entries dedupe
-- case-insensitively and increment count; brainstorm/sticky posts dedupe
-- the same way (except an empty/photo-only text never merges with another
-- empty text, so two distinct photo notes don't collapse into one); ranking
-- submissions append the whole ranking; mc/poll submissions increment the
-- selected option counters (poll additionally scoped to p_item's qIndex).
create or replace function public._merge_moderated_item(
  p_room_type text,
  p_column text,
  p_main_col jsonb,
  p_item jsonb
)
returns jsonb
language plpgsql
as $$
declare
  main_col jsonb := coalesce(p_main_col, '[]'::jsonb);
  i int;
  found_idx int := null;
  item_text text;
  existing_count int;
  merged_owners jsonb;
  q_idx int;
  target jsonb;
  option_indices int[];
  idx int;
begin
  if jsonb_typeof(main_col) <> 'array' then
    main_col := '[]'::jsonb;
  end if;

  if p_column = 'words' then
    item_text := p_item ->> 'text';
    for i in 0 .. jsonb_array_length(main_col) - 1 loop
      if lower(main_col -> i ->> 'text') = lower(item_text) then
        found_idx := i;
        exit;
      end if;
    end loop;
    if found_idx is not null then
      existing_count := coalesce((main_col -> found_idx ->> 'count')::int, 0);
      main_col := jsonb_set(main_col, array[found_idx::text, 'count'], to_jsonb(existing_count + 1));
    else
      main_col := main_col || jsonb_build_array(jsonb_build_object('text', item_text, 'count', 1));
    end if;

  elsif p_column = 'posts' then
    item_text := p_item ->> 'text';
    if item_text is not null and item_text <> '' then
      for i in 0 .. jsonb_array_length(main_col) - 1 loop
        if lower(main_col -> i ->> 'text') = lower(item_text) then
          found_idx := i;
          exit;
        end if;
      end loop;
    end if;
    if found_idx is not null then
      existing_count := coalesce((main_col -> found_idx ->> 'count')::int, 1);
      select coalesce(jsonb_agg(distinct value), '[]'::jsonb)
        into merged_owners
        from jsonb_array_elements_text(
          coalesce(main_col -> found_idx -> 'ownerSessionIds', '[]'::jsonb)
          || coalesce(p_item -> 'ownerSessionIds', '[]'::jsonb)
        ) value;
      main_col := jsonb_set(main_col, array[found_idx::text, 'count'], to_jsonb(existing_count + 1));
      main_col := jsonb_set(main_col, array[found_idx::text, 'ownerSessionIds'], merged_owners);
    else
      main_col := main_col || jsonb_build_array(p_item);
    end if;

  elsif p_column = 'votes' then
    if p_room_type = 'ranking' then
      main_col := main_col || jsonb_build_array(p_item -> 'value');

    elsif p_room_type = 'poll' then
      q_idx := coalesce((p_item ->> 'qIndex')::int, 0);
      while jsonb_array_length(main_col) <= q_idx loop
        main_col := main_col || 'null'::jsonb;
      end loop;
      target := main_col -> q_idx;
      if target is null or jsonb_typeof(target) <> 'array' then
        target := '[]'::jsonb;
      end if;
      option_indices := array(select jsonb_array_elements_text(coalesce(p_item -> 'value', '[]'::jsonb)))::int[];
      foreach idx in array option_indices loop
        while jsonb_array_length(target) <= idx loop
          target := target || to_jsonb(0);
        end loop;
        target := jsonb_set(target, array[idx::text], to_jsonb(coalesce((target ->> idx)::int, 0) + 1));
      end loop;
      main_col := jsonb_set(main_col, array[q_idx::text], target);

    else -- 'mc'
      option_indices := array(select jsonb_array_elements_text(coalesce(p_item -> 'value', '[]'::jsonb)))::int[];
      foreach idx in array option_indices loop
        while jsonb_array_length(main_col) <= idx loop
          main_col := main_col || to_jsonb(0);
        end loop;
        main_col := jsonb_set(main_col, array[idx::text], to_jsonb(coalesce((main_col ->> idx)::int, 0) + 1));
      end loop;
    end if;
  end if;

  return main_col;
end;
$$;

revoke all on function public._merge_moderated_item(text, text, jsonb, jsonb) from public;

-- Same find-or-create-then-set-answer logic as record_student_response()
-- (20260718030000_record_student_response_and_sticky_merge.sql), extracted
-- so an approved poll vote can update the main row's `responses` column in
-- the same atomic write as the vote itself, instead of a second round trip.
create or replace function public._merge_poll_response(
  p_responses jsonb,
  p_name text,
  p_qindex int,
  p_selected jsonb
)
returns jsonb
language plpgsql
as $$
declare
  current_responses jsonb := coalesce(p_responses, '[]'::jsonb);
  i int;
  found_idx int := null;
  answers jsonb;
begin
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

  return current_responses;
end;
$$;

revoke all on function public._merge_poll_response(jsonb, text, int, jsonb) from public;

-- ---------------------------------------------------------------------------
-- Public RPCs.
-- ---------------------------------------------------------------------------

-- Approves or dismisses a single moderation-pending item, atomically. Locks
-- the main room row first (so the auth check and the eventual merge see a
-- consistent snapshot), then the MOD- shadow row, so a second moderating
-- device racing the same action serializes behind this one instead of
-- reading stale data. 'not_found' covers both "no such room" and "this item
-- id is no longer pending" (e.g. another moderator already handled it) —
-- callers should treat both as a harmless no-op, not an error to retry.
create or replace function public.moderate_item(
  p_code text,
  p_item_id text,
  p_action text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  mod_code text := 'MOD-' || p_code;
  header_secret text := current_setting('request.headers', true)::json ->> 'x-host-secret';
  stored_secret text;
  main_cfg jsonb;
  main_words jsonb;
  main_posts jsonb;
  main_votes jsonb;
  main_responses jsonb;
  room_type text;
  column_name text;
  pending jsonb;
  i int;
  found_idx int := null;
  item jsonb;
  merged_col jsonb;
  merged_responses jsonb;
  student_name text;
  q_idx int;
  affected int;
begin
  if p_action not in ('approve', 'dismiss') then
    return 'error';
  end if;

  select host_secret::text, config, words, posts, votes, responses
    into stored_secret, main_cfg, main_words, main_posts, main_votes, main_responses
    from public.rooms where code = p_code for update;
  if not found then
    return 'not_found';
  end if;
  if header_secret is null or header_secret <> stored_secret then
    return 'unauthorized';
  end if;

  room_type := main_cfg ->> 'type';
  column_name := case
    when room_type = 'wordcloud' then 'words'
    when room_type in ('brainstorm', 'sticky') then 'posts'
    when room_type in ('mc', 'poll', 'ranking') then 'votes'
    else null
  end;
  if column_name is null then
    return 'error';
  end if;

  execute format('select %I from public.rooms where code = $1 for update', column_name)
    into pending using mod_code;
  if not found then
    return 'not_found';
  end if;

  pending := coalesce(pending, '[]'::jsonb);
  if jsonb_typeof(pending) <> 'array' then
    pending := '[]'::jsonb;
  end if;

  for i in 0 .. jsonb_array_length(pending) - 1 loop
    if (pending -> i ->> 'id') = p_item_id then
      found_idx := i;
      exit;
    end if;
  end loop;
  if found_idx is null then
    return 'not_found';
  end if;

  item := pending -> found_idx;
  pending := pending - found_idx;

  execute format('update public.rooms set %I = $1, updated_at = now() where code = $2', column_name)
    using pending, mod_code;

  if p_action = 'dismiss' then
    return 'ok';
  end if;

  merged_col := public._merge_moderated_item(
    room_type, column_name,
    case column_name when 'words' then main_words when 'posts' then main_posts else main_votes end,
    item
  );

  merged_responses := main_responses;
  if room_type = 'poll' then
    student_name := item ->> 'studentName';
    if student_name is not null and trim(both from student_name) <> '' then
      q_idx := coalesce((item ->> 'qIndex')::int, 0);
      merged_responses := public._merge_poll_response(main_responses, student_name, q_idx, item -> 'value');
    end if;
  end if;

  update public.rooms
  set
    updated_at = now(),
    words     = case when column_name = 'words' then merged_col else words end,
    posts     = case when column_name = 'posts' then merged_col else posts end,
    votes     = case when column_name = 'votes' then merged_col else votes end,
    responses = case when room_type = 'poll' then merged_responses else responses end
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    return 'error';
  end if;

  return 'ok';
end;
$$;

revoke all on function public.moderate_item(text, text, text) from public;
grant execute on function public.moderate_item(text, text, text) to anon, authenticated;

-- Drains the entire pending set for a room into the main row in one go —
-- same merge rules as moderate_item, applied to every pending item in
-- order, all inside this one function call's transaction (either the whole
-- batch lands, or none of it does).
create or replace function public.moderate_all(
  p_code text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  mod_code text := 'MOD-' || p_code;
  header_secret text := current_setting('request.headers', true)::json ->> 'x-host-secret';
  stored_secret text;
  main_cfg jsonb;
  main_words jsonb;
  main_posts jsonb;
  main_votes jsonb;
  main_responses jsonb;
  room_type text;
  column_name text;
  pending jsonb;
  merged_col jsonb;
  merged_responses jsonb;
  i int;
  item jsonb;
  student_name text;
  q_idx int;
  affected int;
begin
  select host_secret::text, config, words, posts, votes, responses
    into stored_secret, main_cfg, main_words, main_posts, main_votes, main_responses
    from public.rooms where code = p_code for update;
  if not found then
    return 'not_found';
  end if;
  if header_secret is null or header_secret <> stored_secret then
    return 'unauthorized';
  end if;

  room_type := main_cfg ->> 'type';
  column_name := case
    when room_type = 'wordcloud' then 'words'
    when room_type in ('brainstorm', 'sticky') then 'posts'
    when room_type in ('mc', 'poll', 'ranking') then 'votes'
    else null
  end;
  if column_name is null then
    return 'error';
  end if;

  execute format('select %I from public.rooms where code = $1 for update', column_name)
    into pending using mod_code;
  if not found then
    return 'not_found';
  end if;

  pending := coalesce(pending, '[]'::jsonb);
  if jsonb_typeof(pending) <> 'array' then
    pending := '[]'::jsonb;
  end if;

  merged_col := case column_name when 'words' then main_words when 'posts' then main_posts else main_votes end;
  merged_responses := main_responses;

  for i in 0 .. jsonb_array_length(pending) - 1 loop
    item := pending -> i;
    merged_col := public._merge_moderated_item(room_type, column_name, merged_col, item);

    if room_type = 'poll' then
      student_name := item ->> 'studentName';
      if student_name is not null and trim(both from student_name) <> '' then
        q_idx := coalesce((item ->> 'qIndex')::int, 0);
        merged_responses := public._merge_poll_response(merged_responses, student_name, q_idx, item -> 'value');
      end if;
    end if;
  end loop;

  execute format('update public.rooms set %I = $1, updated_at = now() where code = $2', column_name)
    using '[]'::jsonb, mod_code;

  update public.rooms
  set
    updated_at = now(),
    words     = case when column_name = 'words' then merged_col else words end,
    posts     = case when column_name = 'posts' then merged_col else posts end,
    votes     = case when column_name = 'votes' then merged_col else votes end,
    responses = case when room_type = 'poll' then merged_responses else responses end
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    return 'error';
  end if;

  return 'ok';
end;
$$;

revoke all on function public.moderate_all(text) from public;
grant execute on function public.moderate_all(text) to anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Verify after running:
--
--   select routine_name from information_schema.routines
--   where routine_schema = 'public'
--   and routine_name in ('moderate_item', 'moderate_all',
--     '_merge_moderated_item', '_merge_poll_response');
--
-- Depends on the `rooms.host_secret` column and jsonb columns from
-- 20260717000000_room_isolation_and_pending_secrecy.sql already being
-- applied. Same jsonb-vs-json caveat as earlier migrations: assumes
-- words/posts/votes/responses are `jsonb`, not `json`.
-- ---------------------------------------------------------------------------
