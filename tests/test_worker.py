"""
End-to-end test for backend/worker.py. Uses the real worker, the real AI
pipeline and the real case matcher against your local Supabase database.

Roughly what happens:
  1. a citizen reports incident A (2 files) and submits it
  2. the worker analyses it and saves the detections
  3. same again for incident B, "filmed" 200m away 20 minutes later
  4. an admin makes a case from A and adds B, and the worker merges them
  5. we check get_case_evidence() and that every crop is in the bucket
  6. if there's an "Is this ...?" question we answer No and make sure it
     never comes back

We don't go through the Supabase API. PgClient below fakes the bits of
supabase-py the worker uses and talks to Postgres directly as service_role,
with "bucket" files in a temp folder. So you only need the database:

    cd database && supabase start && supabase db reset && cd ..
    pip install "psycopg[binary]"
    python tests/test_worker.py                       # uses the clips in ai/ if they're there
    python tests/test_worker.py clip1.mp4 photo.jpg   # or your own: first half is A, second half B

Cleans up after itself. Point ARGUS_TEST_DB elsewhere if your database isn't
on the default `supabase start` URL.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))
sys.path.insert(0, str(ROOT / "backend"))

DB_URL = os.environ.get("ARGUS_TEST_DB", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")
SANDTON = (-26.1076, 28.0567)


# --- fake supabase-py client (just the parts the worker touches)

class _Result:
    def __init__(self, data):
        self.data = data


class _Rpc:
    def __init__(self, client, name, params):
        self.client, self.name, self.params = client, name, params

    def execute(self):
        return _Result(self.client.call(self.name, self.params))


class _Query:
    def __init__(self, client, table):
        self.client, self.table = client, table
        self.columns, self.where, self.order_by, self.values = "*", [], None, None

    def select(self, columns="*"):
        self.columns = columns
        return self

    def update(self, values):
        self.values = values
        return self

    def eq(self, column, value):
        self.where.append((column, "=", value))
        return self

    def in_(self, column, values):
        self.where.append((column, "= ANY", list(values)))
        return self

    def order(self, column):
        self.order_by = column
        return self

    def execute(self):
        cond = " AND ".join(f"{c} {op}(%s)" if op == "= ANY" else f"{c} = %s"
                            for c, op, _ in self.where) or "true"
        params = [v for _, _, v in self.where]
        if self.values is not None:
            sets = ", ".join(f"{k} = %s" for k in self.values)
            sql = f"UPDATE public.{self.table} SET {sets} WHERE {cond} RETURNING *"
            params = list(self.values.values()) + params
        else:
            sql = f"SELECT {self.columns} FROM public.{self.table} WHERE {cond}"
            if self.order_by:
                sql += f" ORDER BY {self.order_by}"
        return _Result(self.client.sql(sql, params))


class _Bucket:
    def __init__(self, folder):
        self.folder = Path(folder)

    def download(self, path):
        return (self.folder / path).read_bytes()

    def upload(self, path, data, options=None):
        target = self.folder / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


class _Storage:
    def __init__(self, folder):
        self.folder = Path(folder)

    def from_(self, bucket):
        return _Bucket(self.folder / bucket)


class PgClient:
    """Mimics supabase-py's rpc/table/storage with the service key, but goes
    straight to Postgres. One transaction per call, same as PostgREST."""

    def __init__(self, db_url, storage_folder):
        self.db_url = db_url
        self.storage = _Storage(storage_folder)

    def rpc(self, name, params):
        return _Rpc(self, name, params)

    def table(self, name):
        return _Query(self, name)

    def _run(self, sql, params):
        with psycopg.connect(self.db_url, autocommit=False) as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                            [json.dumps({"role": "service_role"})])
                cur.execute("SET LOCAL ROLE service_role")
                cur.execute(sql, params)
                rows = cur.fetchall() if cur.description else []
            conn.commit()
        return rows

    def sql(self, sql, params):
        return self._run(sql, params)

    def call(self, name, params):
        args = ", ".join(f"{k} => %({k})s" for k in params)
        values = {k: (Jsonb(v) if isinstance(v, (dict, list)) else v) for k, v in params.items()}
        with psycopg.connect(self.db_url) as conn:
            setof = conn.execute("SELECT bool_or(proretset) FROM pg_proc p "
                                 "JOIN pg_namespace n ON n.oid = p.pronamespace "
                                 "WHERE n.nspname = 'public' AND p.proname = %s", [name]).fetchone()[0]
        if setof:
            return self._run(f"SELECT * FROM public.{name}({args})", values)
        rows = self._run(f"SELECT public.{name}({args}) AS r", values)
        return rows[0]["r"] if rows else None


# --- the app's side of things

def sql(query, params=None, who=None):
    with psycopg.connect(DB_URL, autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            if who:
                cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                            [json.dumps({"sub": who["authid"], "role": "authenticated"})])
                cur.execute("SET LOCAL ROLE authenticated")
            cur.execute(query, params)
            rows = cur.fetchall() if cur.description else []
        conn.commit()
    return rows


def make_user(role, tag):
    authid = str(uuid.uuid4())
    name = f"worker_test_{role[:3]}_{authid[:8]}"
    meta = {"username": name, "firstname": role.title(), "surname": "Tester"}
    sql("INSERT INTO auth.users (id, email, raw_user_meta_data, raw_app_meta_data) VALUES (%s, %s, %s, %s)",
        [authid, f"{name}@example.com", json.dumps(meta), json.dumps({"role": role})])
    userid = sql('SELECT userid FROM public."User" WHERE authid = %s', [authid])[0]["userid"]
    tag.append(authid)
    return {"authid": authid, "userid": userid}


def report(citizen, files, bucket, lat, lon):
    """Report an incident and upload files the way the citizen app does."""
    inc = sql("INSERT INTO public.crimescene (location, datetime, reportedby, latitude, longitude, gpssource) "
              "VALUES ('Rivonia Rd, Sandton', now(), %s, %s, %s, 'phone') RETURNING incidentid",
              [citizen["userid"], lat, lon], who=citizen)[0]["incidentid"]
    for i, f in enumerate(files, start=1):
        path = f"{inc}/media/{uuid.uuid4().hex[:8]}{Path(f).suffix.lower()}"
        target = bucket / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(f, target)
        kind = "image" if Path(f).suffix.lower() in (".jpg", ".jpeg", ".png", ".webp", ".heic") else "video"
        sql("INSERT INTO public.media (incidentid, uploadedby, mediatype, storagepath) VALUES (%s, %s, %s, %s)",
            [inc, citizen["userid"], kind, path], who=citizen)
    return inc


def with_gps(src, dst, lat, lon, when):
    """Copy a video and stamp GPS + recording time into it, like a phone would."""
    import imageio_ffmpeg
    loc = f"{lat:+08.4f}{lon:+09.4f}/"
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-y", "-i", str(src), "-t", "6",
                    "-c", "copy", "-metadata", f"location={loc}",
                    "-metadata", f"creation_time={when.strftime('%Y-%m-%dT%H:%M:%S.000000Z')}",
                    str(dst)], check=True)
    return dst


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print(f"  OK  {message}")


# --- the test itself

def main():
    try:
        psycopg.connect(DB_URL, connect_timeout=5).close()
    except psycopg.Error as e:
        sys.exit(f"Can't reach the database at {DB_URL} ({e}).\n"
                 "Run `supabase start` in the database folder first, or set ARGUS_TEST_DB.")

    given = [Path(a) for a in sys.argv[1:]]
    if not given:
        given = [p for p in (ROOT / "ai" / "gunVid.mp4", ROOT / "ai" / "womanGun.jpg") if p.exists()]
    if not given:
        sys.exit("Give one or more test files: python tests/test_worker.py clip.mp4 photo.jpg")

    os.environ.setdefault("OPENCV_LOG_LEVEL", "ERROR")
    tmp = Path(tempfile.mkdtemp(prefix="argus_worker_test_"))
    bucket = tmp / "storage" / "submissions"
    users, incidents, case_id = [], [], None
    started = time.time()
    try:
        # A and B use the same footage, B is just "filmed" 200m away 20 min later
        t0 = datetime(2026, 10, 12, 8, 0, tzinfo=timezone.utc)
        def files_for(tag, lat, lon, when):
            out = []
            for i, f in enumerate(given):
                if f.suffix.lower() in (".mp4", ".mov", ".m4v"):
                    out.append(with_gps(f, tmp / f"{tag}{i}{f.suffix}", lat, lon, when))
                else:
                    out.append(f)
            return out
        files_a = files_for("a", *SANDTON, t0)
        files_b = files_for("b", SANDTON[0] - 0.0018, SANDTON[1], t0 + timedelta(minutes=20))

        citizen, admin = make_user("citizen", users), make_user("admin", users)
        inc_a = report(citizen, files_a, bucket, *SANDTON)
        inc_b = report(citizen, files_b, bucket, *SANDTON)
        incidents += [inc_a, inc_b]
        for inc in (inc_a, inc_b):
            sql("SELECT public.submit_for_analysis(%s)", [inc], who=citizen)
        check(len(sql("SELECT * FROM public.aijob WHERE incidentid = ANY(%s) AND kind = 'analyse' "
                      "AND status = 'queued'", [[inc_a, inc_b]])) == 2, "submit queued 2 analyse jobs")

        # --- worker
        import logging
        from worker import Worker, log
        log.setLevel(logging.INFO)
        log.addHandler(logging.StreamHandler(sys.stdout))
        client = PgClient(DB_URL, tmp / "storage")
        os.chdir(ROOT / "ai")                       # model files live here
        worker = Worker(client, "test-worker", work_dir=tmp / "work")
        done = worker.run(once=True)
        check(done == 2, "worker did both analyse jobs")
        check(not sql("SELECT 1 FROM public.aijob WHERE incidentid = ANY(%s) AND status <> 'done'",
                      [[inc_a, inc_b]]), "both jobs are 'done'")

        for inc in (inc_a, inc_b):
            media = sql("SELECT processingstatus, airesultpath, capturetimestamp FROM public.media "
                        "WHERE incidentid = %s", [inc])
            check(all(m["processingstatus"] == "completed" for m in media),
                  f"incident {inc}: every file 'completed'")
            check(all(m["airesultpath"] and (bucket / m["airesultpath"]).exists() for m in media),
                  f"incident {inc}: results.json is in the bucket")
            cs = sql("SELECT aisummary, aisummarystatus, gpssource, latitude FROM public.crimescene "
                     "WHERE incidentid = %s", [inc])[0]
            check(cs["aisummarystatus"] == "ready" and cs["aisummary"],
                  f"incident {inc}: AI summary ready: {cs['aisummary']!r}")
            dets = sql("SELECT d.detectiontype, d.crops FROM public.detection d "
                       "JOIN public.media m USING (mediaid) WHERE m.incidentid = %s", [inc])
            missing = [c["path"] for d in dets for c in d["crops"] if not (bucket / c["path"]).exists()]
            check(not missing, f"incident {inc}: {len(dets)} detection(s), all their crops are in the bucket")
            if any(f.suffix.lower() in (".mp4", ".mov", ".m4v") for f in given):
                check(cs["gpssource"] == "file", f"incident {inc}: GPS taken from the video file")

        # --- admin builds the case
        case_id = sql("SELECT public.create_case(%s, NULL, %s) AS id",
                      ["Worker test case", [inc_a]], who=admin)[0]["id"]
        sug = sql("SELECT * FROM public.suggest_cases_for_incident(%s)", [inc_b], who=admin)
        check(any(s["caseid"] == case_id for s in sug),
              f"B is suggested for the case: {[s['reasons'] for s in sug if s['caseid'] == case_id]}")
        sql("SELECT public.add_incidents_to_case(%s, %s)", [case_id, [inc_b]], who=admin)
        done = worker.run(once=True)
        check(done >= 2, f"worker did the case jobs ({done})")

        view = sql("SELECT public.get_case_evidence(%s) AS v", [case_id], who=admin)[0]["v"]
        entities = view["people"] + view["vehicles"] + view["weapons"]
        print(f"      summary: {view['ai_summary']}")
        for e in entities:
            print(f"      {e['label']:10} {e['description']:50} {len(e['crops'])} crop(s), "
                  f"{e['submission_count']} submission(s), {len(e['questions'])} question(s)")
        check(len(view["submissions"]) == 2, "both submissions are combined into the case")
        check(view["ai_summary"].startswith("2 submissions"), "case AI summary written")
        crops = [c["path"] for e in entities for c in e["crops"]]
        check(all((bucket / p).exists() for p in crops), f"all {len(crops)} case crops exist in the bucket")

        # --- admin says No to a suggestion
        questions = [q for e in entities for q in e["questions"]]
        if questions:
            q = questions[0]
            sql("SELECT public.answer_entity_match(%s, false)", [int(q["member_key"])], who=admin)
            worker.run(once=True)
            view = sql("SELECT public.get_case_evidence(%s) AS v", [case_id], who=admin)[0]["v"]
            again = [x for e in view["people"] + view["vehicles"] + view["weapons"]
                     for x in e["questions"] if x["member_key"] == q["member_key"]]
            rejected = [r["entityid"] for r in sql(
                "SELECT entityid FROM public.entitymatchrejection WHERE detectionid = %s",
                [int(q["member_key"])])]
            now = sql("SELECT caseentityid, matchstatus FROM public.detection WHERE detectionid = %s",
                      [int(q["member_key"])])[0]
            check(len(rejected) == 1, "the 'No' is remembered")
            check(now["caseentityid"] not in rejected,
                  f"detection {q['member_key']} placed again, not with the rejected entity "
                  f"({now['matchstatus'] or 'unlinked'}{'; new question elsewhere' if again else ''})")
        else:
            print("      (no 'Is this ...?' question in this case - answer test skipped)")

        check(sql("SELECT count(*) AS n FROM public.aiworker WHERE workerid = 'test-worker'")[0]["n"] == 1,
              "worker heartbeat recorded")
        print(f"\nAll worker checks passed in {time.time() - started:.0f} s")
    finally:
        # clean up whatever we made, best effort
        def tidy(query, params):
            try:
                sql(query, params)
            except psycopg.Error as e:
                print(f"  (cleanup: {e.diag.message_primary})")
        if case_id:
            tidy("DELETE FROM public.aijob WHERE caseid = %s", [case_id])
            tidy("DELETE FROM public.caseevent WHERE caseid = %s", [case_id])
            tidy("DELETE FROM public.cases WHERE caseid = %s", [case_id])
        for inc in incidents:
            tidy("DELETE FROM public.aijob WHERE incidentid = %s", [inc])
            tidy("DELETE FROM public.weapondetail WHERE detectionid IN (SELECT d.detectionid FROM public.detection d "
                "JOIN public.media m USING (mediaid) WHERE m.incidentid = %s)", [inc])
            tidy("DELETE FROM public.vehicledetail WHERE detectionid IN (SELECT d.detectionid FROM public.detection d "
                "JOIN public.media m USING (mediaid) WHERE m.incidentid = %s)", [inc])
            tidy("DELETE FROM public.detection WHERE mediaid IN (SELECT mediaid FROM public.media "
                "WHERE incidentid = %s)", [inc])
            tidy("DELETE FROM public.caseevent WHERE incidentid = %s", [inc])
            tidy("DELETE FROM public.media WHERE incidentid = %s", [inc])
            tidy("DELETE FROM public.crimescene WHERE incidentid = %s", [inc])
        tidy("DELETE FROM public.aiworker WHERE workerid = 'test-worker'", None)
        for authid in users:
            tidy("DELETE FROM public.citizen WHERE userid IN "
                 "(SELECT userid FROM public.\"User\" WHERE authid = %s)", [authid])
            tidy("DELETE FROM public.caseevent WHERE actor IN "
                 "(SELECT userid FROM public.\"User\" WHERE authid = %s)", [authid])
            tidy("DELETE FROM public.\"User\" WHERE authid = %s", [authid])
            tidy("DELETE FROM auth.users WHERE id = %s", [authid])
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
