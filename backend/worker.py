"""
worker.py - the Argus AI worker. Runs on the GPU PC, takes jobs from Supabase
and does them. Nobody connects TO this machine: it only makes outgoing
connections to Supabase (no ngrok, no open ports).

    Citizen app ── submit_for_analysis(42) ──►  aijob 'analyse' 42
    worker      ── claim_next_job()        ──►  gets the job
                   download 42/media/*  →  run the pipeline (ai/main.py)
                   upload crops + results.json (upload_results.py)
                   ai_save_analysis(42, results.json)   → detection rows ...
                ── finish_job()
    Admin accepts it into case 7          ──►  aijob 'merge' 42 → 7
    worker:  ai_load_case(7) + ai_load_submission(42)
             → case_matcher.merge_submission() → ai_save_case(7, case)

Jobs (database/supabase/migrations/20261012100100_ai_pipeline_functions.sql):
    analyse   run the pipeline on a submission's files, save the results
    merge     combine an accepted submission into its case's people /
              vehicles / weapons
    rematch   place one picture again after an admin said "No, not Person 2"
    summary   re-vote a case's people / vehicles / weapons + its AI summary

Run (from the cit-event-capture folder, with the .venv switched on):

    python backend/worker.py                 keep running, check for jobs every 5 s
    python backend/worker.py --once          do the waiting jobs, then stop
    python backend/worker.py --id gpu-pc-1   name shown in the app (default: PC name)

Needs backend/.env (copy .env.example):
    SUPABASE_URL=https://<project>.supabase.co
    SUPABASE_SERVICE_ROLE_KEY=...        (secret! only on this PC, never in the app)
    ARGUS_WORKER_ID=gpu-pc-1            (optional)

A heartbeat goes to Supabase every 30 s, so the admin app can show "AI worker
online". If the worker crashes or the PC turns off mid-job, the job is put
back in the queue automatically (max 3 attempts). Log: backend/worker.log.
"""

import argparse
import logging
import os
import shutil
import socket
import sys
import threading
import time
import traceback
from logging.handlers import RotatingFileHandler
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
AI = ROOT / "ai"
sys.path.insert(0, str(AI))
sys.path.insert(0, str(HERE))

BUCKET = "submissions"
VERSION = "argus-worker 1.0"
POLL_SECONDS = 5
HEARTBEAT_SECONDS = 30
WORK_DIR = HERE / "work"                 # downloads + crops while a job runs (git-ignored)

log = logging.getLogger("argus.worker")


# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------

def make_client():
    """Supabase client with the service key from backend/.env."""
    from dotenv import load_dotenv
    from supabase import create_client

    load_dotenv(HERE / ".env")
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in backend/.env "
                 "(copy backend/.env.example)")
    return create_client(url, key)


def rpc(client, name, **params):
    """Calls a database function, returns its result."""
    return client.rpc(name, params).execute().data


def gpu_name():
    try:
        import torch
        if torch.cuda.is_available():
            return torch.cuda.get_device_name(0)
    except Exception:  # noqa: BLE001
        pass
    return "CPU only"


# ---------------------------------------------------------------------------
# The worker
# ---------------------------------------------------------------------------

class Worker:
    def __init__(self, client, worker_id, heartbeat_client=None, detector=None,
                 work_dir=WORK_DIR):
        self.client = client
        self.worker_id = worker_id
        self.heartbeat_client = heartbeat_client or client
        self.work_dir = Path(work_dir)
        self.gpu = gpu_name()
        self._detector = detector
        self._stop = threading.Event()

    # --- models: loaded once, the first time they're needed ---------------

    @property
    def detector(self):
        if self._detector is None:
            from detector import ArgusDetector
            log.info("Loading the AI models ...")
            self._detector = ArgusDetector()
            log.info("Models ready (%s)", self._detector.model_version)
        return self._detector

    # --- heartbeat ------------------------------------------------------------

    def heartbeat(self):
        try:
            rpc(self.heartbeat_client, "ai_worker_heartbeat", p_workerid=self.worker_id,
                p_gpu=self.gpu, p_version=VERSION)
        except Exception as error:  # noqa: BLE001  (network hiccup: try again later)
            log.warning("Heartbeat failed: %s", error)

    def _heartbeat_loop(self):
        while not self._stop.wait(HEARTBEAT_SECONDS):
            self.heartbeat()

    # --- main loop ------------------------------------------------------------

    def run(self, once=False, poll=POLL_SECONDS):
        """Takes and does jobs until stopped (or, with once=True, until the
        queue is empty). Returns how many jobs were done."""
        self._stop.clear()
        log.info("Worker %s started (%s, %s)", self.worker_id, self.gpu, VERSION)
        self.heartbeat()
        beat = threading.Thread(target=self._heartbeat_loop, daemon=True)
        beat.start()
        done = 0
        idle_logged = False
        try:
            while not self._stop.is_set():
                try:
                    job = self.claim()
                except Exception as error:  # noqa: BLE001  (offline? keep trying)
                    log.warning("Could not reach Supabase: %s", error)
                    if once:
                        raise
                    self._stop.wait(poll * 3)
                    continue
                if job is None:
                    if once:
                        break
                    if not idle_logged:
                        log.info("Waiting for jobs ...")
                        idle_logged = True
                    self._stop.wait(poll)
                    continue
                idle_logged = False
                self.do(job)
                done += 1
        except KeyboardInterrupt:
            log.info("Stopping (Ctrl+C)")
        finally:
            self._stop.set()
        return done

    def stop(self):
        self._stop.set()

    def claim(self):
        rows = rpc(self.client, "claim_next_job", p_workerid=self.worker_id) or []
        return rows[0] if isinstance(rows, list) and rows else None

    def do(self, job):
        """Does one job and reports it finished (or failed: the database
        retries it up to 3 times)."""
        what = {"analyse": f"incident {job['incidentid']}",
                "merge": f"incident {job['incidentid']} -> case {job['caseid']}",
                "rematch": f"detection {job['detectionid']} in case {job['caseid']}",
                "summary": f"case {job['caseid']}"}.get(job["kind"], "")
        log.info("Job %s: %s %s (attempt %s)", job["jobid"], job["kind"], what, job["attempts"])
        started = time.time()
        error = None
        try:
            handler = {"analyse": self.analyse, "merge": self.merge,
                       "rematch": self.rematch, "summary": self.summary}[job["kind"]]
            handler(job)
        except KeyboardInterrupt:
            error = "the worker was stopped during this job"
            self._finish(job, error)
            raise
        except Exception as e:  # noqa: BLE001
            error = f"{type(e).__name__}: {e}"
            log.error("Job %s failed: %s\n%s", job["jobid"], error, traceback.format_exc())
        self._finish(job, error)
        if error is None:
            log.info("Job %s done in %.0f s", job["jobid"], time.time() - started)

    def _finish(self, job, error):
        for attempt in range(3):                    # don't lose the result to a hiccup
            try:
                rpc(self.client, "finish_job", p_jobid=job["jobid"], p_error=error)
                return
            except Exception as e:  # noqa: BLE001
                log.warning("finish_job failed (%s), retrying", e)
                time.sleep(2 * (attempt + 1))
        log.error("Could not report job %s; the database will retry it later", job["jobid"])

    # --- analyse: run the pipeline on a submission ---------------------------

    def analyse(self, job):
        import main as pipeline                       # ai/main.py
        from upload_results import upload_run         # backend/upload_results.py

        incident = job["incidentid"]
        media = (self.client.table("media").select("mediaid, storagepath, mediatype")
                 .eq("incidentid", incident).order("mediaid").execute().data)
        if not media:
            raise RuntimeError(f"incident {incident} has no files")
        if len(media) > pipeline.MAX_FILES:
            raise RuntimeError(f"incident {incident} has {len(media)} files (max {pipeline.MAX_FILES})")

        folder = self.work_dir / f"incident_{incident}"
        shutil.rmtree(folder, ignore_errors=True)
        (folder / "media").mkdir(parents=True)
        try:
            files = []
            bucket = self.client.storage.from_(BUCKET)
            for index, row in enumerate(media, start=1):
                name = Path(row["storagepath"]).name
                local = folder / "media" / f"{index}_{name}"
                local.write_bytes(bucket.download(row["storagepath"]))
                files.append(local)
                log.info("  downloaded %s (%.1f MB)", row["storagepath"], local.stat().st_size / 1e6)

            # crops/submission <incident>/ : upload_results expects that name
            crops = folder / "crops" / f"submission {incident}"
            result = pipeline.analyse_submission(self.detector, files, crops, incident)
            path, uploaded = upload_run(result, crops / "results.json", incident,
                                        [row["mediaid"] for row in media], client=self.client)
            log.info("  uploaded %s", path)
            stats = rpc(self.client, "ai_save_analysis", p_incidentid=incident,
                        p_result=uploaded, p_summary=pipeline.submission_summary(result))
            log.info("  saved: %s", stats)
        finally:
            shutil.rmtree(folder, ignore_errors=True)   # everything is in Supabase now

    # --- case jobs: merge / rematch / summary --------------------------------

    def _load_case(self, job):
        return rpc(self.client, "ai_load_case", p_caseid=job["caseid"])

    def _save_case(self, case):
        import case_matcher as cm
        cm.revote_case(case)
        stats = rpc(self.client, "ai_save_case", p_caseid=case["case_id"], p_case=case)
        log.info("  case %s saved: %s", case["case_id"], stats)
        return stats

    def merge(self, job):
        import case_matcher as cm
        case = self._load_case(job)
        sub = rpc(self.client, "ai_load_submission", p_incidentid=job["incidentid"])
        if any(s["submission"] == sub["submission"] for s in case["submissions"]):
            log.info("  incident %s is already combined into case %s", job["incidentid"], job["caseid"])
        else:
            report = cm.merge_submission(case, sub)
            log.info("  %d new, %d linked, %d question(s), %d update(s)",
                     len(report["new"]), len(report["linked"]),
                     len(report["questions"]), len(report["updated"]))
        self._save_case(case)

    def rematch(self, job):
        import case_matcher as cm
        case = self._load_case(job)
        detection = str(job["detectionid"])
        if not any(m["key"] == detection for e in case["entities"] for m in e["members"]):
            row = (self.client.table("detection").select("mediaid")
                   .eq("detectionid", job["detectionid"]).execute().data)
            if row:
                media = (self.client.table("media").select("incidentid")
                         .eq("mediaid", row[0]["mediaid"]).execute().data)
                sub = rpc(self.client, "ai_load_submission", p_incidentid=media[0]["incidentid"])
                member = next((m for m in sub["members"] if m["key"] == detection), None)
                in_case = any(s["submission"] == sub["submission"] for s in case["submissions"])
                if member and in_case:
                    target = cm.place_member(case, member)
                    log.info("  detection %s -> %s (%s)", detection, target["label"], member["status"])
        self._save_case(case)

    def summary(self, job):
        self._save_case(self._load_case(job))


# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

def setup_logging():
    log.setLevel(logging.INFO)
    log.propagate = False                     # Ultralytics sets up the root logger too
    fmt = logging.Formatter("%(asctime)s  %(message)s", "%Y-%m-%d %H:%M:%S")
    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(fmt)
    log.addHandler(console)
    file = RotatingFileHandler(HERE / "worker.log", maxBytes=5_000_000, backupCount=3,
                               encoding="utf-8")
    file.setFormatter(fmt)
    log.addHandler(file)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Argus AI worker: does the jobs Supabase queues.")
    parser.add_argument("--id", help="worker name shown in the app (default: ARGUS_WORKER_ID or the PC name)")
    parser.add_argument("--once", action="store_true", help="do the waiting jobs, then stop")
    parser.add_argument("--poll", type=float, default=POLL_SECONDS, help="seconds between checks")
    args = parser.parse_args(argv)

    os.environ.setdefault("OPENCV_LOG_LEVEL", "ERROR")
    setup_logging()
    client = make_client()
    worker_id = args.id or os.environ.get("ARGUS_WORKER_ID") or socket.gethostname()
    # model files (yolo26s.pt ...) are found / downloaded in the ai folder
    os.chdir(AI)
    worker = Worker(client, worker_id, heartbeat_client=make_client())
    worker.detector                      # load the models now: problems show at once
    worker.run(once=args.once, poll=args.poll)


if __name__ == "__main__":
    main()
