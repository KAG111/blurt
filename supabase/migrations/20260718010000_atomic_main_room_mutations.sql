-- Fixes a data-loss bug in classic (non-moderated) rooms: submissions to
-- shared JSON columns (votes/words/posts) currently do
--   client reads column -> mutates JSON in memory -> writes whole column back
-- Two students submitting within the same round-trip window both read the
-- same starting value, both write back a "successful" update, and whichever
-- write lands second silently overwrites the first — the retry/backoff loop
-- around this doesn't help, because there's no conflict for Postgres to
-- detect; each write independently succeeds, it's just wrong.
--
-- The fix is the same shape as append_pending_item() from the previous
-- migration: move the read-modify-write server-side into a single
-- SECURITY DEFINER call per operation, using `select ... for update` (or,
-- where the mutation is a pure append, a single atomic UPDATE ... SET
-- col = col || new_value) so concurrent callers serialize on the row lock
-- instead of racing on a client-side read.
--
-- These operate on the *main* room row only (never MOD- rows) — the
-- moderated/shadow path keeps using append_pending_item() from students,
-- exactly as before.
--
-- Run this in the Supabase SQL Editor after reviewing it.

begin;

-- a. mc / poll vote increments. p_qindex is null for mc (votes is a flat
-- array of per-option counters); for poll, votes is an array of such arrays,
-- one per question, indexed by p_qindex. Grows arrays with zero-padding as
-- needed so this works whether or not the target slot has been touched yet.
create or replace function public.increment_votes(
  p_code text,
  p_qindex int,
  p_option_indices int[]
)
returns void
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
end;
$$;

-- b. Ranking: each submission is one full ranking (an array), appended
-- whole — a pure append, so a single atomic UPDATE is enough, no explicit
-- row lock needed (matches append_pending_item's style).
create or replace function public.append_ranking(
  p_code text,
  p_ranking jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  affected int;
begin
  update public.rooms
  set votes = coalesce(votes, '[]'::jsonb) || jsonb_build_array(p_ranking),
      updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'append_ranking: room % not found', p_code;
  end if;
end;
$$;

-- c. Word cloud: case-insensitive dedupe by text — increments the existing
-- entry's count, or appends a new {text, count: 1}.
create or replace function public.submit_word(
  p_code text,
  p_text text
)
returns void
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
    current_words := current_words || jsonb_build_array(jsonb_build_object('text', p_text, 'count', 1));
  end if;

  update public.rooms
  set words = current_words, updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'submit_word: room % not found on write', p_code;
  end if;
end;
$$;

-- d. Brainstorm / sticky posts. p_dedupe defaults to true (brainstorm's
-- existing behaviour: case-insensitive text match increments count and
-- merges ownerSessionIds). Sticky notes call this with p_dedupe := false,
-- since each note is a distinct pinned object (position/color/image) and
-- was never deduped by text client-side — merging two would silently
-- destroy one note's position/color/image, a real behaviour change, not a
-- bugfix, so the client keeps that off for sticky.
create or replace function public.append_post(
  p_code text,
  p_post jsonb,
  p_dedupe boolean default true
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_posts jsonb;
  i int;
  found_idx int := null;
  post_text text := p_post ->> 'text';
  existing_count int;
  merged_owners jsonb;
  affected int;
begin
  select posts into current_posts from public.rooms where code = p_code for update;
  if not found then
    raise exception 'append_post: room % not found', p_code;
  end if;

  current_posts := coalesce(current_posts, '[]'::jsonb);
  if jsonb_typeof(current_posts) <> 'array' then
    current_posts := '[]'::jsonb;
  end if;

  if p_dedupe and post_text is not null then
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
    current_posts := current_posts || jsonb_build_array(p_post);
  end if;

  update public.rooms
  set posts = current_posts, updated_at = now()
  where code = p_code;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'append_post: room % not found on write', p_code;
  end if;
end;
$$;

-- e. Like a post by id. No-ops (does not raise) if the id no longer
-- exists, matching the client's existing tolerant behaviour.
create or replace function public.like_post(
  p_code text,
  p_post_id text
)
returns void
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
end;
$$;

revoke all on function public.increment_votes(text, int, int[]) from public;
revoke all on function public.append_ranking(text, jsonb) from public;
revoke all on function public.submit_word(text, text) from public;
revoke all on function public.append_post(text, jsonb, boolean) from public;
revoke all on function public.like_post(text, text) from public;

grant execute on function public.increment_votes(text, int, int[]) to anon, authenticated;
grant execute on function public.append_ranking(text, jsonb) to anon, authenticated;
grant execute on function public.submit_word(text, text) to anon, authenticated;
grant execute on function public.append_post(text, jsonb, boolean) to anon, authenticated;
grant execute on function public.like_post(text, text) to anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Verify after running:
--
--   select routine_name from information_schema.routines
--   where routine_schema = 'public'
--   and routine_name in ('increment_votes','append_ranking','submit_word','append_post','like_post');
--
-- Same jsonb-vs-json caveat as the previous migration: this assumes
-- votes/words/posts are `jsonb` columns. Check
-- information_schema.columns if you haven't already confirmed that.
-- ---------------------------------------------------------------------------
