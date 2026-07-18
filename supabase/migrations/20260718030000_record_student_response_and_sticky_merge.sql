-- Two follow-ups to the earlier atomic-mutation migration
-- (20260718010000_atomic_main_room_mutations.sql):
--
-- 1. recordStudentResponse() (poll's per-student named-answer tracking,
--    stored in the `responses` column) had the same client-side
--    read-modify-write race as votes/words/posts did — two students
--    submitting at the same moment could silently clobber each other's
--    named answers. Same fix shape: a SECURITY DEFINER RPC that does the
--    whole find-or-create-record-then-set-answer under a row lock.
--
-- 2. Sticky notes now dedupe identical text the same way brainstorm ideas
--    already did (this is a product decision, not a bug fix — sticky
--    notes previously never merged). append_post() from the earlier
--    migration already supports this via its p_dedupe parameter, but its
--    dedupe check only excluded a *null* text, not an *empty* one — and a
--    sticky note can be submitted as a photo with no text at all. Two
--    different photo-only notes would otherwise both match on empty text
--    and get merged, silently discarding one photo. Re-defining append_post
--    here with that check tightened before turning dedupe on for sticky.

begin;

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

create or replace function public.record_student_response(
  p_code text,
  p_name text,
  p_qindex int,
  p_selected jsonb
)
returns void
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
end;
$$;

revoke all on function public.record_student_response(text, text, int, jsonb) from public;
grant execute on function public.record_student_response(text, text, int, jsonb) to anon, authenticated;

commit;
