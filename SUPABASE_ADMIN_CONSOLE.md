# Supabase changes for the web admin console

**For:** whoever manages our Supabase project.
**Goal:** police-station admins + one root admin who manages them from the
web console in `web/admin-console/`.

Everything below is in the repo. Do the steps in order. About 15 minutes.

---

## What's new

| Piece | File | What it does |
|---|---|---|
| Table `admin` + functions | `database/supabase/migrations/20261018100000_admin_accounts.sql` | One row per admin: `userid` (FK → `"User"`), `admin_type` (`root` / `normal`), `admin_station`, `createdby`, `datecreated` |
| Edge Function `create-admin` | `database/supabase/functions/create-admin/index.ts` | Creates an admin's login with the service key. Only the root admin may call it |
| Function setting | `database/supabase/config.toml` (new `[functions.create-admin]` block) | `verify_jwt = false`, same as `create-investigator` (the function checks the caller itself) |
| Tests | `tests/test_admin_accounts_db.py` | Checks the rules against a local database |

### The `admin` table

```
admin
  userid        integer  PK, FK -> "User"(userid)  (user must have role 'admin';
                                                    deleting the user deletes the row)
  role          'admin'  (fixed; part of the FK, same pattern as investigator/citizen)
  admin_type    'root' | 'normal'   default 'normal'
  admin_station varchar(150)        e.g. 'Kempton Park SAPS'
  createdby     integer  FK -> "User"(userid), who created it
  datecreated   timestamptz
```

Rules the database enforces:

- There can be **at most one root admin** (unique index).
- Nobody can insert, edit or delete `admin` rows from the apps. Rows are made by
  the sign-up trigger. The station is changed with `set_admin_station()` (root only).
- An admin sees only their own row. The root admin sees all of them.
- New admin logins are always `normal`. A login can't make itself root through
  its metadata. Root is only ever set by hand (step 2).

### New database functions

| Function | Who | Used for |
|---|---|---|
| `current_admin()` | any signed-in user | The console checks you are root right after you sign in |
| `is_root_admin()` | any signed-in user | true / false |
| `list_admins()` | root only | The console's admin list (includes last sign-in) |
| `set_admin_station(userid, station)` | root only | "Change station" |
| `make_root_admin(username, station)` | **SQL Editor only** | One-off: make someone the root admin |

`handle_new_auth_user()` and `handle_auth_role_change()` are updated: when a
login with role `admin` is created, they also create its `admin` row, with the
station taken from `user_metadata.admin_station`.

**Existing admins** get an `admin` row automatically (type `normal`, station
`Unassigned`). The root admin can set their stations in the console.

---

## Step 1: Run the migration

**Option A, the CLI** (how the earlier migrations were applied), from the
`database/` folder:

```
supabase db push
```

That also applies `20261015100000_case_chat.sql` (the investigator chat) if it
hasn't been run yet.

**Option B, the dashboard:** Supabase → **SQL Editor** → New query → paste
the whole of `20261018100000_admin_accounts.sql` → **Run**. If the chat
migration isn't on the database yet, run `20261015100000_case_chat.sql` first
the same way.

**Check:** **Table Editor** shows a new `admin` table, with one row per
existing admin.

---

## Step 2: Make the root admin (once)

The root admin is an existing account, converted. Pick the username of the
person who will run the console.

- If they already have an admin account, use it.
- If they have none, register one in the mobile app (citizen sign-up).

Then in the **SQL Editor**:

```sql
SELECT public.make_root_admin('their_username', 'Argus HQ');
```

- A citizen account is converted to an admin automatically.
- Investigator accounts are refused. Use a separate account so their case
  work isn't affected.
- If someone is already root, you get a message showing how to demote them first:
  ```sql
  UPDATE public.admin SET admin_type = 'normal' WHERE admin_type = 'root';
  ```

**Check:**

```sql
SELECT u.username, a.admin_type, a.admin_station
FROM public.admin a JOIN public."User" u USING (userid);
```

---

## Step 3: Deploy the `create-admin` Edge Function

**Option A, the CLI,** from the `database/` folder:

```
supabase functions deploy create-admin
```

The `[functions.create-admin]` block in `config.toml` turns **Verify JWT**
off. That's intended: the function checks the caller (signed in **and** root
admin) itself with the service key.

**Option B, the dashboard:**

1. **Edge Functions** → **Deploy a new function** → name it exactly `create-admin`.
2. Paste the code from `database/supabase/functions/create-admin/index.ts`.
3. Deploy.
4. Open the function's settings and switch **Verify JWT (legacy)** **OFF**.

You don't need to add any secrets. `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` are available to Edge Functions automatically.

---

## Step 4: Try it

1. Serve the console: `cd web\admin-console` then `python -m http.server 8080`,
   and open <http://localhost:8080>. Or upload the folder to Netlify Drop.
2. Sign in with the root admin's username and password. You should see the
   admin list.
3. Sign in with a normal admin instead. You should get "Only the root
   administrator can sign in to this console."
4. Click **+ New admin**, fill it in and click **Generate** for a temporary
   password, then create it. The new admin can now sign in to the **mobile
   app** with that username and password (and should change the password).
5. Click **Change station** on one of the old admins that shows "Not set".

---

## If something goes wrong

| You see | Fix |
|---|---|
| "Only the root administrator can sign in" for the right person | Step 2 wasn't done for that username, or a different account is root. Run the check query in step 2 |
| "Could not find the function public.current_admin" or list errors | The migration (step 1) isn't on the database |
| "Failed to send a request to the Edge Function" / 404 on create | `create-admin` isn't deployed, or it has a different name (step 3) |
| Creating an admin says "Please sign in again" / 401 | **Verify JWT** is still on for `create-admin`: switch it off (step 3) |
| "An account with this email already exists" | That email already has a login (maybe as a citizen). Use another email |

## Optional: run the database tests locally

With the local Supabase running (`supabase start`, then `supabase db reset` in
`database/`):

```
python tests/test_admin_accounts_db.py
```

Expected output: `4/4 passed`.

---

## Not in this change (possible next steps)

- **Station-scoped admin screens.** Normal admins still see all submissions
  and cases in the mobile app. The `admin_station` column is now there to
  filter by station later.
- **Removing or disabling an admin.** Needs another small Edge Function (deleting
  logins needs the service key). For now: Supabase → Authentication → Users → delete.
