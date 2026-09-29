# Argus Shield — Database

This folder is the version-controlled record of the Argus Shield database. The live database runs on **Supabase Cloud** (PostgreSQL 17) and is managed with the **Supabase CLI**. Every change to it is made as a **migration** in this folder, so GitHub and Supabase always match.

> **Owner:** Carel von Ronge (database & GitHub). Talk to Carel before changing anything in this folder or in the Supabase dashboard.

**Contents**

1. [Folder layout](#folder-layout)
2. [Schema](#schema)
3. [Accounts, login and passwords](#accounts-login-and-passwords)
4. [Who can see and do what (RLS)](#who-can-see-and-do-what-rls)
5. [Database functions and triggers](#database-functions-and-triggers)
6. [Using the database from Flutter](#using-the-database-from-flutter)
7. [Migrations](#migrations)
8. [Workflow: making a database change](#workflow-making-a-database-change)
9. [Testing](#testing)
10. [Still to do](#still-to-do)
11. [Troubleshooting](#troubleshooting)

---

## Folder layout

```text
database/
├── README.md                  ← this file
└── supabase/                  ← run all Supabase CLI commands from database/
    ├── config.toml            ← Supabase CLI project configuration
    ├── migrations/            ← SQL migrations, applied in timestamp order
    └── functions/             ← Edge Functions (planned — see "Still to do")
```

Never put passwords, the database password, the service role / secret key or any other credential in this folder.

---

## Schema

### Users and roles

Everyone who uses the app has one row in `"User"`. Citizens and investigators have one extra row in their own sub-table with the details only they have. Admins have no extra details, so they only have a `"User"` row.

```text
auth.users  (Supabase Auth: email, hashed password, login sessions)
    │  authid
    ▼
"User"  (everyone: username, name, email, phone, role)
    ├──► citizen       (only when role = 'citizen')
    └──► investigator  (only when role = 'investigator')
```

**`"User"`** — note the capital U: the name must be written with quotes in SQL (`public."User"`), but in Flutter it is simply `.from('User')`.

| Column | Type | Notes |
|---|---|---|
| `userid` | integer, PK | Referenced by every other table (reportedby, uploadedby, assignedto…) |
| `authid` | uuid, unique | Link to `auth.users.id`. Set to empty if the login is deleted, so the evidence trail is kept |
| `username` | varchar(30) | Used to log in. Unique ignoring case. Letters, numbers, `_` and `.`, 3–30 characters |
| `firstname` | varchar(100) | |
| `surname` | varchar(100) | |
| `email` | varchar(150), unique | Copied from Supabase Auth and kept in sync automatically |
| `phonenumber` | varchar(20) | Optional |
| `role` | `user_role` enum | `citizen`, `investigator` or `admin` |
| `datecreated` | timestamptz | Set automatically |

**`citizen`**

| Column | Type | Notes |
|---|---|---|
| `userid` | integer, PK | Points to `"User"` |
| `role` | `user_role` | Always `citizen` (this is what stops a non-citizen having a citizen row) |
| `residence` | text | The registration screen should make this required |

**`investigator`**

| Column | Type | Notes |
|---|---|---|
| `userid` | integer, PK | Points to `"User"` |
| `role` | `user_role` | Always `investigator` |
| `rank` | varchar(50) | e.g. `Sgt.` |
| `badgenumber` | varchar(50), unique | e.g. `JHB-4471` |
| `station` | varchar(150) | e.g. `Kempton Park SAPS` |
| `unit` | varchar(100) | e.g. `CIT Task Force` |
| `dutystatus` | varchar(20) | `on_duty`, `available` (default) or `off_duty` |

The sub-tables point at `"User"` using **both** `userid` and `role`. Because of this the database guarantees that a citizen row only belongs to a citizen and an investigator row only to an investigator. To change someone's role, first delete their row from the old sub-table.

### Investigation tables

| Table | Holds | Links to |
|---|---|---|
| `crimescene` | A reported incident: location, date/time, attack type, status (`open`, `closed`, `under_review`), description | `reportedby` → User |
| `media` | Footage/photos uploaded to an incident: type (`image`, `video`, `audio`), storage path, file hash/size, timestamps, processing status (`pending`, `processing`, `completed`, `failed`) | `incidentid` → crimescene, `uploadedby` → User |
| `detection` | What the AI found in a media file: type (`vehicle`, `person`, `weapon`), frame time, bounding box, confidence, model version | `mediaid` → media |
| `vehicledetail` | Vehicle details for a vehicle detection: make, model, colour, number plate, plate confidence | `detectionid` → detection (one-to-one) |
| `suspect` | A person detection that an admin has confirmed as a suspect: physical/clothing description, behaviour | `detectionid` → detection, `incidentid` → crimescene, `confirmedby` → User |
| `correctionlog` | Audit trail of corrections to AI results (original and corrected value) | `detectionid` → detection, `correctedby` → User |
| `caseassignment` | Which investigator is assigned to which case, by whom, and the status (`active`, `reassigned`, `closed`) | `incidentid` → crimescene, `assignedto` / `assignedby` → User |
| `crossreferencelink` | Links the same vehicle or suspect across different incidents, with match confidence and verification status | `linkedby` → User |

See `diagrams/ERD.png` for the diagram (it still needs updating to show the `citizen` and `investigator` tables).

---

## Accounts, login and passwords

### Passwords are handled by Supabase Auth

Our tables never store passwords or login tokens. Supabase Auth keeps them in its own `auth.users` table (you can see accounts under **Dashboard → Authentication → Users**).

* The app sends the email and password straight to Supabase Auth (`signUp` / `signInWithPassword`).
* Supabase stores only a one-way hash of the password and checks it at login.
* On a successful login Supabase gives the app a session token (JWT). The Flutter SDK stores it, sends it with every request and refreshes it automatically.
* The database reads the token to know who is asking (`auth.uid()`), matches it to `"User".authid`, and the RLS policies decide what that person may see.

### How each type of account is created

| Account | How it is created | What the database does |
|---|---|---|
| **Citizen** | Registers in the app with `supabase.auth.signUp(...)`, sending `username`, `firstname`, `surname`, `phonenumber`, `residence` as sign-up data | The `on_auth_user_created` trigger creates the `"User"` row and the `citizen` row. **App sign-ups are always citizens** — a role sent from the app is ignored |
| **Investigator** | An admin fills in the "add investigator" screen, which calls the `create-investigator` Edge Function (see [Still to do](#still-to-do)) | The Edge Function creates the login with the service key and puts `role: investigator` in `app_metadata`, which only the service key can set. The trigger then creates the `"User"` and `investigator` rows. The investigator is emailed a code to set their own password |
| **Admin** | Manually, by the database owner (see below) | — |

**Creating an admin** (one-time, by the database owner):

1. **Dashboard → Authentication → Users → Add user** (email + password). The trigger creates them as a citizen.
2. In the **SQL editor**:
   ```sql
   DELETE FROM public.citizen
     WHERE userid = (SELECT userid FROM public."User" WHERE email = 'person@example.com');
   UPDATE public."User"
     SET role = 'admin', username = 'TheirUsername', firstname = 'First', surname = 'Last'
     WHERE email = 'person@example.com';
   ```
   The `DELETE` must run first — the database will not change the role while a citizen row exists.

### Logging in with a username

Supabase Auth logs in with an **email**, but our login screen asks for a **username**. The app first calls `email_for_username` to look up the email, then logs in with it. Trade-off: anyone who knows a username can find that user's email. If the team decides that is a problem, change the login field to Email and remove the function.

### Setting and resetting passwords

New investigators and anyone who taps **Forgot password?** receive an email with a 6-digit code (`resetPasswordForEmail`). The app verifies the code and lets them choose a new password. This needs:

* the **Reset Password** email template (Dashboard → Authentication → Emails) to include `{{ .Token }}`;
* a custom SMTP provider for real users — Supabase's built-in email only sends to the project team's own addresses, a few per hour.

---

## Who can see and do what (RLS)

Every table has row-level security (RLS) enabled. The app uses the **publishable (anon) key** plus the logged-in user's token, so each query automatically returns only the rows that user may see — the app does not need to filter by user itself.

| Table | Citizen | Investigator | Admin |
|---|---|---|---|
| `"User"` | Own row; may edit own username, name, phone | Own row and other investigators | All; may change roles |
| `citizen` | Own row; may edit residence | — | All |
| `investigator` | — | All investigators; may change **only** own `dutystatus` | All; may edit everything |
| `crimescene` | Report incidents as themselves; see those they reported | See and update cases they are **actively assigned** to | All |
| `media` | Upload to incidents they reported; see own uploads | See and upload to assigned cases | All |
| `detection` | — | Assigned cases (read-only) | All (read) |
| `vehicledetail` | — | Assigned cases; may correct details | All |
| `suspect` | — | Assigned cases (read-only) | Create, confirm, edit, delete |
| `correctionlog` | — | Assigned cases; add corrections as themselves (no edits/deletes) | All; add corrections |
| `caseassignment` | — | Own assignments | Assign, reassign, close |
| `crossreferencelink` | — | View, create, update | All, incl. delete |

* **Not logged in:** no access to any table. Only `email_for_username` and `username_available` can be called.
* **Nobody** (through the app) can insert or delete `"User"`, `citizen` or `investigator` rows — only the sign-up trigger creates them.
* The **Python AI/CV pipeline** uses the **service role (secret) key**, which bypasses RLS, to write `detection`/`vehicledetail` rows and update `media.processingstatus`. That key must **never** be in the Flutter app or on GitHub.

---

## Database functions and triggers

| Name | Type | What it does |
|---|---|---|
| `current_user_id()` | helper | The logged-in user's `userid` |
| `current_user_role()` | helper | The logged-in user's role as text |
| `is_assigned_to(incidentid)` | helper | True if the logged-in investigator has an active assignment on that case |
| `can_view_detection(detectionid)` | helper | True for admins, or investigators assigned to the detection's case |
| `handle_new_auth_user()` | trigger on `auth.users` insert | Creates the `"User"` row and the matching `citizen`/`investigator` row |
| `handle_auth_email_change()` | trigger on `auth.users` email update | Copies the new email into `"User".email` |
| `protect_user_columns()` | trigger on `"User"` update | Only admins may change `role`, `email`, `authid`, `userid`, `datecreated` |
| `protect_investigator_columns()` | trigger on `investigator` update | Non-admins may only change `dutystatus` |
| `email_for_username(username)` | callable before login | Returns the email for a username (any case), or null |
| `username_available(username)` | callable before login | True if nobody has that username yet (any case) |
| `rls_auto_enable()` | event trigger | Turns RLS on for every new table in `public` (the table still needs policies before the app can use it) |

---

## Using the database from Flutter

### Keys

Found under **Dashboard → Project Settings → API Keys**.

| Key | Where it goes |
|---|---|
| Project URL | Flutter app |
| **Publishable key** (`sb_publishable_…`) | Flutter app — safe to ship, RLS protects the data |
| **Secret / service_role key** | **Only** the Python pipeline and Edge Functions (as environment variables). Never in the app, never in Git |

```dart
await Supabase.initialize(
  url: 'https://<project-ref>.supabase.co',
  anonKey: 'sb_publishable_...',   // the publishable key goes in this parameter
);
final supabase = Supabase.instance.client;
```

### Registration (citizen)

```dart
final free = await supabase.rpc('username_available',
    params: {'p_username': username}) as bool;
if (!free) throw 'That username is taken';

final res = await supabase.auth.signUp(
  email: email,
  password: password,
  data: {
    'username': username,
    'firstname': firstname,
    'surname': surname,
    'phonenumber': phone,
    'residence': residence,
  },
);
// With "Confirm email" on, a duplicate email returns a user with no identities instead of an error
if (res.user != null && (res.user!.identities?.isEmpty ?? true)) {
  throw 'An account with this email already exists';
}
```

### Login and role

```dart
final email = await supabase.rpc('email_for_username',
    params: {'p_username': username}) as String?;
if (email == null) throw 'Invalid username or password';   // same message either way
await supabase.auth.signInWithPassword(email: email, password: password);

final profile = await supabase
    .from('User')
    .select('userid, username, firstname, surname, role')
    .eq('authid', supabase.auth.currentUser!.id)
    .single();
// profile['role'] -> 'citizen' | 'investigator' | 'admin'  → choose the dashboard

// Extra details for a citizen or investigator:
final details = await supabase
    .from(profile['role'] == 'investigator' ? 'investigator' : 'citizen')
    .select()
    .eq('userid', profile['userid'])
    .single();
```

### Set / reset password with the emailed code

```dart
await supabase.auth.resetPasswordForEmail(email);      // "Forgot password?" only
await supabase.auth.verifyOTP(type: OtpType.recovery, email: email, token: code);
await supabase.auth.updateUser(UserAttributes(password: newPassword));
```

### Errors to handle

| Situation | What Flutter receives |
|---|---|
| Wrong username or password | `AuthException` (invalid login credentials) |
| Weak password | `AuthWeakPasswordException` |
| Email already registered, "Confirm email" **off** | `AuthException` with code `user_already_exists` |
| Email already registered, "Confirm email" **on** | No error — check `identities` as shown above |
| Username taken / invalid (if not checked first) | `AuthException` "Database error saving new user" — always call `username_available` first |
| A query the user is not allowed to run | An empty list (RLS hides the rows) or a `PostgrestException` |

---

## Migrations

| Migration | What it does |
|---|---|
| `20260929072508_remote_schema.sql` | Baseline: all tables, constraints and indexes, pulled from Supabase Cloud |
| `20260929114152_auth_and_rls.sql` | Links `"User"` to Supabase Auth (`authid`), removes `passwordhash`, adds the helper functions, the sign-up trigger, column protection and all RLS policies |
| `20260929221626_user_role_tables.sql` | `role` becomes the `user_role` enum; adds `username`, `firstname`, `surname`, `phonenumber`; removes `fullname` and `badgenumber`; creates `citizen` and `investigator`; username helpers; email sync; investigator duty-status rule; their RLS policies |

---

## Workflow: making a database change

All Supabase commands run from `database/`. Git commands run from the repository root. Docker Desktop must be running.

### First-time setup

```bash
cd database
supabase login
supabase link --project-ref <project-ref>   # ask Carel for the project ref and database password
supabase migration list                     # every migration should show under both Local and Remote
```

### Step by step

1. **Branch** (from the repository root):
   ```bash
   git checkout main
   git pull
   git checkout -b database/short-description
   ```
2. **Check that GitHub and Supabase match** (from `database/`):
   ```bash
   supabase migration list    # Local and Remote columns must be identical
   supabase db pull           # should say "No schema changes found"
   ```
   If `db pull` writes a new file, someone changed the dashboard by hand. Read the file before continuing (see [Troubleshooting](#troubleshooting) for a known false alarm).
3. **Create the migration:**
   ```bash
   supabase migration new short_description
   ```
   Write the SQL in the new file under `supabase/migrations/`.
4. **(Optional) Test locally** on a throwaway database built from all migrations:
   ```bash
   supabase start
   supabase db reset
   supabase stop
   ```
5. **Dry run, then push** to Supabase Cloud:
   ```bash
   supabase db push --dry-run   # must list ONLY your new migration
   supabase db push
   supabase migration list      # your migration now shows under Local and Remote
   ```
6. **Commit and open a Pull Request** (from the repository root):
   ```bash
   git add database/supabase/migrations/
   git commit -m "Describe the database change"
   git push -u origin database/short-description
   ```

### Rules

* **Never** change tables, columns, policies or functions in the Supabase dashboard. Every change is a migration.
* **Never** edit a migration that has already been pushed — write a new one.
* A new table gets RLS turned on automatically but has **no policies**, so the app can't read it until policies are added in a migration.
* Only one person pushes migrations at a time — check with Carel first.
* Changing data (e.g. creating the first admin) in the SQL editor is fine. Changing **structure** is not.

---

## Testing

Test every database change by checking what each role can and cannot see.

**In the app:** log in as a citizen, an investigator and an admin, and confirm each sees only what the [RLS table](#who-can-see-and-do-what-rls) says.

**In the SQL editor**, you can pretend to be a user. Everything inside the transaction is undone at the end:

```sql
BEGIN;
-- 1. pick the user (must come before SET ROLE: logged-in users can't read auth.users)
SELECT set_config('request.jwt.claims',
  json_build_object('sub', (SELECT id FROM auth.users WHERE email = 'someone@example.com'),
                    'role', 'authenticated')::text, true);
-- 2. act as a logged-in user
SET LOCAL ROLE authenticated;

SELECT * FROM public."User";         -- what can this person see?
SELECT * FROM public.investigator;

ROLLBACK;
```

---

## Still to do

* **`create-investigator` Edge Function** — needed for the admin "add investigator" screen. It goes in `database/supabase/functions/create-investigator/index.ts` (the Supabase CLI deploys functions from `supabase/functions/`) and is deployed with `supabase functions deploy create-investigator`. Its code is ready; ask Carel.
* **Storage bucket for footage** — `media.storagepath` expects files in Supabase Storage, but no bucket or storage policies exist yet.
* **Email** — custom SMTP provider and the Reset Password template with `{{ .Token }}`.
* **Registration fields** — there is no registration wireframe yet. If citizens need more than residence (e.g. ID number, suburb, city), add columns to `citizen` in a new migration.
* **ERD** — update `diagrams/ERD.png` to show `citizen` and `investigator`, and to remove `fullName`, `passwordHash` and `badgeNumber` from USER.

---

## Troubleshooting

**`Bind for 0.0.0.0:54320 failed: port is already allocated`** (during `db pull`)
A temporary database from an earlier run is still running in Docker. In PowerShell:
```powershell
docker ps -a --filter "publish=54320" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
docker rm -f <the ID shown>
docker container prune -f
```

**`ports are not available ... 54320`** (Windows has reserved the port)
In an Administrator PowerShell: `net stop winnat` then `net start winnat`. Check reserved ranges with `netsh interface ipv4 show excludedportrange protocol=tcp`.

**`db pull` creates a file that only drops and re-adds the same CHECK constraints**
This is a false alarm from the Supabase CLI — nothing actually changed. Answer **No** to "Update remote migration history table?", delete the file (`Remove-Item supabase\migrations\<file>.sql`) and check `supabase migration list` shows only the real migrations.

**`Database error saving new user`** when signing up
The sign-up trigger rejected the data: usually a username that is taken or has invalid characters, or an investigator created without a badge number or station.

**Docker errors**
Make sure Docker Desktop is running and `docker info` works before any `supabase` command.
