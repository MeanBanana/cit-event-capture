# Supabase changes: Update / Delete investigators, Delete rejected submissions

In the admin app:

* **Investigators tab:** every investigator card has **Update** (change name,
  username, email, phone, police details, and optionally give a new temporary
  password) and **Delete** (removes the account).
* **Submissions tab:** a **rejected** submission has **Delete** (on its card and
  on its page). It deletes the submission, its footage and everything the AI
  found in it, for good.

Changing someone's log-in (email, password), deleting a log-in and deleting
footage files all need the **service key**, which must never be in the app.
So the app calls two new Edge Functions, which check that the caller is an
admin and then use the key on Supabase's servers.

Three things to do on Supabase (in this order).

---

## 1. Run the migration

**SQL Editor → New query**, paste the whole of
`database/supabase/migrations/20261020130000_admin_delete_investigator_and_submission.sql`,
click **Run** (or `supabase db push` from `database/`).

It adds two database functions that **only the service key** can call:

| Function | What it does |
| --- | --- |
| `remove_investigator_account(userid)` | Ends their active case assignments (the case history says so). If they never did anything on record, deletes their rows. Otherwise **anonymises** the account ("Former investigator", `deleted_<id>`, placeholder email, no phone, police details removed), so chat messages, corrections etc. stay in the case records as evidence. |
| `delete_rejected_submission(incidentid)` | Only for **rejected** submissions, and not while another submission is marked a duplicate of it. Deletes the submission, its files' rows, detections, vehicle / weapon details, suspects, corrections, AI jobs and its own history lines. |

## 2. Deploy the two Edge Functions

From the `database/` folder (Supabase CLI logged in and linked, as for
`create-investigator`):

```
supabase functions deploy manage-investigator
supabase functions deploy delete-submission
```

`config.toml` already has `verify_jwt = false` for both (they check the caller
themselves, like `create-investigator`). If you deploy from the dashboard
instead, switch **Verify JWT** off for both.

No new secrets: they use `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`, which
Supabase provides to every Edge Function.

## 3. Try it

1. Log in to the app as an admin → **Investigators** → **Update** on a test
   investigator → change the phone → **Save changes**. Then give a new
   temporary password: the investigator is asked to choose their own at the
   next log-in.
2. **Delete** a test investigator who has never been assigned a case: the
   account disappears and their email/username can be used again.
3. **Submissions** → filter **Rejected** → **Delete** on a test submission.
   Its folder in **Storage → submissions** is gone too.

## If something goes wrong

| Message | Cause |
| --- | --- |
| "This feature is not set up on the server yet." | The Edge Function isn't deployed (step 2) |
| "Please log in again." (401) | **Verify JWT** is still on for the function: switch it off |
| "The account could not be deleted" / "could not be deleted" | The migration (step 1) isn't on the database. See **Edge Functions → Logs** |
| "Only rejected submissions can be deleted" | It's pending, accepted or a duplicate: reject it first |
| "… are marked as duplicates of this one" | Reopen or delete those duplicates first |
| "The submission was deleted, but some of its files could not be removed" | Run `backend/cleanup_storage.py --yes` on the worker PC; it removes folders of submissions that no longer exist |

## Database tests (optional)

```
python tests/test_admin_deletes_db.py
```

Expected: `5 passed, 0 failed`.
