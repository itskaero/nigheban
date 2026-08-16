# Nigehbān (نگہبان) — Ward Handover · setup (about 10 minutes)

*Har shift, ek nigehbān — every shift, a guardian.*

A single-file, mobile-first paediatric handover app. Static frontend + Supabase (free) backend with per-resident login and live sync between phones.

You get these files:
- `index.html` — the whole app
- `schema.sql` — creates the database table + realtime + seed data
- `audit.sql` — adds the audit-trail table + trigger (run after schema.sql)
- `auth.sql` — switches the ward to per-resident email login (run last)
- `SETUP.md` — this file

The app works **immediately in demo mode** (open `index.html`, passcode `ward123`) — but demo mode does **not save**. Follow the steps below to go live.

---

## 1. Create a free Supabase project
1. Go to supabase.com → sign in → **New project**.
2. Pick a name, a strong database password, and the region closest to you (Singapore/Mumbai are nearest to Pakistan). Free tier is fine.
3. Wait ~2 min for it to provision.

## 2. Install the database
1. In your project: left sidebar → **SQL Editor** → **New query**.
2. Open `schema.sql`, copy everything, paste it in, click **Run**.
3. You should see "Success". This creates the `patients` table, security rules, realtime, and 8 seed patients.
   - Want to start empty? Delete the `insert into patients ...` block at the bottom before running.

## 2b. Add the audit trail (recommended)
1. SQL Editor → **New query**.
2. Open `audit.sql`, paste, **Run**.
3. This adds an append-only `audit_log` table and a database trigger that records every change (admit, shift, acuity change, escalation, task/lab/note edit, discharge) with who and when. It's written **inside the database**, so the app can't forge or skip entries. View it in the app's **History** tab, or per-patient from Edit → "View this patient's history".

## 2c. Turn on per-resident login
1. SQL Editor → **New query** → paste `auth.sql` → **Run**.
   This adds a `residents` profile table (auto-filled on signup) and swaps the database rules from "anyone with the key" to "must be a logged-in resident." The audit log now records each resident's real name from their verified account.
2. In the dashboard: **Authentication → Providers → Email** → make sure Email is enabled.
   - For quickest testing, turn **off** "Confirm email" so new accounts work immediately. For real use, leave confirmation on.
3. **Strongly recommended for a real ward:** once your residents have registered, turn **off** "Enable signups" (same Providers → Email screen) and add any new people via **Authentication → Users → Add user**. That way only invited emails can ever log in.

## 3. Get your two keys
1. Left sidebar → **Project Settings** (gear) → **API**.
2. Copy:
   - **Project URL** (looks like `https://abcdxyz.supabase.co`)
   - **anon public** key (a long string under "Project API keys")

## 4. Paste keys into the app
Open `index.html`, find this block near the top:

```js
const CONFIG = {
  SUPABASE_URL:  "",            // paste Project URL here
  SUPABASE_ANON: "",            // paste anon public key here
  WARD_INVITE:   "PAEDS2026"    // code residents type once when creating an account — change this
};
```

Fill in the three values. Save. Open the file — you'll see the **login screen**. Create your account (using the invite code), and the header dot turns **green ("Live · synced")**.

## 5. Put it online (so residents open it on their phones)
Any static host works, all free. Easiest options:

**Netlify Drop (no account needed to test):**
- Go to app.netlify.com/drop → drag `index.html` in → you get a public URL.

**GitHub Pages:**
- New repo → upload `index.html` (rename nothing) → Settings → Pages → deploy from `main` branch, root. URL appears in a minute.

Share the URL. On a phone, use the browser's **"Add to Home Screen"** to make it feel like an app (it's already configured for full-screen).

---

## How it works day to day
- **Login**: each resident signs in with their own email + password. Their name is attached to everything they change, so the audit trail shows real identities. "Sign out" is under the **Me** tab.
- **Bays** across the top (Measles, General, HDU, Nursery, PICU, NICU) — tap to switch. Red dot = has a sick patient.
- **Cards** sort sickest-first by NEWS. Tap to expand: vitals, SBAR, antibiotic ladder, tasks, labs, escalation plan.
- **Everything you type saves to Supabase and appears on every other phone within a second** (live sync).
- **+ button** adds a patient. **Edit** (pencil) changes acuity/NEWS/SBAR or discharges (removes) a patient.
- **Tasks / labs**: type in the inline field + Enter. Tap a lab row to flip pending ↔ result.
- **Escalate**: set a trigger ("if SpO₂<90") + who to call — locks a red banner on the card.
- **Shift**: move a patient between bays; the change syncs everywhere.

## About the keys and security

**The anon key in the CONFIG block is meant to be public — leave it there.**
Supabase's anon/publishable key is a scoped, publishable identifier, not a secret. Your data is protected by **Row Level Security policies + login**, not by hiding the key. This is Supabase's intended design.

**With `auth.sql` applied, the ward is locked to logged-in residents.** The anon key alone can no longer read or write patient data — every request must carry a valid resident session. That's the real security boundary.

**GitHub Secrets won't help — and here's why.**
GitHub Secrets are *build-time* secrets for server-side pipelines. This app is a static file that runs in the browser, so anything it uses to reach the database must be delivered to the browser in plaintext (View Source shows everything). There is no way to hide a client-side key, and you don't need to — security comes from RLS + auth. The only key that must **never** appear in a frontend is the Supabase **service-role** key (the admin key that bypasses RLS); this app never uses it.

**Two gates, strongest first:**
1. **Best:** after your residents register, disable public signups (Authentication → Providers → Email → "Enable signups" off) and add people via Authentication → Users. Only invited emails can log in.
2. **Lighter:** keep signups on but require the `WARD_INVITE` code (set in CONFIG) at registration. Fine for getting started; move to option 1 for real use.

**Patient identifiers:** even with login, treat this as an internal handover board, not the hospital record. Use first name + bed (like the seed data) rather than full legal names / MRN, unless your unit's governance explicitly permits it.

**Audit trail** is append-only even for logged-in users (no insert/update/delete policy on `audit_log`), so history can't be quietly altered.

## Troubleshooting
- **Login screen never appears, goes straight to demo** → URL or anon key is blank in CONFIG. Re-check step 4.
- **"Invalid login credentials"** → wrong email/password, or the account needs email confirmation (check inbox, or disable "Confirm email" in Auth settings for testing).
- **Signup says "Wrong ward invite code"** → the code typed doesn't match `WARD_INVITE` in CONFIG.
- **Signed in but no patients load / red dot** → `auth.sql` may not have run, so the policies still block you. Re-run `schema.sql`, `audit.sql`, then `auth.sql` in that order.
- **Changes don't sync between phones** → make sure `alter publication supabase_realtime add table patients;` ran (it's in schema.sql).
