-- =====================================================================
--  SUPABASE SCHEMA — Barber Booking App
--  Run this whole file once in: Supabase Dashboard → SQL Editor → New query
-- =====================================================================

create extension if not exists "pgcrypto";

-- =====================================================================
--  TABLES
-- =====================================================================

-- One row per admin (you). Links to a Supabase Auth user.
create table if not exists admins (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz default now()
);

-- One row per barber. id = their Supabase Auth user id (they sign up themselves).
create table if not exists barbers (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  shop_name text not null,
  phone text,
  email text,
  active boolean not null default true,
  created_at timestamptz default now()
);

-- Single-use codes the admin generates and hands to a new barber.
create table if not exists invite_codes (
  code text primary key,
  created_by uuid references admins(id),
  used boolean not null default false,
  used_by uuid references barbers(id),
  created_at timestamptz default now(),
  used_at timestamptz
);

-- Each barber's service menu. Price is optional on purpose.
create table if not exists services (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references barbers(id) on delete cascade,
  name text not null,
  duration int not null default 30,
  price numeric,
  created_at timestamptz default now()
);

-- Per-weekday working hours, split into morning / afternoon / evening windows.
-- weekday: 0=Sunday .. 6=Saturday (JS Date.getDay() convention)
create table if not exists working_hours (
  barber_id uuid not null references barbers(id) on delete cascade,
  weekday int not null check (weekday between 0 and 6),
  is_working boolean not null default false,
  morning_enabled boolean not null default false,
  morning_start time,
  morning_end time,
  afternoon_enabled boolean not null default false,
  afternoon_start time,
  afternoon_end time,
  evening_enabled boolean not null default false,
  evening_start time,
  evening_end time,
  primary key (barber_id, weekday)
);

-- Days off / holidays.
create table if not exists blocked_dates (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references barbers(id) on delete cascade,
  date date not null,
  reason text,
  unique (barber_id, date)
);

-- Recurring / regular customers. service_chain is an ordered list of service ids
-- (as text) — the same service id can repeat (e.g. cut, cut, cut, beard).
create table if not exists permanent_clients (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references barbers(id) on delete cascade,
  name text not null,
  phone text,
  weekday int not null check (weekday between 0 and 6),
  time time not null,
  service_chain text[] not null default '{}',
  created_at timestamptz default now()
);

-- Every appointment: walk-ins, customer self-bookings, and the materialized
-- weekly occurrences of permanent clients all live here.
create table if not exists bookings (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references barbers(id) on delete cascade,
  customer_id text,
  name text not null,
  phone text,
  service_id uuid references services(id) on delete set null,
  service_name text,
  service_chain text[],
  duration int not null default 30,
  date date not null,
  time time not null,
  status text not null default 'چاوەڕوان' check (status in ('چاوەڕوان','تەواوبوو','دواخراوە','هەڵوەشاوە')),
  type text not null default 'کڕیار' check (type in ('کڕیار','سەردانکەر','هەمیشەیی')),
  permanent_client_id uuid references permanent_clients(id) on delete set null,
  created_at timestamptz default now(),
  unique (barber_id, permanent_client_id, date)
);
create index if not exists idx_bookings_barber_date on bookings(barber_id, date);
create index if not exists idx_bookings_customer on bookings(barber_id, customer_id);

-- =====================================================================
--  ROW LEVEL SECURITY
-- =====================================================================
alter table admins enable row level security;
alter table barbers enable row level security;
alter table invite_codes enable row level security;
alter table services enable row level security;
alter table working_hours enable row level security;
alter table blocked_dates enable row level security;
alter table permanent_clients enable row level security;
alter table bookings enable row level security;

-- ---------- helper: is the current logged-in user an admin? ----------
create or replace function is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from admins where id = auth.uid());
$$;

-- ---------- admins ----------
create policy admins_self_select on admins for select using (id = auth.uid());

-- ---------- barbers ----------
-- a barber can see/edit only their own row
create policy barbers_self_all on barbers for all
  using (id = auth.uid()) with check (id = auth.uid());
-- the admin can see and update (activate/deactivate) every barber
create policy barbers_admin_select on barbers for select using (is_admin());
create policy barbers_admin_update on barbers for update using (is_admin());
-- NOTE: there is intentionally no public select policy on this table.
-- Customers get barber info only through rpc_get_barber_public_info() below,
-- which exposes just name / shop_name / active — never phone or email.

-- ---------- invite_codes ----------
create policy invite_codes_admin_all on invite_codes for all
  using (is_admin()) with check (is_admin());

-- ---------- services (menu is meant to be public) ----------
create policy services_owner_all on services for all
  using (barber_id = auth.uid()) with check (barber_id = auth.uid());
create policy services_public_select on services for select using (true);

-- ---------- working_hours (public, so customers can see open days) ----------
create policy hours_owner_all on working_hours for all
  using (barber_id = auth.uid()) with check (barber_id = auth.uid());
create policy hours_public_select on working_hours for select using (true);

-- ---------- blocked_dates (public, so customers skip holidays) ----------
create policy blocked_owner_all on blocked_dates for all
  using (barber_id = auth.uid()) with check (barber_id = auth.uid());
create policy blocked_public_select on blocked_dates for select using (true);

-- ---------- permanent_clients (private — has customer name/phone) ----------
create policy perm_owner_all on permanent_clients for all
  using (barber_id = auth.uid()) with check (barber_id = auth.uid());

-- ---------- bookings (private — has customer name/phone) ----------
create policy bookings_owner_all on bookings for all
  using (barber_id = auth.uid()) with check (barber_id = auth.uid());
-- Anonymous customers never query this table directly — they use the
-- rpc_* functions below, which run with elevated rights but only ever
-- touch the one booking that belongs to them.

-- =====================================================================
--  PUBLIC / CUSTOMER-FACING FUNCTIONS  (security definer, tightly scoped)
-- =====================================================================

-- Safe public profile for the booking page header.
create or replace function rpc_get_barber_public_info(p_barber_id uuid)
returns table(barber_id uuid, name text, shop_name text, active boolean)
language sql security definer set search_path = public stable as $$
  select id, name, shop_name, active from barbers where id = p_barber_id;
$$;

-- Is this invite code still valid?
create or replace function rpc_validate_invite_code(p_code text)
returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from invite_codes where code = upper(p_code) and used = false);
$$;

-- Called once, right after a barber-to-be creates their Supabase Auth
-- account (email+password of their own choosing). Redeems the code and
-- creates their barber profile + blank weekly schedule.
create or replace function rpc_complete_barber_registration(
  p_code text, p_name text, p_shop_name text, p_phone text
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
begin
  if v_uid is null then
    raise exception 'تکایە سەرەتا هەژمارێک دروست بکە';
  end if;

  if not exists (select 1 from invite_codes where code = upper(p_code) and used = false) then
    raise exception 'کۆدی بانگهێشتنەکە هەڵەیە یان پێشتر بەکارهاتووە';
  end if;

  select email into v_email from auth.users where id = v_uid;

  insert into barbers (id, name, shop_name, phone, email, active)
  values (v_uid, p_name, p_shop_name, p_phone, v_email, true)
  on conflict (id) do update set
    name = excluded.name, shop_name = excluded.shop_name, phone = excluded.phone;

  update invite_codes set used = true, used_by = v_uid, used_at = now()
  where code = upper(p_code);

  insert into working_hours (barber_id, weekday, is_working)
  select v_uid, gs, false from generate_series(0,6) gs
  on conflict (barber_id, weekday) do nothing;

  return true;
end;
$$;

-- Internal: does a candidate slot overlap an existing booking or a
-- not-yet-materialized permanent client on that weekday?
create or replace function rpc_slot_conflicts(
  p_barber_id uuid, p_date date, p_weekday int, p_start time, p_duration int
) returns boolean
language plpgsql security definer set search_path = public stable as $$
declare
  v_end time := p_start + (p_duration || ' minutes')::interval;
  v_conflict boolean;
begin
  select exists (
    select 1 from bookings b
    where b.barber_id = p_barber_id and b.date = p_date
      and b.status <> 'هەڵوەشاوە'
      and b.time < v_end
      and (b.time + (b.duration || ' minutes')::interval) > p_start
  ) into v_conflict;
  if v_conflict then return true; end if;

  select exists (
    select 1 from permanent_clients pc
    where pc.barber_id = p_barber_id and pc.weekday = p_weekday
      and not exists (
        select 1 from bookings bb
        where bb.permanent_client_id = pc.id and bb.date = p_date
      )
      and pc.time < v_end
      and (pc.time + (
            coalesce((select sum(s.duration) from services s where s.id::text = any(pc.service_chain)), 30)
            || ' minutes')::interval) > p_start
  ) into v_conflict;

  return v_conflict;
end;
$$;

-- Returns available "HH:MM" start times for a given barber/date/service,
-- respecting that barber's per-day morning/afternoon/evening windows,
-- holidays, existing bookings and permanent-client slots.
create or replace function rpc_get_available_slots(
  p_barber_id uuid, p_date date, p_service_id uuid
) returns text[]
language plpgsql security definer set search_path = public stable as $$
declare
  v_weekday int := extract(dow from p_date)::int;
  v_duration int;
  v_wh working_hours%rowtype;
  v_slots text[] := '{}';
  v_step int := 15;
  v_periods text[] := array['morning','afternoon','evening'];
  v_p text;
  v_enabled boolean;
  v_start time;
  v_end time;
  t time;
begin
  select duration into v_duration from services where id = p_service_id and barber_id = p_barber_id;
  if v_duration is null then return '{}'; end if;

  if exists (select 1 from blocked_dates where barber_id = p_barber_id and date = p_date) then
    return '{}';
  end if;

  select * into v_wh from working_hours where barber_id = p_barber_id and weekday = v_weekday;
  if not found or not v_wh.is_working then return '{}'; end if;

  foreach v_p in array v_periods loop
    if v_p = 'morning' then
      v_enabled := v_wh.morning_enabled; v_start := v_wh.morning_start; v_end := v_wh.morning_end;
    elsif v_p = 'afternoon' then
      v_enabled := v_wh.afternoon_enabled; v_start := v_wh.afternoon_start; v_end := v_wh.afternoon_end;
    else
      v_enabled := v_wh.evening_enabled; v_start := v_wh.evening_start; v_end := v_wh.evening_end;
    end if;

    if v_enabled and v_start is not null and v_end is not null then
      t := v_start;
      while t + (v_duration || ' minutes')::interval <= v_end loop
        if not rpc_slot_conflicts(p_barber_id, p_date, v_weekday, t, v_duration) then
          v_slots := array_append(v_slots, to_char(t, 'HH24:MI'));
        end if;
        t := t + (v_step || ' minutes')::interval;
      end loop;
    end if;
  end loop;

  return v_slots;
end;
$$;

-- Creates a customer booking, re-checking the slot is still free
-- (protects against two people booking the same slot at once).
create or replace function rpc_create_booking(
  p_barber_id uuid, p_customer_id text, p_name text, p_phone text,
  p_service_id uuid, p_date date, p_time time
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_weekday int := extract(dow from p_date)::int;
  v_service services%rowtype;
  v_id uuid;
begin
  select * into v_service from services where id = p_service_id and barber_id = p_barber_id;
  if not found then raise exception 'ئەم خزمەتگوزارییە بوونی نییە'; end if;

  if rpc_slot_conflicts(p_barber_id, p_date, v_weekday, p_time, v_service.duration) then
    raise exception 'ببورە، یەکێک تر ئەم کاتەی گرت. تکایە کاتێکی تر هەڵبژێرە';
  end if;

  insert into bookings (barber_id, customer_id, name, phone, service_id, service_name, duration, date, time, status, type)
  values (p_barber_id, p_customer_id, p_name, p_phone, p_service_id, v_service.name, v_service.duration, p_date, p_time, 'چاوەڕوان', 'کڕیار')
  returning id into v_id;

  return v_id;
end;
$$;

-- A customer's own next upcoming booking (used to show the "you have a
-- booking" banner on the booking page, keyed by their local customer id).
create or replace function rpc_get_customer_upcoming(p_barber_id uuid, p_customer_id text)
returns table(booking_id uuid, service_name text, date date, time time)
language sql security definer set search_path = public stable as $$
  select id, service_name, date, time
  from bookings
  where barber_id = p_barber_id and customer_id = p_customer_id
    and status = 'چاوەڕوان' and date >= current_date
  order by date asc, time asc
  limit 1;
$$;

create or replace function rpc_cancel_by_customer(p_booking_id uuid, p_customer_id text)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update bookings set status = 'هەڵوەشاوە'
  where id = p_booking_id and customer_id = p_customer_id;
  return found;
end;
$$;

-- =====================================================================
--  PERMISSIONS
-- =====================================================================
grant usage on schema public to anon, authenticated;

grant select, insert, update, delete on barbers, services, working_hours, blocked_dates, permanent_clients, bookings to authenticated;
grant select, insert, update on admins, invite_codes to authenticated;

grant execute on function rpc_get_barber_public_info(uuid) to anon, authenticated;
grant execute on function rpc_validate_invite_code(text) to anon, authenticated;
grant execute on function rpc_complete_barber_registration(text,text,text,text) to authenticated;
grant execute on function rpc_get_available_slots(uuid,date,uuid) to anon, authenticated;
grant execute on function rpc_create_booking(uuid,text,text,text,uuid,date,time) to anon, authenticated;
grant execute on function rpc_get_customer_upcoming(uuid,text) to anon, authenticated;
grant execute on function rpc_cancel_by_customer(uuid,text) to anon, authenticated;
grant execute on function is_admin() to authenticated;

-- =====================================================================
--  ONE-TIME SETUP: turn your own Supabase Auth account into the admin
-- =====================================================================
-- 1. Supabase Dashboard → Authentication → Users → Add user
--    (enter your own email + a password you choose). Copy the User UID.
-- 2. Run this, with your own values:
--
--    insert into admins (id, email) values ('PASTE-USER-UID-HERE', 'you@example.com');
--
-- That's it — you can now log in to admin.html with that email/password.
