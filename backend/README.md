# Argus backend scripts

## Upload AI results to Supabase Storage

`upload_results.py` uploads one run of the AI pipeline (`ai/main.py`) to the
private `submissions` bucket, into the folder of the report (incident) the
files came from. The bucket and its access rules are made by migration
`database/supabase/migrations/20261009090000_submissions_bucket.sql`.

```
pip install -r backend/requirements.txt          # first time
copy backend\.env.example backend\.env           # then paste the service role key

cd ai
python main.py clip1.mp4 clip2.mp4
cd ..
python backend/upload_results.py "ai/crops/submission 3/results.json" --incident 42 --media 17 18
```

`--media` = the `media.mediaid` of each file, in the same order the files were
given to `main.py`. The script checks that they all belong to `--incident`.

Bucket layout, one folder per incident:

```
42/media/<file>                                   footage the citizen uploaded
42/ai/20261008T170155/results.json                the run (paths inside point into the bucket)
42/ai/20261008T170155/1_clip1/vehicle_3.png ...   its pictures, per file
```

* Results stay a JSON file: one submission can give hundreds of detections,
  far too many rows for a table. Each media row's `airesultpath` points at the
  newest `results.json`; `processingstatus` becomes `completed` (or `failed`
  for a file the pipeline couldn't analyse).
* A re-run gets a new folder, so earlier results are never overwritten.
* Who can read: admins, and investigators assigned to the case. Citizens can
  upload and see their own footage, never the `ai/` folder (it holds crops of
  other people's faces and plates). Nobody can overwrite or delete files from
  the app.
* `backend/.env` is git-ignored. The service key can read and write
  everything: keep it on the machine that runs the pipeline, never in the app.

## Tests

`tests/test_submissions_storage.py` checks the bucket, its access rules and
this script end to end against a local Supabase (needs Docker Desktop):

```
cd database
supabase start
supabase db reset
cd ..
python tests/test_submissions_storage.py
```

## AI worker (`worker.py`)

Runs on the GPU PC and does the jobs Supabase queues (database migrations
`20261012100000/100100/100200`): it **only makes outgoing connections** to
Supabase, so no ngrok / port forwarding is needed, wherever the team is.

| Job | What the worker does |
|---|---|
| `analyse` | downloads `<incident>/media/*`, runs the pipeline (`ai/main.py`), uploads crops + `results.json` (`upload_results.py`), saves the detections (`ai_save_analysis`) |
| `merge` | `ai_load_case` + `ai_load_submission` → `case_matcher.merge_submission` → `ai_save_case` |
| `rematch` | after an admin's "No, not Person 2": places that picture again (`case_matcher.place_member`) |
| `summary` | re-votes a case's people / vehicles / weapons and rewrites its AI summary |

```powershell
cd $HOME\Documents\Argus
.\.venv\Scripts\Activate.ps1
cd cit-event-capture
python backend\worker.py                 # keeps running; Ctrl+C to stop
python backend\worker.py --once          # do the waiting jobs, then stop
```

* Needs `backend\.env` with `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
  (optional `ARGUS_WORKER_ID=gpu-pc-1`, default = the PC's name).
* Sends a heartbeat every 30 s (`ai_worker_status()` → "AI worker online").
* A crashed / stopped worker's job goes back in the queue by itself (max 3 tries).
* Log: `backend\worker.log`. Temporary files: `backend\work\` (deleted after each job).

**Test it before the app's upload is finished:** `submit_test.py` sends files
as a new submission (incident + upload + media rows + queued analysis):

```powershell
python backend\submit_test.py ai\gunVid.mp4 ai\womanGun.jpg --location "N1 Midrand"
```

The worker picks it up within seconds; the submission then appears in the admin
app with its AI summary, and accepting it into a case fills the case's people /
vehicles / weapons.

**Automated test** (local Supabase database, real pipeline, no API key):
`python tests/test_worker.py` (see the top of that file).
