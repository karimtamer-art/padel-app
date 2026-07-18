-- 2026-07-18 · Player-driven tournament results (submit → confirm → dispute).
--
-- A player in a tournament match submits a winner (+ optional score); the OTHER
-- team confirms or disputes; a dispute clears the submission and pings both
-- teams to re-submit. The organizer doesn't referee — set_match_winner is the
-- override. winner_entry is set only on CONFIRM, so advance_stage keeps keying
-- off confirmed results. A match vs an all-guest pair auto-confirms (no one to
-- confirm). Idempotent; also folded into migration_player_app.sql.

alter table public.tournament_matches
  add column if not exists submitted_winner uuid references public.tournament_entries(id) on delete set null;
alter table public.tournament_matches add column if not exists submitted_score text;
alter table public.tournament_matches
  add column if not exists submitted_by uuid references public.profiles(id) on delete set null;
alter table public.tournament_matches
  add column if not exists result_status text not null default 'open';

-- Organizer override also resolves any pending/disputed submission.
create or replace function public.set_match_winner(
  p_match_id uuid, p_winner uuid, p_score text default null)
returns text language plpgsql security definer set search_path = public as $$
declare m record;
begin
  select * into m from public.tournament_matches where id = p_match_id;
  if not found then return 'Match not found.'; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
  if p_winner is not null and p_winner not in (m.entry1, m.entry2) then
    return 'Winner must be one of the two pairs.';
  end if;
  update public.tournament_matches set
    winner_entry = p_winner, score = p_score,
    result_status = case when p_winner is null then 'open' else 'confirmed' end,
    submitted_winner = null, submitted_score = null, submitted_by = null
   where id = p_match_id;
  return null;
end $$;
grant execute on function public.set_match_winner(uuid, uuid, text) to authenticated;

create or replace function public.submit_tournament_result(
  p_match_id uuid, p_winner_entry uuid, p_score text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m record; v_my_team text; v_opp_has_app boolean;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select tm.*, e1.player_id a1, e1.partner_id a2, e2.player_id b1, e2.partner_id b2
    into m
    from public.tournament_matches tm
    join public.tournament_entries e1 on e1.id = tm.entry1
    join public.tournament_entries e2 on e2.id = tm.entry2
   where tm.id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.entry1 is null or m.entry2 is null then return 'This match isn''t ready.'; end if;
  if m.result_status = 'confirmed' or m.winner_entry is not null then
    return 'A result is already recorded.';
  end if;
  if p_winner_entry not in (m.entry1, m.entry2) then
    return 'Winner must be one of the two pairs.';
  end if;
  if v_uid in (m.a1, m.a2) then v_my_team := 'a';
  elsif v_uid in (m.b1, m.b2) then v_my_team := 'b';
  else return 'Only players in this match can submit a result.'; end if;

  update public.tournament_matches set
    submitted_winner = p_winner_entry, submitted_score = nullif(btrim(p_score), ''),
    submitted_by = v_uid, result_status = 'pending'
   where id = p_match_id;

  v_opp_has_app := case when v_my_team = 'a' then (m.b1 is not null or m.b2 is not null)
                                             else (m.a1 is not null or m.a2 is not null) end;
  if not v_opp_has_app then
    update public.tournament_matches set
      winner_entry = p_winner_entry, score = nullif(btrim(p_score), ''),
      result_status = 'confirmed'
     where id = p_match_id;
    return null;
  end if;

  insert into public.notifications (user_id, type, title, body, data)
  select pid, 'tournament', 'Confirm match result',
         'A score was submitted for your tournament match — tap to confirm or dispute.',
         jsonb_build_object('tournament_id', m.tournament_id, 'match_id', p_match_id)
  from (select unnest(case when v_my_team = 'a' then array[m.b1, m.b2]
                                                else array[m.a1, m.a2] end) as pid) x
  where pid is not null;
  return null;
end $$;
grant execute on function public.submit_tournament_result(uuid, uuid, text) to authenticated;

create or replace function public.confirm_tournament_result(p_match_id uuid, p_confirm boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m record; v_sub_team text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select tm.*, e1.player_id a1, e1.partner_id a2, e2.player_id b1, e2.partner_id b2
    into m
    from public.tournament_matches tm
    join public.tournament_entries e1 on e1.id = tm.entry1
    join public.tournament_entries e2 on e2.id = tm.entry2
   where tm.id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.result_status <> 'pending' then return 'There''s nothing to confirm.'; end if;

  if m.submitted_by in (m.a1, m.a2) then v_sub_team := 'a';
  elsif m.submitted_by in (m.b1, m.b2) then v_sub_team := 'b';
  else v_sub_team := null; end if;

  if v_sub_team = 'a' then
    if v_uid not in (m.b1, m.b2) then return 'Only the other team can confirm this.'; end if;
  elsif v_sub_team = 'b' then
    if v_uid not in (m.a1, m.a2) then return 'Only the other team can confirm this.'; end if;
  else
    return 'Couldn''t resolve the teams.';
  end if;

  if p_confirm then
    update public.tournament_matches set
      winner_entry = submitted_winner, score = submitted_score, result_status = 'confirmed'
     where id = p_match_id;
  else
    update public.tournament_matches set
      result_status = 'disputed',
      submitted_winner = null, submitted_score = null, submitted_by = null
     where id = p_match_id;
    insert into public.notifications (user_id, type, title, body, data)
    select pid, 'tournament', 'Result disputed',
           'A tournament match result was rejected — agree on the score and re-submit.',
           jsonb_build_object('tournament_id', m.tournament_id, 'match_id', p_match_id)
    from (select unnest(array[m.a1, m.a2, m.b1, m.b2]) as pid) x
    where pid is not null and pid <> v_uid;
  end if;
  return null;
end $$;
grant execute on function public.confirm_tournament_result(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
