-- ============================================================
-- Nigehbān — v4 migration: duty check-in model
-- Rules:
--   • Consultant = one per shift, covers ALL bays (bay = '*')
--   • Trainee   = one active per bay per shift (hand-off on emergency)
--   • Check-ins are scoped to a shift and auto-expire when the
--     shift changes.
--   • Manual check-out still supported.
-- Run once after migrate_v3.sql. Safe on existing data.
-- ============================================================

-- shift_date + shift_tag together identify "this shift" so we can
-- expire cleanly across day boundaries (e.g. Night spans midnight).
alter table checkins add column if not exists shift_date date;

-- Drop the old "one active row per doctor" index; we replace the
-- enforcement with a smarter server-side function below. (A doctor
-- still ends up with one active row, but we manage it in code so we
-- can also hand-off other people's rows.)
drop index if exists one_active_checkin;

-- Keep a partial unique index so a single doctor can't stack rows.
create unique index if not exists one_active_checkin
  on checkins (resident_id) where (active);

-- ------------------------------------------------------------
-- check_in(): the one entry point the app calls.
-- Handles consultant (ward-wide) vs trainee (per-bay hand-off),
-- clears the caller's own prior check-in, and stamps the shift.
-- SECURITY DEFINER so it can deactivate *other* people's rows
-- (hand-off) which RLS would otherwise forbid.
-- ------------------------------------------------------------
create or replace function check_in(
  p_bay        text,
  p_shift_tag  text,
  p_shift_date date,
  p_lat        numeric default null,
  p_lng        numeric default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  v_name text;
begin
  -- must be the logged-in user
  select role, coalesce(full_name, email) into v_role, v_name
    from residents where id = auth.uid();
  if v_role is null then v_role := 'trainee'; end if;

  -- 1) clear MY own existing active check-in (can't be in two places)
  update checkins set active = false
    where resident_id = auth.uid() and active;

  if v_role = 'consultant' then
    -- 2a) only one consultant per shift: hand off any other active
    --     consultant for this shift, then check in ward-wide ('*').
    update checkins set active = false
      where active and role = 'consultant'
        and shift_tag = p_shift_tag and shift_date = p_shift_date;
    insert into checkins(resident_id,resident_name,role,bay,shift_tag,shift_date,lat,lng,active)
      values (auth.uid(), v_name, 'consultant', '*', p_shift_tag, p_shift_date, p_lat, p_lng, true);
  else
    -- 2b) trainee: hand off any other active trainee in THIS bay
    --     for this shift (emergency takeover), then check in.
    update checkins set active = false
      where active and role = 'trainee' and bay = p_bay
        and shift_tag = p_shift_tag and shift_date = p_shift_date;
    insert into checkins(resident_id,resident_name,role,bay,shift_tag,shift_date,lat,lng,active)
      values (auth.uid(), v_name, 'trainee', p_bay, p_shift_tag, p_shift_date, p_lat, p_lng, true);
  end if;
end $$;

-- ------------------------------------------------------------
-- expire_old_shift(): deactivate any active check-in that does not
-- belong to the given current shift. The app calls this on load and
-- on shift change so stale rows disappear.
-- ------------------------------------------------------------
create or replace function expire_old_shift(
  p_shift_tag  text,
  p_shift_date date
) returns void
language plpgsql security definer set search_path = public as $$
begin
  update checkins set active = false
    where active
      and (shift_tag is distinct from p_shift_tag
           or shift_date is distinct from p_shift_date);
end $$;

-- allow logged-in users to call these RPCs
grant execute on function check_in(text,text,date,numeric,numeric) to authenticated, anon;
grant execute on function expire_old_shift(text,date) to authenticated, anon;
