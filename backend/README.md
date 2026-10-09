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
