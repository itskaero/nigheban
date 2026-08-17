-- ============================================================
-- Nigehbān — v3 migration
-- Adds: SBAR before/after history, escalation now stores an
--       "action" step, and audit logs old→new SBAR text.
-- Run once after migrate_v2.sql. Safe on existing data.
-- ============================================================

-- ---------- SBAR change history (before/after snapshots) ----------
create table if not exists sbar_history (
  id          bigint generated always as identity primary key,
  patient_id  bigint,
  patient_name text,
  field       text,               -- dx | s | b | a | r
  old_text    text,
  new_text    text,
  changed_by  text,
  shift_tag   text,
  at          timestamptz default now()
);
create index if not exists sbar_hist_patient on sbar_history (patient_id, at desc);

alter table sbar_history enable row level security;
drop policy if exists "sbar read" on sbar_history;
create policy "sbar read" on sbar_history for select using (auth.role()='authenticated');
-- append-only: written by trigger (security definer), no client insert policy
alter publication supabase_realtime add table sbar_history;

-- ---------- escalation "action" ----------
-- esc jsonb now carries {trigger, action, who}. No schema change needed
-- (jsonb), but we update the audit trigger to render the action too.

-- ---------- richer audit trigger: SBAR old→new + escalation action ----------
create or replace function log_patient_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if (tg_op='DELETE') then
    insert into audit_log(patient_id,patient_name,action,detail,changed_by)
    values(old.id,old.name,'DELETE','Patient removed from '||old.bay,old.updated_by); return old;
  end if;
  who:=new.updated_by;
  if (tg_op='INSERT') then
    insert into audit_log(patient_id,patient_name,action,detail,changed_by)
    values(new.id,new.name,'INSERT','Admitted to '||new.bay||' ('||coalesce(new.score_system,'PEWS')||' '||new.news||')',who); return new;
  end if;

  if (new.bay is distinct from old.bay) then insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','bay','Shifted '||old.bay||' → '||new.bay,who); end if;
  if (new.sev is distinct from old.sev) then insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','sev','Acuity '||old.sev||' → '||new.sev,who); end if;
  if (new.news is distinct from old.news) then insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','news',coalesce(new.score_system,'score')||' '||old.news||' → '||new.news,who); end if;
  if (new.v_hr is distinct from old.v_hr or new.v_rr is distinct from old.v_rr or new.v_spo2 is distinct from old.v_spo2 or new.v_temp is distinct from old.v_temp) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','vitals','Vitals: HR '||coalesce(new.v_hr::text,'-')||' RR '||coalesce(new.v_rr::text,'-')||' SpO2 '||coalesce(new.v_spo2::text,'-')||' T '||coalesce(new.v_temp::text,'-'),who);
  end if;
  if (new.abx is distinct from old.abx) then insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','abx','Antibiotics: '||coalesce(new.abx->>'now','?')||case when (new.abx->>'esc')::boolean then ' (escalated)' else '' end,who); end if;
  if (new.esc is distinct from old.esc) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','esc',
      case when new.esc is null then 'Escalation cleared'
           else 'Escalation: if '||coalesce(new.esc->>'trigger','?')
                ||' → '||coalesce(new.esc->>'action','(action)')
                ||' → call '||coalesce(new.esc->>'who','?') end, who);
  end if;
  if (new.tasks is distinct from old.tasks) then insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','tasks','Tasks updated',who); end if;
  if (new.labs is distinct from old.labs) then insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','labs','Labs updated',who); end if;
  if (new.notes is distinct from old.notes) then insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','notes','Handover note added',who); end if;

  -- SBAR fields: log a before/after row into sbar_history for each changed field
  if (new.dx is distinct from old.dx) then
    insert into sbar_history(patient_id,patient_name,field,old_text,new_text,changed_by,shift_tag) values(new.id,new.name,'dx',old.dx,new.dx,who,new.shift_tag);
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','sbar','Diagnosis edited',who);
  end if;
  if (new.s_situation is distinct from old.s_situation) then
    insert into sbar_history(patient_id,patient_name,field,old_text,new_text,changed_by,shift_tag) values(new.id,new.name,'s',old.s_situation,new.s_situation,who,new.shift_tag);
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','sbar','Situation (S) edited',who);
  end if;
  if (new.b_background is distinct from old.b_background) then
    insert into sbar_history(patient_id,patient_name,field,old_text,new_text,changed_by,shift_tag) values(new.id,new.name,'b',old.b_background,new.b_background,who,new.shift_tag);
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','sbar','Background (B) edited',who);
  end if;
  if (new.a_assessment is distinct from old.a_assessment) then
    insert into sbar_history(patient_id,patient_name,field,old_text,new_text,changed_by,shift_tag) values(new.id,new.name,'a',old.a_assessment,new.a_assessment,who,new.shift_tag);
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','sbar','Assessment (A) edited',who);
  end if;
  if (new.r_recommend is distinct from old.r_recommend) then
    insert into sbar_history(patient_id,patient_name,field,old_text,new_text,changed_by,shift_tag) values(new.id,new.name,'r',old.r_recommend,new.r_recommend,who,new.shift_tag);
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by) values(new.id,new.name,'UPDATE','sbar','Recommendation (R) edited',who);
  end if;

  return new;
end $$;
-- trigger already exists and points at this function; nothing else to do.
