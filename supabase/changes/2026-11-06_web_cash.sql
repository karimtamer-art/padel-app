-- 2026-11-06 — Cash at the venue as a second payment option on the website.
--
-- Reverses the 2026-10-21 "InstaPay ONLY" decision for padel-rivals.com/register.
-- A paid event now takes either:
--   * instapay — sender name + screenshot, exactly as before; or
--   * cash     — nothing uploaded; the pair pays amount_due at the desk.
-- Free events are unchanged ('free').
--
-- Still no gateway and nothing faked (rule 8). Cash is recorded on the
-- registration only; no money moves in the database, same as InstaPay here.
-- web_register keeps its 12-argument signature: it simply stops ignoring
-- p_pay_method. Any value other than 'cash' still means InstaPay, so a page
-- cached from before this change keeps working.
--
-- Safe to re-run.

-- 1. Widen the CHECK ------------------------------------------------------------
do $$ begin
  alter table public.web_registrations drop constraint if exists web_registrations_pay_chk;
  alter table public.web_registrations add constraint web_registrations_pay_chk
    check (pay_method in ('instapay', 'cash', 'free'));
end $$;

-- 2. web_register accepts 'cash' -----------------------------------------------
create or replace function public.web_register(
  p_tournament     uuid,
  p_name           text,
  p_phone          text,
  p_email          text,
  p_level          text,
  p_partner_name   text,
  p_partner_phone  text,
  p_partner_level  text,
  p_pay_method     text,
  p_sender         text default null,
  p_proof_path     text default null,
  p_needs_partner  boolean default false)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_t       record;
  v_lv      text[] := public.web_levels();
  v_lo      int; v_hi int;
  v_digits  text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_pay     text;
  v_due     numeric;
  v_id      uuid;
  v_name    text := btrim(coalesce(p_name, ''));
  v_pname   text := btrim(coalesce(p_partner_name, ''));
  v_solo    boolean := coalesce(p_needs_partner, false);
begin
  select * into v_t from public.web_open_tournaments() o where o.id = p_tournament;
  if not found then
    raise exception 'Registration for this tournament is closed.';
  end if;

  if length(v_name) < 2 or length(v_name) > 80 then
    raise exception 'Please enter your full name.';
  end if;
  if not v_solo and (length(v_pname) < 2 or length(v_pname) > 80) then
    raise exception 'Please enter your partner''s name.';
  end if;
  if length(v_digits) < 10 or length(v_digits) > 15 then
    raise exception 'Please enter a valid WhatsApp number.';
  end if;
  if p_email is not null and length(p_email) > 120 then
    raise exception 'That email address is too long.';
  end if;

  v_lo := coalesce(array_position(v_lv, v_t.min_category), 1);
  v_hi := coalesce(array_position(v_lv, v_t.max_category), array_length(v_lv, 1));
  if coalesce(array_position(v_lv, p_level), 0) not between v_lo and v_hi
     or (not v_solo
         and coalesce(array_position(v_lv, p_partner_level), 0) not between v_lo and v_hi) then
    raise exception 'Both players must be within this tournament''s levels.';
  end if;

  if v_t.spots_left is not null and v_t.spots_left <= 0 then
    raise exception 'Sorry, this tournament is full.';
  end if;

  if exists (select 1 from public.web_registrations
              where tournament_id = p_tournament and phone_digits = v_digits
                and status in ('pending', 'confirmed')) then
    raise exception 'This number is already registered for this tournament. Message us on WhatsApp if something is wrong.';
  end if;
  if (select count(*) from public.web_registrations
       where phone_digits = v_digits and created_at > now() - interval '10 minutes') >= 3 then
    raise exception 'Too many attempts. Please wait a few minutes and try again.';
  end if;

  -- entry_fee is per player: a pair pays two, a solo player their own share
  v_due := coalesce(v_t.entry_fee, 0) * case when v_solo then 1 else 2 end;
  -- A paid entry is InstaPay (proof now) or cash at the venue (2026-11-06).
  -- Anything else, including an older page sending nothing, means InstaPay.
  if v_due <= 0 then
    v_pay := 'free';
  elsif p_pay_method = 'cash' then
    v_pay := 'cash';
  else
    v_pay := 'instapay';
  end if;

  if v_pay = 'instapay' then
    if length(btrim(coalesce(p_sender, ''))) < 2 then
      raise exception 'Please enter the name on the InstaPay transfer.';
    end if;
    if p_proof_path is null or p_proof_path not like 'web/%'
       or not exists (select 1 from storage.objects
                       where bucket_id = 'web-payment-proofs' and name = p_proof_path) then
      raise exception 'Please upload a screenshot of the transfer.';
    end if;
  end if;

  insert into public.web_registrations
    (tournament_id, name, phone, phone_digits, email, level, needs_partner,
     partner_name, partner_phone, partner_level, pay_method, amount_due,
     instapay_sender, proof_path)
  values
    (p_tournament, v_name, btrim(p_phone), v_digits, nullif(btrim(coalesce(p_email, '')), ''),
     p_level, v_solo,
     case when v_solo then null else v_pname end,
     case when v_solo then null else nullif(btrim(coalesce(p_partner_phone, '')), '') end,
     case when v_solo then null else p_partner_level end,
     v_pay, v_due,
     case when v_pay = 'instapay' then btrim(p_sender) end,
     case when v_pay = 'instapay' then p_proof_path end)
  returning id into v_id;

  -- Alert staff (bell + push), same shape as the app's tournament alerts.
  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'admin_tournament',
         case when v_solo then 'Website entry — needs a partner'
              when v_pay = 'instapay' then 'Website entry — payment to verify'
              when v_pay = 'cash' then 'Website entry — cash at the venue'
              else 'New website entry' end,
         case when v_solo then v_name || ' (' || p_level || ', no partner yet)'
              else v_name || ' & ' || v_pname end
           || ' · ' || coalesce(v_t.name, 'tournament')
           || ' · ' || case v_pay when 'instapay' then 'InstaPay EGP ' || v_due::text
                                  when 'cash' then 'cash EGP ' || v_due::text || ' at the venue'
                                  else 'free entry' end
           || ' · WhatsApp ' || btrim(p_phone),
         jsonb_build_object('tournament_id', p_tournament, 'web_registration_id', v_id, 'admin', true)
    from (select o.organizer_id as uid from public.tournaments o
           where o.id = p_tournament and o.organizer_id is not null
          union select p.id from public.profiles p where p.is_admin = true) r
   where uid is not null;

  return v_id;
end $$;
revoke all on function public.web_register(uuid, text, text, text, text, text, text, text, text, text, text, boolean) from public;
grant execute on function public.web_register(uuid, text, text, text, text, text, text, text, text, text, text, boolean) to anon, authenticated;

-- ── verify ──────────────────────────────────────────────────────────────────
-- select pg_get_constraintdef(oid) from pg_constraint
--  where conname = 'web_registrations_pay_chk';         -- lists 'cash'
-- select pay_method, count(*) from public.web_registrations group by 1;
