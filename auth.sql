-- ============================================================
-- Ward Handover — Per-resident auth upgrade
-- Run this AFTER schema.sql and audit.sql.
-- This locks the ward data to logged-in residents only.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Resident profiles (one row per auth user)
--    Auto-created on signup via a trigger on auth.users.
-- ------------------------------------------------------------
create table if not exists residents (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  created_at timestamptz default now()
);

alter table residents enable row level security;

drop policy if exists "residents read"   on residents;
drop policy if exists "residents self"   on residents;
create policy "residents read" on residents
  for select using (auth.role() = 'authenticated');
create policy "residents self" on residents
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- Populate a profile row automatically when someone signs up.
create or replace function handle_new_resident()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.residents(id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.email))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_resident();

-- ------------------------------------------------------------
-- 2. Replace the open "anon" policies on patients with
--    authenticated-only policies.
-- ------------------------------------------------------------
drop policy if exists "anon read"   on patients;
drop policy if exists "anon insert" on patients;
drop policy if exists "anon update" on patients;
drop policy if exists "anon delete" on patients;

drop policy if exists "auth read"   on patients;
drop policy if exists "auth insert" on patients;
drop policy if exists "auth update" on patients;
drop policy if exists "auth delete" on patients;

create policy "auth read"   on patients for select using (auth.role() = 'authenticated');
create policy "auth insert" on patients for insert with check (auth.role() = 'authenticated');
create policy "auth update" on patients for update using (auth.role() = 'authenticated');
create policy "auth delete" on patients for delete using (auth.role() = 'authenticated');

-- ------------------------------------------------------------
-- 3. Audit log: readable by logged-in residents, still
--    append-only (no client insert/update/delete policy).
-- ------------------------------------------------------------
drop policy if exists "audit read" on audit_log;
create policy "audit read" on audit_log
  for select using (auth.role() = 'authenticated');

-- ------------------------------------------------------------
-- 4. (RECOMMENDED) Turn off open public signups.
--    Do this in the dashboard, not SQL:
--      Authentication → Providers → Email → disable "Enable signups"
--    Then invite each resident:
--      Authentication → Users → Add user (send invite email).
--    This is the strongest gate — only invited emails can ever log in.
--    The app also has a ward invite code on its signup form as a
--    lighter alternative if you prefer to keep signups on for now.
-- ------------------------------------------------------------
