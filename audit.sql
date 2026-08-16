-- ============================================================
-- Ward Handover — Audit trail add-on
-- Run this AFTER schema.sql, once, in Supabase → SQL Editor.
-- Safe to run on an existing project; it only adds new objects.
-- ============================================================

-- Append-only log of every change to a patient row.
create table if not exists audit_log (
  id          bigint generated always as identity primary key,
  patient_id  bigint,                    -- may point to a now-deleted patient
  patient_name text,                     -- snapshot so log stays readable after discharge
  action      text not null,             -- INSERT | UPDATE | DELETE
  field       text,                      -- which logical field changed (for UPDATEs)
  detail      text,                      -- human-readable summary of the change
  changed_by  text,                      -- updated_by from the row, i.e. the resident
  at          timestamptz not null default now()
);

create index if not exists audit_patient_idx on audit_log (patient_id);
create index if not exists audit_at_idx on audit_log (at desc);

-- ------------------------------------------------------------
-- Trigger function: turn each row change into readable log lines.
-- Runs inside the DB, so NOTHING can bypass it — the frontend
-- cannot forge, skip, or edit history.
-- ------------------------------------------------------------
create or replace function log_patient_change()
returns trigger language plpgsql as $$
declare
  who text;
begin
  if (tg_op = 'DELETE') then
    insert into audit_log(patient_id, patient_name, action, detail, changed_by)
    values (old.id, old.name, 'DELETE', 'Patient removed from '||old.bay, old.updated_by);
    return old;
  end if;

  who := new.updated_by;

  if (tg_op = 'INSERT') then
    insert into audit_log(patient_id, patient_name, action, detail, changed_by)
    values (new.id, new.name, 'INSERT', 'Admitted to '||new.bay||' ('||coalesce(new.sev,'stable')||', NEWS '||new.news||')', who);
    return new;
  end if;

  -- UPDATE: log only the fields that actually changed, one line each.
  if (new.bay is distinct from old.bay) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','bay','Shifted '||old.bay||' → '||new.bay,who);
  end if;
  if (new.sev is distinct from old.sev) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','sev','Acuity '||old.sev||' → '||new.sev,who);
  end if;
  if (new.news is distinct from old.news) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','news','NEWS '||old.news||' → '||new.news,who);
  end if;
  if (new.esc is distinct from old.esc) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','esc',
      case when new.esc is null then 'Escalation plan cleared'
           else 'Escalation set: if '||coalesce(new.esc->>'trigger','?')||' → call '||coalesce(new.esc->>'who','?') end, who);
  end if;
  if (new.tasks is distinct from old.tasks) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','tasks',
      'Tasks updated ('||coalesce(jsonb_array_length(old.tasks),0)||' → '||coalesce(jsonb_array_length(new.tasks),0)||' items)',who);
  end if;
  if (new.labs is distinct from old.labs) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','labs',
      'Labs updated ('||coalesce(jsonb_array_length(old.labs),0)||' → '||coalesce(jsonb_array_length(new.labs),0)||' items)',who);
  end if;
  if (new.notes is distinct from old.notes) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','notes','Handover note added',who);
  end if;
  if (new.abx is distinct from old.abx) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','abx','Antibiotics/support changed',who);
  end if;
  if (new.r_recommend is distinct from old.r_recommend
      or new.s_situation is distinct from old.s_situation
      or new.dx is distinct from old.dx) then
    insert into audit_log(patient_id,patient_name,action,field,detail,changed_by)
    values(new.id,new.name,'UPDATE','sbar','SBAR / plan edited',who);
  end if;

  return new;
end $$;

drop trigger if exists patients_audit on patients;
create trigger patients_audit
  after insert or update or delete on patients
  for each row execute function log_patient_change();

-- ------------------------------------------------------------
-- RLS: allow reading the log; block edits/deletes so history
-- is append-only even for the anon key. (The trigger writes it
-- with elevated rights, so no anon INSERT policy is needed.)
-- ------------------------------------------------------------
alter table audit_log enable row level security;

drop policy if exists "audit read" on audit_log;
create policy "audit read" on audit_log for select using (true);
-- deliberately NO insert/update/delete policies → clients cannot tamper.

-- Realtime for the audit view (optional but nice — live log).
alter publication supabase_realtime add table audit_log;
