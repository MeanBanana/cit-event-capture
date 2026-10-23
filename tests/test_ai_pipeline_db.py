"""
Database tests for the AI pipeline (the 20261012100000/100100/100200
migrations). These follow the checklist in the AI pipeline doc, and also run
the real ai/case_matcher.py against the database (load, merge, save) to make
sure get_case_evidence() returns exactly what case_view() would.

Talks straight to your local Supabase Postgres, so no API keys. Each test
runs in its own transaction that gets rolled back, so nothing sticks around.
Every call switches to the role the app or worker would really have
(authenticated + user id for people, service_role for the worker), which
means RLS and grants are what's actually being tested.

    cd database && supabase start && supabase db reset && cd ..
    pip install "psycopg[binary]" numpy opencv-python
    python tests/test_ai_pipeline_db.py                  # everything
    python tests/test_ai_pipeline_db.py merge question   # only tests with these in the name

Set ARGUS_TEST_DB if your database isn't on the default local URL.
"""

import json
import math
import os
import sys
import time
import traceback
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))
import case_matcher as cm  # noqa: E402

DB_URL = os.environ.get("ARGUS_TEST_DB", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")
RUN_TIME = datetime(2026, 10, 12, 10, 0, tzinfo=timezone.utc)
SANDTON = (-26.1076, 28.0567)            # 0.0030 deg of longitude here is about 300m


class Rollback(Exception):
    """Thrown at the end of every test so the transaction rolls back."""


class DbError(AssertionError):
    pass


# --- database session: one transaction per test, role switched per call

class Db:
    def __init__(self, conn):
        self.conn = conn
        self.cur = conn.cursor(row_factory=dict_row)

    def _become(self, who):
        self.cur.execute("RESET ROLE")
        if who == "postgres":
            return
        if who == "service":
            claims, role = {"role": "service_role"}, "service_role"
        elif who == "anon":
            claims, role = {"role": "anon"}, "anon"
        else:
            claims, role = {"sub": who["authid"], "role": "authenticated"}, "authenticated"
        self.cur.execute("SELECT set_config('request.jwt.claims', %s, true)", [json.dumps(claims)])
        self.cur.execute(f"SET LOCAL ROLE {role}")

    def rows(self, sql, params=None, who="postgres"):
        """Run SQL as `who` and get the rows back as dicts. Errors become DbError."""
        try:
            with self.conn.transaction():            # savepoint, so one failed query doesn't kill the test
                self._become(who)
                self.cur.execute(sql, params)
                result = self.cur.fetchall() if self.cur.description else []
                self.cur.execute("RESET ROLE")
                return result
        except psycopg.Error as e:
            raise DbError(f"{type(e).__name__}: {e.diag.message_primary or e}") from None

    def one(self, sql, params=None, who="postgres"):
        r = self.rows(sql, params, who)
        return r[0] if r else None

    def val(self, sql, params=None, who="postgres"):
        r = self.one(sql, params, who)
        return None if r is None else next(iter(r.values()))

    def rpc(self, fn, who="service", **params):
        """public.<fn>(name => value, ...), same as supabase.rpc()."""
        args = ", ".join(f"{k} => %({k})s" for k in params)
        values = {k: (Jsonb(v) if isinstance(v, dict) else v) for k, v in params.items()}
        return self.val(f"SELECT public.{fn}({args}) AS r", values, who)

    def fails(self, fn, *args, contains=None, **kwargs):
        try:
            fn(*args, **kwargs)
        except DbError as e:
            if contains and contains.lower() not in str(e).lower():
                raise AssertionError(f"failed, but with {e!s} (expected '{contains}')") from None
            return str(e)
        raise AssertionError("expected an error, but it worked")


@contextmanager
def session():
    with psycopg.connect(DB_URL, autocommit=False) as conn:
        db = Db(conn)
        try:
            with conn.transaction():
                yield db
                raise Rollback()
        except Rollback:
            pass


# --- test data

def make_user(db, role, **meta):
    authid = str(uuid.uuid4())
    name = f"t_{role[:3]}_{authid[:8]}"
    meta = {"username": name, "firstname": role.title(), "surname": "Tester", **meta}
    if role == "investigator":
        meta.setdefault("badgenumber", "B" + authid[:8])
        meta.setdefault("station", "Sandton SAPS")
    db.rows("INSERT INTO auth.users (id, email, raw_user_meta_data, raw_app_meta_data) "
            "VALUES (%s, %s, %s, %s)",
            [authid, f"{name}@example.com", json.dumps(meta), json.dumps({"role": role})])
    userid = db.val('SELECT userid FROM public."User" WHERE authid = %s', [authid])
    return {"authid": authid, "userid": userid, "role": role}


def report(db, citizen, files=2, lat=None, lon=None, location="Rivonia Rd, Sandton",
           when=RUN_TIME):
    """Citizen reports an incident and uploads `files` files, like the app."""
    inc = db.val("INSERT INTO public.crimescene (location, datetime, reportedby, latitude, longitude, gpssource) "
                 "VALUES (%s, %s, %s, %s, %s, %s) RETURNING incidentid",
                 [location, when, citizen["userid"], lat, lon,
                  "phone" if lat is not None else "typed"], who=citizen)
    media = [db.val("INSERT INTO public.media (incidentid, uploadedby, mediatype, storagepath) "
                    "VALUES (%s, %s, 'video', %s) RETURNING mediaid",
                    [inc, citizen["userid"], f"{inc}/media/clip{i + 1}.mp4"], who=citizen)
             for i in range(files)]
    return inc, media


def vec(base, cos, seed):
    """Unit vector with a cosine of exactly `cos` against `base`."""
    rng = np.random.default_rng(seed)
    noise = rng.normal(size=base.shape)
    noise -= noise @ base * base
    noise /= np.linalg.norm(noise)
    v = cos * base + math.sqrt(max(0.0, 1 - cos * cos)) * noise
    return [round(float(x), 6) for x in v]


def base_vector(dims, seed):
    v = np.random.default_rng(seed).normal(size=dims)
    return v / np.linalg.norm(v)


PERSON_A = (base_vector(512, 1), base_vector(96, 2))
PERSON_B = (base_vector(512, 3), base_vector(96, 4))


def look(person, cos, seed):
    """`person`'s fingerprint as if seen in another clip, with similarity `cos`."""
    return {"embedding": vec(person[0], cos, seed), "colour_hist": vec(person[1], cos, seed + 1),
            "views": 3}


def person(track, appearance, upper="black", lower="blue", face=True, seen=(1.0, 6.0)):
    return {"track_id": track, "detection_type": "person", "class_name": "person",
            "confidence": 0.91, "bounding_box": [10, 20, 110, 320],
            "frame_time_seconds": seen[0] + 1, "first_seen_seconds": seen[0],
            "last_seen_seconds": seen[1], "frames_seen": 40, "model_version": "test-model",
            "face_visible": face, "face_size_px": 64 if face else 0,
            "upper_clothing": upper, "upper_clothing_confidence": 0.9,
            "upper_clothing_top3": {upper: 0.9},
            "lower_clothing": lower, "lower_clothing_confidence": 0.8,
            "lower_clothing_top3": {lower: 0.8}, "clothing_views": 4,
            "appearance": appearance,
            "person_crop_path": f"person_{track}.png",
            "face_crop_path": f"face_{track}.png" if face else None,
            "extra_crop_paths": [f"person_{track}_b.png"]}


def vehicle(track, plate="ND 123-456", make="Toyota", colour="white", seen=(0.0, 8.0)):
    return {"track_id": track, "detection_type": "vehicle", "class_name": "car",
            "confidence": 0.88, "bounding_box": [200, 100, 600, 400],
            "frame_time_seconds": seen[0] + 2, "first_seen_seconds": seen[0],
            "last_seen_seconds": seen[1], "frames_seen": 80, "model_version": "test-model",
            "make": make, "make_confidence": 0.8, "make_views": 5,
            "colour": colour, "colour_confidence": 0.9,
            "plate": plate, "plate_confidence": 0.93 if plate else 0.0, "plate_reads": 6 if plate else 0,
            "appearance": None,
            "crop_path": f"vehicle_{track}.png",
            "plate_crop_path": f"plate_{track}.png" if plate else None}


def weapon(track, held_by, kind="long_gun", seen=(2.0, 5.0)):
    return {"track_id": track, "detection_type": "weapon", "class_name": kind,
            "weapon_confidence": 0.95, "weapon_top3": {kind: 0.95}, "confidence": 0.85,
            "bounding_box": [50, 60, 150, 90], "frame_time_seconds": seen[0],
            "first_seen_seconds": seen[0], "last_seen_seconds": seen[1], "frames_seen": 12,
            "held_by_person": held_by, "held_by_share": 1.0, "model_version": "weapons-trained",
            "crop_path": f"weapon_{track}.png"}


def results(inc, media, files, location=None, capture=RUN_TIME, run="20261012T100000"):
    """A results.json the way upload_results.py leaves it: crop paths point into
    the incident's ai/ folder in the bucket and every file has its mediaid."""
    out = []
    for i, (mediaid, dets) in enumerate(zip(media, files), start=1):
        folder = f"{inc}/ai/{run}/{i}_clip{i}"
        fixed = []
        for d in dets:
            d = json.loads(json.dumps(d))
            for k, v in list(d.items()):
                if k.endswith("_path") and v:
                    d[k] = f"{folder}/{v}"
                elif k == "extra_crop_paths":
                    d[k] = [f"{folder}/{p}" for p in v]
            fixed.append(d)
        out.append({"source_path": f"clip{i}.mp4", "source_type": "video", "mediaid": mediaid,
                    "capture_time": (capture + timedelta(minutes=i)).isoformat(),
                    "latitude": location[0] if location else None,
                    "longitude": location[1] if location else None,
                    "detections": fixed})
    return {"submission": inc, "processed_at": "2026-10-12T12:00:00", "model_version": "test-model",
            "file_count": len(out),
            "location": ({"latitude": location[0], "longitude": location[1], "source": "file"}
                         if location else None),
            "capture_time": capture.isoformat(), "files": out,
            "incidentid": inc, "storage_bucket": "submissions",
            "storage_folder": f"{inc}/ai/{run}"}


# --- a stand-in worker
#
# Does what the real worker does for case jobs, using the real case_matcher.
# We skip the download/pipeline/upload part and just hand it a results.json.

def worker_analyse(db, inc, result, worker="test-worker", summary="AI saw 1 person, 1 vehicle."):
    job = claim(db, worker)
    assert job and job["kind"] == "analyse" and job["incidentid"] == inc, job
    stats = db.rpc("ai_save_analysis", p_incidentid=inc, p_result=result, p_summary=summary)
    db.rpc("finish_job", p_jobid=job["jobid"])
    return stats


def claim(db, worker="test-worker"):
    return db.one("SELECT * FROM public.claim_next_job(%s)", [worker], who="service")


def save_case(db, case):
    return db.rpc("ai_save_case", p_caseid=case["case_id"], p_case=case)


def place_member(case, member):
    """Rematch: put one member in its best entity, or a new one."""
    person_entity_of = {m["key"]: e["entity_id"] for e in case["entities"]
                        if e["kind"] == "person" for m in e["members"]}
    found = cm._candidates(member, case["entities"], case, person_entity_of)
    if found:
        decision, score, reasons, target = found[0]
        cm._link(member, target, "auto" if decision == "auto" else "suggested", score, reasons)
    else:
        target = cm._new_entity(case, member)
        if member["kind"] == "weapon":
            target["held_by_entity"] = person_entity_of.get(member.get("held_by"))
        cm._link(member, target, "first")
    cm._revote(target, case)


def run_case_jobs(db, worker="test-worker"):
    """Run all queued merge/rematch/summary jobs. Returns the last case the
    worker saved so tests can compare it with get_case_evidence()."""
    case = None
    while True:
        job = claim(db, worker)
        if not job:
            return case
        assert job["kind"] in ("merge", "rematch", "summary"), job
        case = db.rpc("ai_load_case", p_caseid=job["caseid"])
        if job["kind"] == "merge":
            sub = db.rpc("ai_load_submission", p_incidentid=job["incidentid"])
            cm.merge_submission(case, sub)
        elif job["kind"] == "rematch":
            sub = db.rpc("ai_load_submission",
                         p_incidentid=db.val("SELECT m.incidentid FROM public.detection d JOIN public.media m "
                                             "USING (mediaid) WHERE d.detectionid = %s", [job["detectionid"]]))
            member = next(m for m in sub["members"] if m["key"] == str(job["detectionid"]))
            if not any(m["key"] == member["key"] for e in case["entities"] for m in e["members"]):
                place_member(case, member)
        for e in case["entities"]:
            cm._revote(e, case)
        case["summary"] = cm.summary_text(case)
        save_case(db, case)
        db.rpc("finish_job", p_jobid=job["jobid"])


def jobs(db, **where):
    cond = " AND ".join(f"{k} = %({k})s" for k in where) or "true"
    return db.rows(f"SELECT * FROM public.aijob WHERE {cond} ORDER BY jobid", where)


def evidence(db, case_id, who):
    return db.rpc("get_case_evidence", who=who, p_caseid=case_id)


def entity(view, label):
    for group in ("people", "vehicles", "weapons"):
        for e in view[group]:
            if e["label"] == label:
                return e
    raise AssertionError(f"{label} not in the case ({[e['label'] for g in ('people', 'vehicles', 'weapons') for e in view[g]]})")


class World:
    """The users most tests need, created inside the test's transaction."""

    def __init__(self, db):
        self.admin = make_user(db, "admin")
        self.citizen = make_user(db, "citizen")
        self.other_citizen = make_user(db, "citizen")
        self.investigator = make_user(db, "investigator")
        self.other_investigator = make_user(db, "investigator")


def analysed_case(db, w):
    """Submission 1 (person A with a long gun, white Toyota ND123456),
    analysed, accepted into a new case and merged by the worker."""
    inc, media = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    worker_analyse(db, inc, results(inc, media, [[person(1, look(PERSON_A, 0.97, 10)),
                                                  vehicle(2), weapon(1, held_by=1)]],
                                    location=SANDTON))
    case_id = db.rpc("create_case", who=w.admin, p_title="N1 Midrand CIT robbery",
                     p_incidentids=[inc])
    case = run_case_jobs(db)
    return inc, media, case_id, case


# --- 1. job queue

def test_submit_with_two_files_makes_one_job(db, w):
    inc, media = report(db, w.citizen, files=2)
    first = db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    again = db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    assert first == again, (first, again)
    assert len(jobs(db, incidentid=inc)) == 1
    assert db.val("SELECT aisummarystatus FROM public.crimescene WHERE incidentid = %s", [inc]) == "processing"
    assert {r["processingstatus"] for r in db.rows(
        "SELECT processingstatus FROM public.media WHERE incidentid = %s", [inc])} == {"pending"}
    # while it is being analysed, submitting again still adds nothing
    claim(db)
    assert db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc) == first
    assert len(jobs(db, incidentid=inc)) == 1


def test_submit_rules(db, w):
    inc, _ = report(db, w.citizen, files=1)
    db.fails(db.rpc, "submit_for_analysis", who=w.other_citizen, p_incidentid=inc,
             contains="Only the person who reported")
    db.fails(db.rpc, "submit_for_analysis", who=w.investigator, p_incidentid=inc,
             contains="Only the person who reported")
    db.fails(db.rpc, "submit_for_analysis", who="anon", p_incidentid=inc, contains="permission denied")
    empty, _ = report(db, w.citizen, files=0)
    db.fails(db.rpc, "submit_for_analysis", who=w.citizen, p_incidentid=empty, contains="at least one file")
    six, _ = report(db, w.citizen, files=6)
    db.fails(db.rpc, "submit_for_analysis", who=w.citizen, p_incidentid=six, contains="at most 5")
    assert db.rpc("submit_for_analysis", who=w.admin, p_incidentid=inc)       # admins may too


def test_second_worker_gets_nothing(db, w):
    inc, _ = report(db, w.citizen, files=2)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    a = claim(db, "worker-a")
    b = claim(db, "worker-b")
    assert a and a["workerid"] == "worker-a" and a["status"] == "processing" and a["attempts"] == 1
    assert b is None, b
    assert {r["processingstatus"] for r in db.rows(
        "SELECT processingstatus FROM public.media WHERE incidentid = %s", [inc])} == {"processing"}


def test_jobs_for_the_same_case_never_run_at_once(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    db.rpc("queue_ai_job", who="postgres", p_kind="summary", p_caseid=case_id)
    other, _ = report(db, w.citizen, files=1)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=other)
    first = claim(db, "worker-a")                     # the summary for the case
    assert first["kind"] == "summary"
    db.rpc("queue_ai_job", who="postgres", p_kind="rematch", p_caseid=case_id,
           p_detectionid=db.val("SELECT min(detectionid) FROM public.detection d JOIN public.media m "
                                "USING (mediaid) WHERE m.incidentid = %s", [inc]))
    second = claim(db, "worker-b")                    # skips the rematch (same case)
    assert second["kind"] == "analyse" and second["incidentid"] == other, second
    assert claim(db, "worker-c") is None
    db.rpc("finish_job", p_jobid=first["jobid"])
    assert claim(db, "worker-c")["kind"] == "rematch"


def test_dead_worker_job_requeued_then_failed(db, w):
    inc, _ = report(db, w.citizen, files=2)
    jobid = db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    for attempt in (1, 2, 3):
        worker = f"gpu-{attempt}"
        job = claim(db, worker)
        assert job and job["jobid"] == jobid and job["attempts"] == attempt, (attempt, job)
        # simulate the worker dying: no finish_job, no heartbeats, 61 minutes go by
        db.rows("UPDATE public.aijob SET startedat = now() - interval '61 minutes' WHERE jobid = %s", [jobid])
        db.rows("UPDATE public.aiworker SET lastseen = now() - interval '5 minutes' WHERE workerid = %s",
                [worker])
    assert claim(db, "gpu-4") is None                 # third time out -> failed, nothing left
    job = jobs(db, jobid=jobid)[0]
    assert job["status"] == "failed" and "timed out" in job["error"], job
    assert {r["processingstatus"] for r in db.rows(
        "SELECT processingstatus FROM public.media WHERE incidentid = %s", [inc])} == {"failed"}
    # the app shows "AI analysis failed"
    assert db.val("SELECT aisummarystatus FROM public.crimescene WHERE incidentid = %s", [inc]) == "failed"


def test_long_job_on_a_live_worker_is_left_alone(db, w):
    inc, _ = report(db, w.citizen, files=5)
    jobid = db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    claim(db, "gpu-a")
    db.rows("UPDATE public.aijob SET startedat = now() - interval '90 minutes' WHERE jobid = %s", [jobid])
    db.rpc("ai_worker_heartbeat", p_workerid="gpu-a")              # still alive
    assert claim(db, "gpu-b") is None
    assert jobs(db, jobid=jobid)[0]["status"] == "processing"
    db.rows("UPDATE public.aijob SET startedat = now() - interval '7 hours' WHERE jobid = %s", [jobid])
    assert claim(db, "gpu-b")["attempts"] == 2                     # hung for hours: taken over


def test_restarted_worker_gets_its_lost_job_back(db, w):
    inc, _ = report(db, w.citizen, files=1)
    jobid = db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    assert claim(db, "gpu-a")["attempts"] == 1
    again = claim(db, "gpu-a")                       # crashed and started again
    assert again["jobid"] == jobid and again["attempts"] == 2, again


def test_finish_with_error_retries_then_fails(db, w):
    inc, _ = report(db, w.citizen, files=1)
    jobid = db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    for attempt in (1, 2, 3):
        assert claim(db)["jobid"] == jobid
        db.rpc("finish_job", p_jobid=jobid, p_error=f"CUDA out of memory ({attempt})")
    job = jobs(db, jobid=jobid)[0]
    assert job["status"] == "failed" and job["attempts"] == 3 and "(3)" in job["error"], job
    db.fails(db.rpc, "finish_job", p_jobid=jobid, contains="not running")


def test_failed_job_with_newer_copy_queued_leaves_it_to_that_one(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    two, media2 = report(db, w.citizen, files=1)
    db.rpc("ai_save_analysis", p_incidentid=two, p_result=results(two, media2, [[person(1, None)]]))
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[two])
    job = claim(db)                                       # the merge of `two` is running ...
    assert job["kind"] == "merge"
    db.rpc("reopen_submission", who=w.admin, p_incidentid=two)          # ... admin removes it
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[two])  # and adds it back
    db.rpc("finish_job", p_jobid=job["jobid"], p_error="boom")
    done = jobs(db, jobid=job["jobid"])[0]
    assert done["status"] == "failed" and "newer queued job" in done["error"], done
    assert db.val("SELECT aisummarystatus FROM public.cases WHERE caseid = %s", [case_id]) != "failed"
    assert sorted(j["kind"] for j in jobs(db, caseid=case_id, status="queued")) == ["merge", "summary"]


def test_worker_status_for_admins(db, w):
    db.rpc("ai_worker_heartbeat", p_workerid="gpu-laptop", p_gpu="RTX 3080", p_version="v1")
    status = db.rpc("ai_worker_status", who=w.admin)
    assert status["online"] is True, status
    worker = status["workers"][0]
    assert worker["gpu"] == "RTX 3080" and worker["online"] and worker["seconds_ago"] <= 1, worker
    db.rows("UPDATE public.aiworker SET lastseen = now() - interval '5 minutes'")
    assert db.rpc("ai_worker_status", who=w.admin)["online"] is False
    db.fails(db.rpc, "ai_worker_status", who=w.investigator, contains="Only admins")


def test_worker_functions_are_service_key_only(db, w):
    for who in (w.citizen, w.admin, w.investigator, "anon"):
        for sql in ("SELECT * FROM public.claim_next_job('x')",
                    "SELECT public.finish_job(1)",
                    "SELECT public.ai_save_analysis(1, '{}'::jsonb)",
                    "SELECT public.ai_load_case(1)",
                    "SELECT public.ai_save_case(1, '{}'::jsonb)",
                    "SELECT public.ai_worker_heartbeat('x')",
                    "SELECT public.queue_ai_job('summary', NULL, 1)",
                    "SELECT * FROM public.aijob",
                    "SELECT * FROM public.aiworker",
                    "SELECT * FROM public.entitymatchrejection"):
            db.fails(db.rows, sql, who=who, contains="permission denied")


# --- 2. analysis results in the tables

def test_analysis_is_saved_in_the_tables(db, w):
    inc, media = report(db, w.citizen, files=2, lat=-26.0, lon=28.0)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    result = results(inc, media, [[person(1, look(PERSON_A, 0.97, 10)), vehicle(2), weapon(1, held_by=1)],
                                  [vehicle(1, plate=None)]], location=SANDTON)
    stats = worker_analyse(db, inc, result)
    assert stats == {"files": 2, "detections": 4, "people": 1, "vehicles": 2, "weapons": 1, "removed": 0}, stats

    p = db.one("SELECT d.* FROM public.detection d WHERE mediaid = %s AND detectiontype = 'person'", [media[0]])
    assert p["trackid"] == 1 and float(p["firstseen"]) == 1.0 and float(p["lastseen"]) == 6.0
    assert p["framesseen"] == 40 and p["modelversion"] == "test-model"
    assert p["suspectstatus"] == "possible"           # POPIA: a person, not yet a suspect
    assert p["attributes"]["upper_clothing"] == "black" and "appearance" not in p["attributes"]
    folder = f"{inc}/ai/20261012T100000/1_clip1"
    assert p["crops"] == [{"path": f"{folder}/person_1.png", "type": "person"},
                          {"path": f"{folder}/face_1.png", "type": "face"},
                          {"path": f"{folder}/person_1_b.png", "type": "person"}], p["crops"]
    assert db.val("SELECT extensions.vector_dims(appearance) FROM public.detection WHERE detectionid = %s",
                  [p["detectionid"]]) == 512
    assert db.val("SELECT count(*) FROM public.suspect WHERE incidentid = %s", [inc]) == 0

    v = db.one("SELECT v.* FROM public.vehicledetail v JOIN public.detection d USING (detectionid) "
               "WHERE d.mediaid = %s", [media[0]])
    assert v["licenceplatenumber"] == "ND123456" and v["platedetected"] and v["make"] == "Toyota", v
    assert float(v["plateconfidence"]) == 0.93
    v2 = db.one("SELECT v.* FROM public.vehicledetail v JOIN public.detection d USING (detectionid) "
                "WHERE d.mediaid = %s", [media[1]])
    assert v2["licenceplatenumber"] is None and not v2["platedetected"]

    wd = db.one("SELECT wd.* FROM public.weapondetail wd JOIN public.detection d USING (detectionid) "
                "WHERE d.mediaid = %s", [media[0]])
    assert wd["weapontype"] == "long_gun" and wd["heldbydetectionid"] == p["detectionid"], wd

    m = db.one("SELECT * FROM public.media WHERE mediaid = %s", [media[0]])
    assert m["processingstatus"] == "completed" and m["capturetimestamp"] == RUN_TIME + timedelta(minutes=1)
    assert float(m["latitude"]) == SANDTON[0]
    cs = db.one("SELECT * FROM public.crimescene WHERE incidentid = %s", [inc])
    assert cs["gpssource"] == "file" and float(cs["latitude"]) == SANDTON[0]     # file GPS beats the phone's
    assert cs["aisummarystatus"] == "ready" and cs["aisummary"].startswith("AI saw")
    assert jobs(db, incidentid=inc)[0]["status"] == "done"


def test_phone_gps_kept_when_files_have_none(db, w):
    inc, media = report(db, w.citizen, files=1, lat=-26.0, lon=28.0)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    worker_analyse(db, inc, results(inc, media, [[vehicle(1)]]), summary=None)
    cs = db.one("SELECT * FROM public.crimescene WHERE incidentid = %s", [inc])
    assert (float(cs["latitude"]), cs["gpssource"]) == (-26.0, "phone"), cs
    assert cs["aisummarystatus"] == "none"            # finished, but no summary text given


def test_rerun_replaces_instead_of_duplicating(db, w):
    inc, media = report(db, w.citizen, files=1)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    worker_analyse(db, inc, results(inc, media, [[person(1, None), person(2, None), vehicle(3)]]))
    ids = {r["trackid"]: r["detectionid"] for r in db.rows(
        "SELECT trackid, detectionid FROM public.detection WHERE mediaid = %s", [media[0]])}

    # an investigator already confirmed track 2 as a suspect, so a re-run mustn't touch it
    db.rows("UPDATE public.detection SET suspectstatus = 'confirmed', suspectreviewedat = now() "
            "WHERE detectionid = %s", [ids[2]])
    db.rows("INSERT INTO public.suspect (detectionid, incidentid) VALUES (%s, %s)", [ids[2], inc])

    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    stats = worker_analyse(db, inc, results(inc, media, [[person(1, None, upper="red"), vehicle(3, plate="CA 1")]],
                                            run="20261012T110000"))
    assert stats["removed"] == 0, stats              # track 2 was reviewed: kept
    rows = db.rows("SELECT trackid, detectionid, detectiontype, attributes FROM public.detection "
                   "WHERE mediaid = %s ORDER BY trackid", [media[0]])
    assert [(r["trackid"], r["detectionid"]) for r in rows] == [(1, ids[1]), (2, ids[2]), (3, ids[3])], rows
    assert rows[0]["attributes"]["upper_clothing"] == "red"          # updated in place
    assert db.val("SELECT licenceplatenumber FROM public.vehicledetail WHERE detectionid = %s", [ids[3]]) == "CA1"

    # third run without track 1: unreviewed rows like that get removed
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    stats = worker_analyse(db, inc, results(inc, media, [[vehicle(3)]], run="20261012T120000"))
    assert stats["removed"] == 1, stats
    assert db.val("SELECT count(*) FROM public.detection WHERE mediaid = %s", [media[0]]) == 2


def test_failed_file_and_bad_input(db, w):
    inc, media = report(db, w.citizen, files=2)
    other, other_media = report(db, w.other_citizen, files=1)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    job = claim(db)
    result = results(inc, media, [[person(1, None)], []])
    result["files"][1] = {"source_path": "clip2.mp4", "error": "cannot decode", "mediaid": media[1]}
    db.rpc("ai_save_analysis", p_incidentid=inc, p_result=result)
    db.rpc("finish_job", p_jobid=job["jobid"])
    assert [r["processingstatus"] for r in db.rows(
        "SELECT processingstatus FROM public.media WHERE incidentid = %s ORDER BY mediaid", [inc])] \
        == ["completed", "failed"]

    wrong = results(inc, other_media, [[person(1, None)]])          # someone else's file
    db.fails(db.rpc, "ai_save_analysis", p_incidentid=inc, p_result=wrong, contains="not a file of incident")
    db.fails(db.rpc, "ai_save_analysis", p_incidentid=inc, p_result={"nope": 1}, contains="files")
    bad = results(inc, media[:1], [[{"detection_type": "dragon", "track_id": 1}]])
    db.fails(db.rpc, "ai_save_analysis", p_incidentid=inc, p_result=bad, contains="detection_type")


def test_crop_paths_outside_the_incident_are_dropped(db, w):
    inc, media = report(db, w.citizen, files=1)
    other, _ = report(db, w.other_citizen, files=1)
    result = results(inc, media, [[person(1, None)]])
    det = result["files"][0]["detections"][0]
    det["person_crop_path"] = f"{other}/ai/x/person_1.png"          # someone else's folder
    det["face_crop_path"] = f"{inc}/ai/../../{other}/media/clip1.mp4"
    det["extra_crop_paths"] = ["crops\\submission 1\\1_clip\\person_1.png"]   # a local path
    db.rpc("ai_save_analysis", p_incidentid=inc, p_result=result)
    assert db.val("SELECT crops FROM public.detection WHERE mediaid = %s", [media[0]]) == []


def test_weapon_types_from_the_model_are_accepted(db, w):
    inc, media = report(db, w.citizen, files=1)
    dets = [person(1, None), weapon(1, 1, "long_gun"), weapon(2, 1, "machete"), weapon(3, None, "ray_gun")]
    db.rpc("ai_save_analysis", p_incidentid=inc, p_result=results(inc, media, [dets]))
    kinds = [r["weapontype"] for r in db.rows(
        "SELECT wd.weapontype FROM public.weapondetail wd JOIN public.detection d USING (detectionid) "
        "WHERE d.mediaid = %s ORDER BY d.trackid", [media[0]])]
    assert kinds == ["long_gun", "machete", "other"], kinds


# --- 3. case suggestions

def _suggest(db, w, inc):
    return db.rows("SELECT * FROM public.suggest_cases_for_incident(%s, 10)", [inc], who=w.admin)


def test_suggestion_rule(db, w):
    inc, media, case_id, _ = analysed_case(db, w)       # Sandton, RUN_TIME, plate ND123456
    near_lon = SANDTON[1] + 0.0030                       # ~300 m east

    close, _ = report(db, w.citizen, files=1, lat=SANDTON[0], lon=near_lon,
                      when=RUN_TIME + timedelta(minutes=20))
    s = _suggest(db, w, close)
    assert [r["caseid"] for r in s] == [case_id], s
    assert s[0]["score"] == 40 + 30, s                    # <= 300 m and <= 2 h
    assert any(r.endswith("m apart") for r in s[0]["reasons"]), s

    far, _ = report(db, w.citizen, files=1, lat=-25.75, lon=28.19, when=RUN_TIME)   # Pretoria, ~45 km
    assert _suggest(db, w, far) == []

    late, _ = report(db, w.citizen, files=1, lat=SANDTON[0], lon=near_lon,
                     when=RUN_TIME + timedelta(days=20))
    assert _suggest(db, w, late) == []                    # near, but more than 14 days apart

    week, _ = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1] + 0.008,   # ~800 m
                     when=RUN_TIME + timedelta(days=6))
    s = _suggest(db, w, week)
    assert s and s[0]["score"] == 30 + 10 and "6 days apart" in s[0]["reasons"], s

    plate, pmedia = report(db, w.citizen, files=1, lat=-25.75, lon=28.19)   # same plate, 45 km away
    db.rpc("ai_save_analysis", p_incidentid=plate,
           p_result=results(plate, pmedia, [[vehicle(1, plate="ND123456")]]))
    s = _suggest(db, w, plate)
    assert s and "Same plate ND123456" in s[0]["reasons"], s

    typo, tmedia = report(db, w.citizen, files=1, lat=-25.75, lon=28.19)    # 1 character off
    db.rpc("ai_save_analysis", p_incidentid=typo,
           p_result=results(typo, tmedia, [[vehicle(1, plate="ND123458")]]))
    assert any(r.startswith("Similar plate") for r in _suggest(db, w, typo)[0]["reasons"])


def test_typed_location_is_the_fallback_without_gps(db, w):
    a, _ = report(db, w.citizen, files=1, location="Rivonia Rd, Sandton")      # no GPS
    case_id = db.rpc("create_case", who=w.admin, p_title="Rivonia", p_incidentids=[a])
    b, _ = report(db, w.citizen, files=1, location="rivonia rd sandton", when=RUN_TIME + timedelta(hours=3))
    s = _suggest(db, w, b)
    assert [r["caseid"] for r in s] == [case_id] and s[0]["score"] == 20 + 20, s
    assert "Same location" in s[0]["reasons"]


def test_suggestion_mentions_a_look_alike_person(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    new, nmedia = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("ai_save_analysis", p_incidentid=new,
           p_result=results(new, nmedia, [[person(1, look(PERSON_A, 0.85, 20))]]))
    reasons = _suggest(db, w, new)[0]["reasons"]
    hit = [r for r in reasons if r.startswith("may show Person 1")]
    assert hit and "alike" in hit[0], reasons


# --- 4. cases: merge, questions, remove

def _normalise(view):
    """case_view()/get_case_evidence() with lists sorted so they compare."""
    view = json.loads(json.dumps(view))
    view["submissions"].sort(key=lambda s: s["submission"])
    for group in ("people", "vehicles", "weapons"):
        for e in view[group]:
            e["crops"].sort(key=lambda c: (c["submission"], c["path"]))
            e["questions"].sort(key=lambda q: q["member_key"])
            for q in e["questions"]:
                q["crops"].sort(key=lambda c: c["path"])
    return view


def assert_same_as_case_matcher(db, w, case_id, case):
    got = _normalise(evidence(db, case_id, w.admin))
    want = _normalise(cm.case_view(case))
    if got != want:
        for key in want:
            if got.get(key) != want[key]:
                raise AssertionError(f"get_case_evidence differs from case_view() in '{key}':\n"
                                     f"  database:     {json.dumps(got.get(key))[:600]}\n"
                                     f"  case_matcher: {json.dumps(want[key])[:600]}")
        raise AssertionError(f"extra keys: {set(got) - set(want)}")


def test_accept_merges_into_case_like_case_matcher(db, w):
    inc, media, case_id, case = analysed_case(db, w)
    assert [j["kind"] for j in jobs(db, caseid=case_id)] == ["merge"]
    view = evidence(db, case_id, w.admin)
    assert view["counts"] == {"people": 1, "vehicles": 1, "weapons": 1}, view["counts"]
    p1 = entity(view, "Person 1")
    assert p1["description"] == "top black, bottom blue · face seen", p1["description"]
    assert len(p1["crops"]) == 3 and p1["submission_count"] == 1
    assert entity(view, "Vehicle 1")["description"] == "white Toyota car · plate ND123456"
    assert entity(view, "Weapon 1")["description"] == "long gun · held by Person 1"
    assert view["ai_summary"].startswith("1 submission"), view["ai_summary"]
    assert_same_as_case_matcher(db, w, case_id, case)
    assert db.val("SELECT aisummarystatus FROM public.cases WHERE caseid = %s", [case_id]) == "ready"


def test_second_submission_joins_the_same_people_and_vehicles(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    two, media2 = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=two)
    # same person (very alike, same clothes), same car with a plate, plus someone new
    worker_analyse(db, two, results(two, media2, [[person(1, look(PERSON_A, 0.95, 30)),
                                                   person(2, look(PERSON_B, 0.99, 31), upper="red"),
                                                   vehicle(3, plate="ND123456")]],
                                    location=SANDTON, capture=RUN_TIME + timedelta(minutes=30)))
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[two])
    case = run_case_jobs(db)
    view = evidence(db, case_id, w.admin)
    assert view["counts"] == {"people": 2, "vehicles": 1, "weapons": 1}, view["counts"]
    assert entity(view, "Person 1")["submission_count"] == 2
    v1 = entity(view, "Vehicle 1")
    assert v1["submission_count"] == 2 and "read in 2 submissions" in v1["description"], v1["description"]
    assert view["open_questions"] == 0
    assert_same_as_case_matcher(db, w, case_id, case)


def _case_with_question(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    two, media2 = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=two)
    worker_analyse(db, two, results(two, media2, [[person(1, look(PERSON_A, 0.82, 40))]],
                                    location=SANDTON, capture=RUN_TIME + timedelta(hours=1)))
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[two])
    case = run_case_jobs(db)
    view = evidence(db, case_id, w.admin)
    assert view["open_questions"] == 1, view
    question = entity(view, "Person 1")["questions"][0]
    assert question["submission"] == two and any("alike" in r for r in question["reasons"]), question
    assert len(question["crops"]) == 3
    return case_id, two, case, question


def test_question_is_asked_like_case_matcher(db, w):
    case_id, _, case, _ = _case_with_question(db, w)
    assert_same_as_case_matcher(db, w, case_id, case)


def test_answer_yes_moves_pictures_under_the_person(db, w):
    case_id, two, _, question = _case_with_question(db, w)
    before = len(entity(evidence(db, case_id, w.admin), "Person 1")["crops"])
    db.rpc("answer_entity_match", who=w.admin, p_detectionid=int(question["member_key"]), p_yes=True)
    view = evidence(db, case_id, w.admin)
    p1 = entity(view, "Person 1")
    assert view["open_questions"] == 0 and len(p1["crops"]) == before + 3, p1
    assert p1["submission_count"] == 2
    assert [j["kind"] for j in jobs(db, caseid=case_id, status="queued")] == ["summary"]
    event = db.one("SELECT * FROM public.caseevent WHERE caseid = %s ORDER BY eventid DESC LIMIT 1", [case_id])
    assert (event["eventtype"], event["incidentid"], event["detail"]) == ("ai_match_confirmed", two, "is Person 1")
    assert event["actor"] == w.admin["userid"]
    case = run_case_jobs(db)                          # worker re-votes; confirmed stays confirmed
    assert db.val("SELECT matchstatus FROM public.detection WHERE detectionid = %s",
                  [int(question["member_key"])]) == "confirmed"
    assert_same_as_case_matcher(db, w, case_id, case)


def test_answer_no_is_never_asked_again(db, w):
    case_id, two, _, question = _case_with_question(db, w)
    det = int(question["member_key"])
    db.rpc("answer_entity_match", who=w.admin, p_detectionid=det, p_yes=False)
    assert evidence(db, case_id, w.admin)["open_questions"] == 0
    assert [j["kind"] for j in jobs(db, caseid=case_id, status="queued")] == ["rematch"]
    case = run_case_jobs(db)                          # worker places it again
    view = evidence(db, case_id, w.admin)
    assert view["counts"]["people"] == 2 and view["open_questions"] == 0, view
    assert entity(view, "Person 2")["crops"][0]["submission"] == two
    assert_same_as_case_matcher(db, w, case_id, case)
    # neither a summary re-run nor a later merge should ever link that pair again
    db.rpc("queue_ai_job", who="postgres", p_kind="summary", p_caseid=case_id)
    stale = db.rpc("ai_load_case", p_caseid=case_id)
    p1 = next(e for e in stale["entities"] if e["entity_id"] == "p1")
    moved = next(m for e in stale["entities"] for m in e["members"] if m["key"] == str(det))
    p1["members"].append(dict(moved, status="suggested"))
    save_case(db, stale)
    assert db.val("SELECT e.number FROM public.detection d JOIN public.caseentity e ON e.entityid = d.caseentityid "
                  "WHERE d.detectionid = %s", [det]) == 2


def test_answer_rules(db, w):
    case_id, _, _, question = _case_with_question(db, w)
    det = int(question["member_key"])
    db.fails(db.rpc, "answer_entity_match", who=w.investigator, p_detectionid=det, p_yes=True,
             contains="Only admins")
    db.fails(db.rpc, "answer_entity_match", who=w.citizen, p_detectionid=det, p_yes=True,
             contains="Only admins")
    settled = db.val("SELECT min(detectionid) FROM public.detection WHERE matchstatus = 'first'")
    db.fails(db.rpc, "answer_entity_match", who=w.admin, p_detectionid=settled, p_yes=True,
             contains="no open question")
    db.rpc("set_case_status", who=w.admin, p_caseid=case_id, p_status="closed")
    db.fails(db.rpc, "answer_entity_match", who=w.admin, p_detectionid=det, p_yes=True, contains="closed")


def test_human_answers_win_over_a_stale_worker(db, w):
    case_id, _, _, question = _case_with_question(db, w)
    det = int(question["member_key"])
    stale = db.rpc("ai_load_case", p_caseid=case_id)          # worker loaded before the answer ...
    db.rpc("answer_entity_match", who=w.admin, p_detectionid=det, p_yes=True)
    save_case(db, stale)                                       # ... and saves after it
    assert db.val("SELECT matchstatus FROM public.detection WHERE detectionid = %s", [det]) == "confirmed"
    # the worker can't confirm anything itself
    case = db.rpc("ai_load_case", p_caseid=case_id)
    for e in case["entities"]:
        for m in e["members"]:
            if m["status"] == "first":
                m["status"] = "confirmed"
    save_case(db, case)
    assert db.val("SELECT count(*) FROM public.detection WHERE matchstatus = 'confirmed'") == 1


def test_removing_a_submission_removes_its_pictures(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    two, media2 = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("ai_save_analysis", p_incidentid=two,
           p_result=results(two, media2, [[person(1, look(PERSON_A, 0.95, 50)), person(2, look(PERSON_B, 0.99, 51))]],
                            location=SANDTON, capture=RUN_TIME + timedelta(minutes=10)))
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[two])
    run_case_jobs(db)
    assert evidence(db, case_id, w.admin)["counts"]["people"] == 2

    db.rpc("reopen_submission", who=w.admin, p_incidentid=two)      # back to pending = out of the case
    view = evidence(db, case_id, w.admin)                             # straight away, before any job runs
    assert view["counts"]["people"] == 1, view["counts"]              # Person 2 only came from it
    assert all(c["submission"] == inc for c in entity(view, "Person 1")["crops"])
    assert [s["submission"] for s in view["submissions"]] == [inc]
    assert [j["kind"] for j in jobs(db, caseid=case_id, status="queued")] == ["summary"]
    assert db.val("SELECT aisummarystatus FROM public.cases WHERE caseid = %s", [case_id]) == "outdated"
    case = run_case_jobs(db)
    assert_same_as_case_matcher(db, w, case_id, case)


def test_rejecting_an_accepted_submission_removes_its_pictures(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    db.rpc("reject_submission", who=w.admin, p_incidentid=inc, p_note="Not related")
    view = evidence(db, case_id, w.admin)
    assert view["counts"] == {"people": 0, "vehicles": 0, "weapons": 0} and view["submissions"] == [], view
    assert db.val("SELECT count(*) FROM public.detection WHERE caseentityid IS NOT NULL") == 0


def test_moving_a_submission_to_another_case(db, w):
    inc, media, case_a, _ = analysed_case(db, w)
    case_b = db.rpc("create_case", who=w.admin, p_title="Other case")
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_b, p_incidentids=[inc])
    assert evidence(db, case_a, w.admin)["counts"] == {"people": 0, "vehicles": 0, "weapons": 0}
    run_case_jobs(db)
    assert evidence(db, case_b, w.admin)["counts"] == {"people": 1, "vehicles": 1, "weapons": 1}
    assert evidence(db, case_a, w.admin)["ai_summary"].startswith("0 submissions")


def test_merge_waits_for_the_analysis(db, w):
    inc, media = report(db, w.citizen, files=1)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    case_id = db.rpc("create_case", who=w.admin, p_title="Early accept", p_incidentids=[inc])
    assert jobs(db, caseid=case_id) == []                       # nothing to merge yet
    worker_analyse(db, inc, results(inc, media, [[person(1, look(PERSON_A, 0.9, 60))]]))
    assert [j["kind"] for j in jobs(db, caseid=case_id)] == ["merge"]
    run_case_jobs(db)
    assert evidence(db, case_id, w.admin)["counts"]["people"] == 1


def test_reanalysing_a_merged_submission_merges_it_again(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    worker_analyse(db, inc, results(inc, media, [[person(1, look(PERSON_A, 0.97, 10)),
                                                  person(5, look(PERSON_B, 0.97, 11), upper="green")]],
                                    location=SANDTON, run="20261012T130000"))
    assert [j["kind"] for j in jobs(db, caseid=case_id, status="queued")] == ["summary", "merge"]
    case = run_case_jobs(db)
    view = evidence(db, case_id, w.admin)
    assert view["counts"] == {"people": 2, "vehicles": 0, "weapons": 0}, view["counts"]
    assert_same_as_case_matcher(db, w, case_id, case)


def test_deleting_a_case_with_people_works(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    db.rows("DELETE FROM public.cases WHERE caseid = %s", [case_id], who=w.admin)
    assert db.val("SELECT count(*) FROM public.caseentity") == 0
    cs = db.one("SELECT * FROM public.crimescene WHERE incidentid = %s", [inc])
    assert cs["caseid"] is None and cs["reviewstatus"] == "pending" and not cs["aimerged"]
    assert db.val("SELECT count(*) FROM public.detection WHERE caseentityid IS NOT NULL "
                  "OR matchstatus IS NOT NULL") == 0


def test_duplicates_are_not_combined_twice(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    dup, dmedia = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("ai_save_analysis", p_incidentid=dup,
           p_result=results(dup, dmedia, [[person(1, look(PERSON_A, 0.97, 10))]], location=SANDTON))
    db.rpc("mark_duplicate", who=w.admin, p_incidentid=dup, p_originalid=inc)
    assert db.val("SELECT caseid FROM public.crimescene WHERE incidentid = %s", [dup]) == case_id
    assert jobs(db, incidentid=dup) == []


# ---------------------------------------------------------------------------
# 5. Who can see what
# ---------------------------------------------------------------------------

def test_only_admins_and_assigned_investigators_see_case_evidence(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    db.rpc("assign_investigator", who=w.admin, p_caseid=case_id, p_userid=w.investigator["userid"])
    assert evidence(db, case_id, w.investigator)["counts"]["people"] == 1
    assert db.val("SELECT count(*) FROM public.caseentity", who=w.investigator) == 3
    for who in (w.citizen, w.other_investigator):
        db.fails(evidence, db, case_id, who, contains="Only admins and investigators assigned")
        assert db.val("SELECT count(*) FROM public.caseentity", who=who) == 0
        assert db.val("SELECT count(*) FROM public.detection", who=who) == 0
    db.fails(evidence, db, case_id, "anon", contains="permission denied")
    assert evidence(db, 999999, w.admin) is None


def test_citizen_cannot_read_ai_pictures(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    db.rows("INSERT INTO storage.objects (bucket_id, name) VALUES ('submissions', %s), ('submissions', %s)",
            [f"{inc}/media/clip1.mp4", f"{inc}/ai/20261012T100000/1_clip1/person_1.png"])
    names = [r["name"] for r in db.rows("SELECT name FROM storage.objects", who=w.citizen)]
    assert names == [f"{inc}/media/clip1.mp4"], names
    assert len(db.rows("SELECT name FROM storage.objects", who=w.admin)) == 2


def test_app_users_cannot_write_ai_output(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    db.fails(db.rows, "UPDATE public.cases SET aisummary = 'fake' WHERE caseid = %s", [case_id],
             who=w.admin, contains="analysis pipeline only")
    db.fails(db.rows, "UPDATE public.media SET latitude = 1, longitude = 1 WHERE mediaid = %s", [media[0]],
             who=w.admin, contains="analysis pipeline only")
    db.fails(db.rows, "UPDATE public.crimescene SET aimerged = false WHERE incidentid = %s", [inc],
             who=w.admin, contains="analysis pipeline only")
    # the file's own GPS can't be relabelled (or faked) from the app
    db.fails(db.rows, "UPDATE public.crimescene SET gpssource = 'phone' WHERE incidentid = %s", [inc],
             who=w.admin, contains="analysis pipeline only")
    db.fails(db.rows, "INSERT INTO public.crimescene (location, datetime, reportedby, gpssource) "
                      "VALUES ('x', now(), %s, 'file')", [w.citizen["userid"]],
             who=w.citizen, contains="analysis pipeline only")
    db.fails(db.rows, "INSERT INTO public.caseentity (caseid, kind, number) VALUES (%s, 'person', 9)",
             [case_id], who=w.admin, contains="permission denied")
    # direct table writes to detection: no policy -> nothing changes
    db.rows("UPDATE public.detection SET matchstatus = 'confirmed'", who=w.admin)
    assert db.val("SELECT count(*) FROM public.detection WHERE matchstatus = 'confirmed'") == 0


def test_list_cases_returns_the_ai_summary(db, w):
    inc, media, case_id, _ = analysed_case(db, w)
    row = db.one("SELECT * FROM public.list_cases(p_caseid => %s)", [case_id], who=w.admin)
    assert row["aisummarystatus"] == "ready" and row["aisummary"].startswith("1 submission"), row
    assert row["incidentcount"] == 1 and row["plates"] == ["ND123456"]


# ---------------------------------------------------------------------------

def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    only = sys.argv[1:]
    if only:
        tests = [(n, f) for n, f in tests if any(o in n for o in only)]
    try:
        psycopg.connect(DB_URL, connect_timeout=5).close()
    except psycopg.Error as e:
        sys.exit(f"Can't reach the database at {DB_URL} ({e}).\n"
                 "Run `supabase start` in the database folder first, or set ARGUS_TEST_DB.")

    started = time.time()
    passed = failed = 0
    for name, fn in tests:
        label = name[len("test_"):].replace("_", " ")
        try:
            with session() as db:
                fn(db, World(db))
            passed += 1
            print(f"  PASS  {label}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  FAIL  {label}\n        {type(e).__name__}: {e}")
            if os.environ.get("ARGUS_TEST_TRACE"):
                traceback.print_exc()
    print(f"\n{passed} passed, {failed} failed in {time.time() - started:.1f}s")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
