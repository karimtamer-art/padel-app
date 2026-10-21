-- ============================================================
-- 2026-10-20 · Web registrations (padel-rivals.com landing page)
-- ============================================================
-- People who don't trust the app yet can register a pair for a tournament
-- from the website, with no account. The site runs as `anon`, so:
--
--   * Nothing here grants anon a TABLE. Anon reaches the data through two
--     SECURITY DEFINER RPCs only: web_open_tournaments() (read) and
--     web_register() (write). Same boundary as the app's RPCs.
--   * web_registrations is a SEPARATE table from tournament_entries on
--     purpose. tournament_entries.player_id is a real profile, and every
--     bracket/ticket/settlement path assumes it. A web pair is a lead that
--     staff confirm by WhatsApp and then enter into the draw by hand
--     (organizer guest-partner flow), as staff-added entries are today.
--   * Capacity counts BOTH tables, so the website can't oversell a draw.
--   * Payment is InstaPay screenshot ONLY (no cash, no gateway — rule 8).
--     The proof goes to a PRIVATE bucket anon can insert into but never
--     read, list or overwrite; web_register() refuses a proof path that
--     doesn't exist in that bucket.
--
-- Levels are padel categories, D Low (lowest) .. A Upper (highest), stored
-- on tournaments as min_category / max_category. NULL = no limit on that
-- side. These are a WEBSITE label only — they do not touch min_rating /
-- max_rating or the rating engine (rule 2).
--
-- Safe to re-run.
-- ============================================================

-- 1. Level categories --------------------------------------------------------
create or replace function public.web_levels()
returns text[] language sql immutable as $$
  select array['D Low','D Mid','D Upper',
               'C Low','C Mid','C Upper',
               'B Low','B Mid','B Upper',
               'A Low','A Mid','A Upper']::text[];
$$;
grant execute on function public.web_levels() to anon, authenticated;

alter table public.tournaments add column if not exists min_category text;
alter table public.tournaments add column if not exists max_category text;
do $$ begin
  alter table public.tournaments drop constraint if exists tournaments_web_category_chk;
  alter table public.tournaments add constraint tournaments_web_category_chk check (
    (min_category is null or min_category = any (public.web_levels()))
    and (max_category is null or max_category = any (public.web_levels()))
    and (min_category is null or max_category is null
         or array_position(public.web_levels(), min_category)
            <= array_position(public.web_levels(), max_category)));
exception when others then null; end $$;

-- 2. Table ---------------------------------------------------------------------
create table if not exists public.web_registrations (
  id              uuid primary key default gen_random_uuid(),
  tournament_id   uuid not null references public.tournaments(id) on delete cascade,
  name            text not null,
  phone           text not null,
  phone_digits    text not null,
  email           text,
  level           text not null,
  needs_partner   boolean not null default false,  -- solo: staff find them a partner
  partner_name    text,
  partner_phone   text,
  partner_level   text,
  pay_method      text not null,            -- instapay | free
  amount_due      numeric(10,2) not null default 0,
  instapay_sender text,
  proof_path      text,                     -- object name in web-payment-proofs
  status          text not null default 'pending',
  admin_note      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
-- "Find me a partner" (2026-10-21). These keep a database that already ran
-- the first version of this file in step with the create above.
alter table public.web_registrations add column if not exists needs_partner boolean not null default false;
alter table public.web_registrations alter column partner_name drop not null;
alter table public.web_registrations alter column partner_level drop not null;
do $$ begin
  alter table public.web_registrations drop constraint if exists web_registrations_partner_chk;
  alter table public.web_registrations add constraint web_registrations_partner_chk
    check (needs_partner or (partner_name is not null and partner_level is not null));
exception when others then null; end $$;

do $$ begin
  alter table public.web_registrations drop constraint if exists web_registrations_pay_chk;
  alter table public.web_registrations add constraint web_registrations_pay_chk
    check (pay_method in ('instapay', 'free'));
  alter table public.web_registrations drop constraint if exists web_registrations_status_chk;
  alter table public.web_registrations add constraint web_registrations_status_chk
    check (status in ('pending', 'confirmed', 'rejected', 'cancelled'));
exception when others then null; end $$;
create index if not exists idx_web_registrations_tournament
  on public.web_registrations (tournament_id, status);
create index if not exists idx_web_registrations_phone
  on public.web_registrations (phone_digits, created_at desc);

alter table public.web_registrations enable row level security;
revoke all on public.web_registrations from anon, authenticated;
grant select on public.web_registrations to authenticated;
grant update (status, admin_note, updated_at) on public.web_registrations to authenticated;

drop policy if exists "web_registrations staff read" on public.web_registrations;
create policy "web_registrations staff read" on public.web_registrations
  for select to authenticated
  using (public._is_admin() or public._has_access('tournaments'));
drop policy if exists "web_registrations staff update" on public.web_registrations;
create policy "web_registrations staff update" on public.web_registrations
  for update to authenticated
  using (public._is_admin() or public._has_access('tournaments'))
  with check (public._is_admin() or public._has_access('tournaments'));

-- 3. Proof bucket --------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('web-payment-proofs', 'web-payment-proofs', false, 5242880,
          array['image/jpeg','image/png','image/webp','image/heic','image/heif'])
  on conflict (id) do update
    set public = false,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

-- Insert only, under web/. No select/update/delete for anon: a visitor can't
-- list, read or overwrite anyone's screenshot (an upsert needs UPDATE).
drop policy if exists "web-payment-proofs upload" on storage.objects;
create policy "web-payment-proofs upload" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'web-payment-proofs' and name like 'web/%');
drop policy if exists "web-payment-proofs staff read" on storage.objects;
create policy "web-payment-proofs staff read" on storage.objects
  for select to authenticated
  using (bucket_id = 'web-payment-proofs'
         and (public._is_admin() or public._has_access('tournaments')));

-- 4. Read: tournaments open for web sign-up ------------------------------------
-- Same gates as register_for_tournament: not cancelled/finished, registration
-- opened, not closed by the organizer, before the 1-hour-before-start cutoff.
-- Egypt only for now (commerce + InstaPay are Egyptian).
create or replace function public.web_open_tournaments()
returns table (
  id uuid, name text, venue_name text, start_date date, start_time text,
  entry_fee numeric, category text, min_category text, max_category text,
  spots_left int)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  select t.id, t.name, t.venue_name, t.start_date, t.start_time,
         coalesce(t.entry_fee, 0)::numeric, coalesce(t.category, 'open'),
         t.min_category, t.max_category,
         case when coalesce(t.capacity, 0) <= 0 then null
              else greatest(0, t.capacity
                - (select count(*) from public.tournament_entries e
                    where e.tournament_id = t.id and e.status not in ('withdrawn', 'cancelled'))
                -- a pair takes a slot; two solo players make one pair
                - (select count(*) filter (where not w.needs_partner)
                          + ceil(count(*) filter (where w.needs_partner) / 2.0)
                     from public.web_registrations w
                    where w.tournament_id = t.id and w.status in ('pending', 'confirmed'))
                )::int
         end
    from public.tournaments t
   where coalesce(t.status, 'auto') not in ('cancelled', 'completed', 'in_progress')
     and coalesce(t.region_id, 'EG') = 'EG'
     and (t.registration_opens is null or current_date >= t.registration_opens)
     and not coalesce(t.registration_closed, false)
     and t.start_date >= current_date
     and (public.tournament_reg_deadline(t.start_date, t.start_time) is null
          or now() < public.tournament_reg_deadline(t.start_date, t.start_time))
   order by t.start_date, t.start_time nulls last;
end $$;
revoke all on function public.web_open_tournaments() from public;
grant execute on function public.web_open_tournaments() to anon, authenticated;

-- 5. Write: register a pair, or a solo player who needs a partner --------------
-- Errors are RAISEd with a sentence the website shows as-is.
-- p_needs_partner = true: no partner fields; they pay their own share
-- (entry_fee) and staff match them with another solo player in range.
-- The 11-argument first version is DROPPED, not left beside this one, so the
-- grant names one live signature and PostgREST never has two to choose from.
drop function if exists public.web_register(uuid, text, text, text, text, text, text, text, text, text, text);
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
  if v_due <= 0 then
    v_pay := 'free';
  else
    v_pay := 'instapay';                       -- InstaPay only; p_pay_method is ignored
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
              else 'New website entry' end,
         case when v_solo then v_name || ' (' || p_level || ', no partner yet)'
              else v_name || ' & ' || v_pname end
           || ' · ' || coalesce(v_t.name, 'tournament')
           || ' · ' || case v_pay when 'instapay' then 'InstaPay EGP ' || v_due::text
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
-- select * from public.web_open_tournaments();          -- open events
-- select id, name, min_category, max_category from public.tournaments
--  order by start_date desc limit 10;                    -- set levels here
-- select count(*) from public.web_registrations;        -- 0 on first run
-- select tournament_id, level, name, phone, created_at   -- solo players to match
--   from public.web_registrations
--  where needs_partner and status = 'pending' order by tournament_id, level;
