-- ============================================================
-- Ward Handover — Supabase schema
-- Run this once in Supabase → SQL Editor → New query → Run
-- ============================================================

-- One row per patient currently on the ward.
create table if not exists patients (
  id           bigint generated always as identity primary key,
  bay          text not null,                 -- measles | general | hdu | nursery | picu | nicu
  name         text not null,
  bed          text,
  age          text,
  sev          text not null default 'stable',-- stable | watch | sick
  news         int  not null default 0,
  dx           text,
  s_situation  text,
  b_background text,
  a_assessment text,
  r_recommend  text,
  vitals       jsonb default '[]'::jsonb,      -- [["HR","148","warn"], ...]
  abx          jsonb default '{"past":[],"now":"None","esc":false}'::jsonb,
  tasks        jsonb default '[]'::jsonb,       -- [{"t":"...","w":"AM","o":"Ali","done":false}]
  labs         jsonb default '[]'::jsonb,       -- [{"t":"CRP","s":"pending","w":"due AM"}]
  notes        jsonb default '[]'::jsonb,       -- [{"txt":"...","who":"Dr Ali","time":"14:32"}]
  esc          jsonb,                           -- {"trigger":"SpO2<90","who":"PICU"} or null
  flags        jsonb default '[]'::jsonb,       -- ["abx","o2","lab","shift"]
  updated_at   timestamptz default now(),
  updated_by   text
);

create index if not exists patients_bay_idx on patients (bay);

-- Keep updated_at fresh on every write.
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists patients_touch on patients;
create trigger patients_touch before update on patients
  for each row execute function touch_updated_at();

-- ------------------------------------------------------------
-- Row Level Security
-- Internal ward tool: the anon key may read/write.
-- (The ward password in the app is a soft gate, NOT real auth —
--  anyone with the anon key can reach these tables. For a real
--  hospital deployment, switch to Supabase Auth + per-user policies.)
-- ------------------------------------------------------------
alter table patients enable row level security;

drop policy if exists "anon read"   on patients;
drop policy if exists "anon insert" on patients;
drop policy if exists "anon update" on patients;
drop policy if exists "anon delete" on patients;

create policy "anon read"   on patients for select using (true);
create policy "anon insert" on patients for insert with check (true);
create policy "anon update" on patients for update using (true);
create policy "anon delete" on patients for delete using (true);

-- ------------------------------------------------------------
-- Realtime: broadcast row changes to subscribed phones
-- ------------------------------------------------------------
alter publication supabase_realtime add table patients;

-- ------------------------------------------------------------
-- Seed data (optional — delete this block for an empty ward)
-- ------------------------------------------------------------
insert into patients (bay,name,bed,age,sev,news,dx,s_situation,b_background,a_assessment,r_recommend,vitals,abx,tasks,labs,flags) values
('picu','Ahmed R.','P-2','3y M','sick',8,'Septic shock, on inotropes',
 'Noradrenaline 0.3, ventilated & sedated.','D2 septic shock, cultures sent, LDH 980.','Lactate 3.1 to 2.2, perfusion improving.','Wean inotrope if MAP holds; lactate 2-hrly.',
 '[["HR","148","warn"],["RR","vent","na"],["SpO2","96","ok"],["MAP","58","ok"],["T","38.4","warn"]]',
 '{"past":["Ceftriaxone"],"now":"Meropenem + Vanc","esc":true}',
 '[{"t":"Repeat lactate","w":"06:00","o":"Ali","done":false},{"t":"Chase blood C/S","w":"AM","o":"Lab","done":false}]',
 '[{"t":"Lactate","s":"pending","w":"sent 04:00"},{"t":"Blood C/S","s":"pending","w":"D2 no growth"},{"t":"ABG","s":"result","w":"pH 7.31"}]',
 '["abx","o2"]'),
('picu','Sana F.','P-4','8m F','watch',5,'Bronchiolitis, CPAP',
 'CPAP 6/40%, comfortable.','RSV +ve, D3, Na 129.','Work of breathing settling.','Trial off CPAP AM; recheck Na.',
 '[["HR","132","ok"],["RR","44","warn"],["SpO2","94","ok"],["MAP","-","na"],["T","37.2","ok"]]',
 '{"past":[],"now":"None","esc":false}',
 '[{"t":"Recheck serum Na","w":"AM","o":"Ali","done":false},{"t":"Trial off CPAP","w":"Round","o":"Cons","done":false}]',
 '[{"t":"Serum Na","s":"pending","w":"due AM"},{"t":"RSV panel","s":"result","w":"+ve"}]',
 '["o2"]'),
('hdu','Bilal K.','H-1','5y M','watch',6,'Severe pneumonia',
 'O2 4L NC, mild distress.','D2 IV abx, CRP 180.','Sats borderline on exertion.','PICU + HFNC if SpO2<90.',
 '[["HR","128","ok"],["RR","40","warn"],["SpO2","91","warn"],["MAP","-","na"],["T","38.9","bad"]]',
 '{"past":["Amoxclav"],"now":"Cefotaxime","esc":true}',
 '[{"t":"Reassess O2","w":"2-hrly","o":"Ali","done":false},{"t":"PICU bed standby","w":"now","o":"Ali","done":false}]',
 '[{"t":"CRP","s":"result","w":"180 up"},{"t":"CXR","s":"pending","w":"ordered"}]',
 '["abx","o2","shift"]'),
('hdu','Ayesha M.','H-3','2y F','stable',2,'AGE + dehydration, improving',
 'Tolerating orals, IV weaning.','D2, K was 3.1 corrected.','Rehydrated, UO good.','Step down to General; stop IV.',
 '[["HR","110","ok"],["RR","24","ok"],["SpO2","99","ok"],["MAP","-","na"],["T","37.0","ok"]]',
 '{"past":[],"now":"None","esc":false}',
 '[{"t":"Stop IV fluids","w":"if orals ok","o":"Ali","done":true},{"t":"Move to General","w":"AM","o":"Ali","done":false}]',
 '[{"t":"Serum K","s":"result","w":"3.9"}]',
 '["shift"]'),
('measles','Hamza T.','M-1','4y M','watch',4,'Measles + pneumonia',
 'Rash fading, O2 2L.','Vit A given, D3 abx.','Feeding poorly.','Wean O2; barrier nursing.',
 '[["HR","122","ok"],["RR","34","warn"],["SpO2","93","warn"],["MAP","-","na"],["T","38.2","warn"]]',
 '{"past":[],"now":"Ampicillin","esc":false}',
 '[{"t":"2nd dose Vit A","w":"AM","o":"Ali","done":false},{"t":"Wean O2","w":"Round","o":"Cons","done":false}]',
 '[{"t":"CBC","s":"result","w":"WBC 4.2"}]',
 '["abx","o2"]'),
('general','Fatima Z.','G-7','6y F','stable',1,'Enteric fever, afebrile 24h',
 'Well, eating.','D5 ceftriaxone.','Recovering.','D/C tomorrow; switch oral cefixime.',
 '[["HR","96","ok"],["RR","20","ok"],["SpO2","99","ok"],["MAP","-","na"],["T","36.9","ok"]]',
 '{"past":["Ceftriaxone IV"],"now":"oral cefixime","esc":false}',
 '[{"t":"Discharge meds","w":"AM","o":"Ali","done":false}]',
 '[{"t":"Blood C/S","s":"result","w":"S. typhi"}]',
 '["abx"]'),
('nicu','Baby Areej','N-3','D4 M','watch',3,'Preterm 33wk, ?sepsis',
 'NCPAP, feeds via OGT.','CRP borderline, abx D2.','Stable, apnoea x1.','Repeat CRP; caffeine.',
 '[["HR","160","ok"],["RR","52","warn"],["SpO2","95","ok"],["MAP","-","na"],["T","36.8","ok"]]',
 '{"past":[],"now":"Amp + Gent","esc":false}',
 '[{"t":"Repeat CRP","w":"AM","o":"Ali","done":false},{"t":"Start caffeine","w":"now","o":"Ali","done":false}]',
 '[{"t":"CRP","s":"pending","w":"due AM"},{"t":"Blood C/S","s":"pending","w":"D2"}]',
 '["abx"]'),
('nursery','Baby Noor','Nu-5','D2 F','stable',0,'Neonatal jaundice, phototherapy',
 'Under lights, feeding well.','TSB 16, no risk factors.','Improving.','Repeat TSB 12h; stop if <13.',
 '[["HR","140","ok"],["RR","44","ok"],["SpO2","98","ok"],["MAP","-","na"],["T","36.9","ok"]]',
 '{"past":[],"now":"None","esc":false}',
 '[{"t":"Repeat TSB","w":"18:00","o":"Ali","done":false}]',
 '[{"t":"TSB","s":"pending","w":"12-hrly"}]',
 '["lab"]');
