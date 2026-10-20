# AI pipeline in Supabase

How the AI worker, the database and the app work together. This is what was
built from `SUPABASE_AI_PIPELINE.md`; the differences from that plan (and why)
are at the end.

Migrations:

| Migration | What it does |
|---|---|
| `20261012100000_ai_pipeline_tables.sql` | pgvector; tables `aijob`, `aiworker`, `caseentity`, `entitymatchrejection`; new columns on `detection`, `weapondetail`, `crimescene`, `media`, `cases`; RLS |
| `20261012100100_ai_pipeline_functions.sql` | the job queue, the worker's save / load functions, `get_case_evidence`, `answer_entity_match`, the triggers, `list_cases` + case AI summary, privileges |
| `20261012100200_case_suggestion_rule.sql` | the new suggestion rule in `match_incidents()` (1 km, 14 days, or same plate) |

```
Citizen app                Database                          AI worker (service key)
upload 1-5 files
submit_for_analysis(42) -> aijob 'analyse' 42
                                                  <- claim_next_job('gpu-laptop')
                                                     download 42/media/*, run pipeline,
                                                     upload_results.py (crops + results.json)
                           detection rows         <- ai_save_analysis(42, results.json)
                                                  <- finish_job(jobid)
Admin accepts           -> crimescene.caseid = 7
                           trigger: aijob 'merge' 42 -> 7
                                                  <- claim_next_job
                                                  <- ai_load_case(7), ai_load_submission(42)
                                                     case_matcher.merge_submission()
                           caseentity + links     <- ai_save_case(7, case)
Admin opens the case    -> get_case_evidence(7)
"Is this Person 2?"     -> answer_entity_match(detectionid, yes/no)  (No -> aijob 'rematch')
Removed from the case   -> its pictures leave the case immediately    (-> aijob 'summary')
```

No public URL / ngrok is needed: the worker only makes outgoing calls to Supabase.

---

## For the AI worker

The worker uses the **service role key** (`backend/.env`, like `upload_results.py`).
Every call is an RPC; each save is one transaction.

| Function | What it does |
|---|---|
| `claim_next_job(p_workerid)` | The oldest waiting job (a list with 0 or 1 row). Also counts as a heartbeat |
| `finish_job(p_jobid, p_error)` | Done (`p_error` empty) or failed. A failed job is retried up to 3 times |
| `ai_worker_heartbeat(p_workerid, p_gpu, p_version)` | "I'm alive" — call every ~30 s from a background thread |
| `ai_save_analysis(p_incidentid, p_result, p_summary)` | Saves one run: `p_result` = the results.json **as uploaded** by `upload_results.py` (bucket paths, `mediaid` per file); `p_summary` = the submission's summary text |
| `ai_load_submission(p_incidentid)` | The submission as `case_matcher.submission_record()` gives it, with **detection ids as member keys** |
| `ai_load_case(p_caseid)` | The case dict `case_matcher` works with (entities, members, rejected pairs, counters) |
| `ai_save_case(p_caseid, p_case)` | Stores the case dict back (entities, which crop belongs to which, summary) |

Rules the worker can rely on:

* **One job at a time per worker id.** If a worker asks for a new job while it still has one open, the open one is treated as lost (crash + restart) and put back.
* **Jobs of the same case / incident never run at the same time**, even with several workers.
* A job is taken away from a worker only when it ran > 60 min **and** the worker sent no heartbeat for 2 min (or after 6 h). A long analysis on a live worker is left alone.
* **Re-running** an analysis updates the same rows (same file + type + track id), so suspect reviews and case links survive; rows a person already worked on are never deleted.
* Crop paths must be inside the incident's own `ai/` folder; anything else is dropped.
* The database has the last word on human decisions: an admin's **Yes** is never undone by the worker, a **No** pair is never linked again, and only an admin can set `confirmed`.

### The worker loop (sketch)

```python
import json, socket, tempfile, threading, time
from pathlib import Path

import case_matcher as cm                      # ai/
from upload_results import get_client, upload_results   # backend/

WORKER = socket.gethostname()
sb = get_client()                              # service key


def rpc(name, **params):
    return sb.rpc(name, params).execute().data


def heartbeat():
    while True:
        rpc("ai_worker_heartbeat", p_workerid=WORKER, p_gpu="RTX 3080", p_version="v1")
        time.sleep(30)


def analyse(job):
    inc = job["incidentid"]
    media = (sb.table("media").select("mediaid, storagepath")
             .eq("incidentid", inc).order("mediaid").execute().data)
    with tempfile.TemporaryDirectory() as tmp:
        files = []
        for m in media:                        # same order as the media ids below
            local = Path(tmp) / Path(m["storagepath"]).name
            local.write_bytes(sb.storage.from_("submissions").download(m["storagepath"]))
            files.append(local)
        result, json_path = run_pipeline(files)          # main.py's logic -> results.json
        uploaded = upload_results(result, json_path, inc, [m["mediaid"] for m in media], client=sb)
    p_result = json.loads(sb.storage.from_("submissions").download(uploaded))
    rpc("ai_save_analysis", p_incidentid=inc, p_result=p_result, p_summary=summary_of(p_result))


def case_job(job):
    case = rpc("ai_load_case", p_caseid=job["caseid"])
    if job["kind"] == "merge":
        sub = rpc("ai_load_submission", p_incidentid=job["incidentid"])
        try:
            cm.merge_submission(case, sub)
        except ValueError:                     # already merged (retry after a crash)
            return
    elif job["kind"] == "rematch":             # admin said "No": place it again
        ...                                    # see place_member() in tests/test_ai_pipeline_db.py
    for e in case["entities"]:                 # 'summary' = just this part
        cm._revote(e, case)
    case["summary"] = cm.summary_text(case)
    rpc("ai_save_case", p_caseid=job["caseid"], p_case=case)


threading.Thread(target=heartbeat, daemon=True).start()
while True:
    jobs = rpc("claim_next_job", p_workerid=WORKER)
    if not jobs:
        time.sleep(5)
        continue
    job = jobs[0]
    try:
        analyse(job) if job["kind"] == "analyse" else case_job(job)
        rpc("finish_job", p_jobid=job["jobid"])
    except Exception as e:                     # retried up to 3 times, then 'failed'
        rpc("finish_job", p_jobid=job["jobid"], p_error=f"{type(e).__name__}: {e}")
```

`tests/test_ai_pipeline_db.py` has a working version of the case part
(`run_case_jobs`, `place_member`) used by the tests.

### Job kinds

| Job | Queued by | Worker does |
|---|---|---|
| `analyse` | `submit_for_analysis` (citizen app, after the last file) | pipeline → `upload_results` → `ai_save_analysis`. If the submission is already in a case, `finish_job` queues a `merge` |
| `merge` | a submission joins a case (accept / add / create case) | `ai_load_case` + `ai_load_submission` → `merge_submission` → `ai_save_case` |
| `rematch` | admin answers **No** | place that one detection again (another entity or a new one) → `ai_save_case` |
| `summary` | admin answers **Yes**, a submission leaves the case | re-vote every entity + `summary_text` → `ai_save_case` |

---

## For the app

| Function | Who | Use |
|---|---|---|
| `submit_for_analysis(p_incidentid)` | the citizen who reported it, admins | after the **last** file is uploaded; returns the job id. `SupabaseService.submitForAnalysis` |
| `get_case_evidence(p_caseid)` | admins, investigators assigned to the case | the case screen's AI section: exactly the shape of `case_matcher.case_view()`; `member_key` = detection id. `SupabaseEvidenceSource.load` |
| `answer_entity_match(p_detectionid, p_yes)` | admins | "Is this Person 2?" Logged in the case history (`ai_match_confirmed` / `ai_match_rejected`). `SupabaseEvidenceSource.answer` |
| `ai_worker_status()` | admins | `{online, workers, queued, running, failed_24h}` for the Overview. `SupabaseService.getAiWorkerStatus` |
| `list_cases` | as before | now also returns `aisummary`, `aisummarystatus`, `aisummaryat` |

Pictures are bucket paths in `submissions`; `SupabaseEvidenceSource` downloads them
with the signed-in user's session, so the bucket's policies decide who sees them
(citizens never see `ai/`).

---

## Who can do what

| | admin | assigned investigator | citizen | worker (service key) |
|---|---|---|---|---|
| `aijob`, `aiworker`, `entitymatchrejection` | via `ai_worker_status()` / `answer_entity_match()` | – | – | read / write |
| `submit_for_analysis` | ✓ | – | own incident | – |
| worker functions | – | – | – | ✓ |
| `detection` (incl. new columns) | read | read (their cases) | – | write |
| `caseentity` | read | read (their cases) | – | write |
| `get_case_evidence` | ✓ | ✓ (their cases) | – | – |
| `answer_entity_match` | ✓ | – | – | – |
| AI columns (`detection`, `media.latitude/longitude`, `crimescene.aimerged`, `gpssource = 'file'`, `cases.aisummary*`) | read only | read only | – | write |

`appearance` / `colourhist` describe clothing and overall look (not faces), but
are treated like the crops: never shown to citizens.

---

## Tests

```
cd database
supabase start
supabase db reset
supabase test db                                  # pgTAP: supabase/tests/ai_pipeline.test.sql
cd ..
pip install "psycopg[binary]"
python tests/test_ai_pipeline_db.py               # end-to-end, runs the real case_matcher.py
```

`test_ai_pipeline_db.py` connects straight to the local database
(`postgresql://postgres:postgres@127.0.0.1:54322/postgres`, change with
`ARGUS_TEST_DB`) and switches roles per call, so RLS and grants decide every
result. Each test is rolled back. It covers the checklist in section 11 of the
plan, plus: `get_case_evidence` is compared field by field with
`case_matcher.case_view()` after merges, questions, Yes / No answers, removing,
moving and re-analysing submissions.

---

## Differences from SUPABASE_AI_PIPELINE.md, and why

| Plan | Built | Why |
|---|---|---|
| Worker inserts rows into `detection` / `vehicledetail` / ... | Worker calls `ai_save_analysis` / `ai_save_case` | A re-run must replace old rows "inside one transaction" (3.1); separate REST calls can't do that. The functions also check the data (right incident, crops in its own folder, human answers kept) |
| `suspect` row per person detection (3.4) | No `suspect` rows from the AI; person detections are `suspectstatus = 'possible'` | The POPIA design (migration `20261006090000`): a `suspect` row means an investigator **confirmed** the person. AI-made rows would break `review_possible_suspect` |
| `weapondetail.suspectid` = holder | new `weapondetail.heldbydetectionid` | Same reason: there is no suspect row to point at until an investigator confirms. `suspectid` stays for investigators |
| `detection.croppaths text[]` | `detection.crops jsonb` `[{path, type}]` | The case screen needs to know which picture is the face, the plate, ... |
| `colourhist real[]` | `colourhist vector(96)` | pgvector compares it directly (`<=>`), same as `appearance` |
| `unmerge` job | done by the database immediately, then a `summary` job re-votes | The pictures leave the case the moment the admin removes the submission, and there is no order problem between a queued merge and unmerge |
| Unique index on queued **and** processing jobs | queued only | Otherwise a change made while a merge is running (remove + re-add) could not queue the follow-up merge and would be lost |
| Re-queue after 60 min | after 60 min **without heartbeats** (or 6 h), or when the same worker asks again | Analysing 5 long videos can take more than an hour; it must not be handed to a second worker while the first is still working |
| — | `crimescene.aimerged` | Marks which submissions are already combined into their case, so `ai_load_case` / `merge_submission` know what is new |
| — | `cases.aisummary` protected like the other AI fields | Admins could otherwise overwrite the AI text by hand |
| `modelversion varchar(50)` | widened to 200 | `model_version` in results.json is longer than 50 characters |
| Merge every submission in the case | only `accepted` ones | Duplicates also sit in the case (`mark_duplicate`), but their footage is the same event: combining it would add every person twice |
| `list_suggested_matches` | keeps its minimum score | The app asks for 60 in the bulk "Suggested matches" list; the per-submission suggestions show everything the new rule lets through |

## Still to do

* ~~The worker itself~~ — done: `backend/worker.py` (see [`backend/README.md`](../backend/README.md#ai-worker-workerpy)); the sketch above shows the idea.
* ~~Citizen upload~~ — done: the upload page sends the incident and files to Supabase and calls `SupabaseService.submitForAnalysis(incidentId)` after the last file.
* **Overview tile** "AI worker online" — `getAiWorkerStatus()` is ready, no UI yet.
* **Claude-written case summary** (plan section 7) — optional; the worker's `summary_text` is used until then.
* `split_entity_member` / `merge_entities` (plan 4.5) — optional, later.
