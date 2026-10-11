"""
upload_results.py - upload one AI pipeline run to Supabase Storage.

Run it after ai/main.py, with the report (incident) the files came from and
the media id of each file, in the same order the files were given to main.py:

    cd ai
    python main.py clip1.mp4 clip2.mp4
    cd ..
    python backend/upload_results.py "ai/crops/submission 3/results.json" --incident 42 --media 17 18

(ai/output_detections.json, the copy of the latest results.json, works too.)

The results stay a JSON file (a submission can give hundreds of detections,
far too many to keep as table rows). Everything goes into the incident's
folder in the private 'submissions' bucket, next to the citizen's footage:

    42/media/<file>                                    citizen's upload
    42/ai/20261008T170155/results.json                 this run
    42/ai/20261008T170155/1_clip1/vehicle_3.png ...    its pictures
    42/ai/20261008T170155/2_clip2/...

Only pictures that results.json mentions are uploaded, and the paths inside
the uploaded results.json are rewritten to their place in the bucket. A
re-run gets a new folder, so earlier results are never overwritten. Last,
each media row's airesultpath points at the new results.json and its
processingstatus becomes 'completed' (or 'failed' if that file could not be
analysed).

Citizens can't read the ai/ folder; admins and investigators assigned to
the case can (migration 20261009090000_submissions_bucket.sql).

Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in backend/.env (copy
.env.example). The service key can read and write everything: keep it on the
machine that runs the pipeline, never in the mobile or web app.

Reading a result back (app or script, signed in as admin / assigned
investigator):
    path = media_row["airesultpath"]
    data = json.loads(supabase.storage.from_("submissions").download(path))
    pic = data["files"][0]["detections"][0]["crop_path"]
    url = supabase.storage.from_("submissions").create_signed_url(pic, 3600)["signedURL"]
"""

import argparse
import copy
import json
import os
import sys
from datetime import datetime
from pathlib import Path, PureWindowsPath

BUCKET = "submissions"
RESULT_NAME = "results.json"
PICTURE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


class UploadError(Exception):
    """Bad input (wrong media ids, missing pictures folder, ...)."""


def get_client():
    """Supabase client with the service key (from backend/.env or the environment)."""
    from dotenv import load_dotenv
    from supabase import create_client

    load_dotenv(Path(__file__).with_name(".env"))
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise UploadError("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in backend/.env "
                         "(copy backend/.env.example) to upload results")
    return create_client(url, key)


def processed_time(result):
    """When the run happened, with the time zone (main.py writes local time
    without one; this script runs on the same machine, so local is right)."""
    t = datetime.fromisoformat(result["processed_at"])
    return t if t.tzinfo else t.astimezone()


def run_folder(incident_id, result):
    """'42/ai/20261008T170155' - where this run goes in the bucket."""
    return f"{int(incident_id)}/ai/{processed_time(result).strftime('%Y%m%dT%H%M%S')}"


def submission_dir(result, json_path):
    """The local 'crops/submission N' folder that holds the run's pictures."""
    name = f"submission {result['submission']}"
    json_path = Path(json_path)
    for folder in (json_path.parent, json_path.parent / "crops" / name):
        if folder.name == name and folder.is_dir():
            return folder
    raise UploadError(f"Can't find the '{name}' pictures folder next to {json_path}")


def _picture(value, sub_dir):
    """Path in results.json (e.g. 'crops\\submission 1\\1_clip\\vehicle_2.png',
    written on Windows or Linux) -> (local file, path inside the run folder),
    or None if it isn't a picture of this submission."""
    if not isinstance(value, str) or not value:
        return None
    parts = PureWindowsPath(value).parts            # understands both \ and /
    if sub_dir.name not in parts:
        return None
    inside = parts[parts.index(sub_dir.name) + 1:]
    if not inside or ".." in inside or Path(inside[-1]).suffix.lower() not in PICTURE_TYPES:
        return None
    local = sub_dir.joinpath(*inside)
    return (local, "/".join(inside)) if local.is_file() else None


def _picture_fields(result):
    """Every dict in results.json that can hold picture paths."""
    for f in result.get("files", []):
        yield f
        yield from f.get("detections", [])


def prepare(result, json_path, incident_id, media_ids):
    """The results.json to upload (paths rewritten for the bucket, media ids
    added) and the pictures to upload as (bucket path, local file)."""
    files = result.get("files", [])
    if len(media_ids) != len(files):
        raise UploadError(f"results.json has {len(files)} file(s) but {len(media_ids)} "
                         f"media id(s) were given: give one per file, in the same order")

    folder = run_folder(incident_id, result)
    sub_dir = submission_dir(result, json_path)
    out = copy.deepcopy(result)
    pictures = {}
    def to_bucket(value):
        found = _picture(value, sub_dir)
        if not found:
            return None
        bucket_path = f"{folder}/{found[1]}"
        pictures[bucket_path] = found[0]
        return bucket_path                      # ready for create_signed_url()

    for obj in _picture_fields(out):
        for key, value in obj.items():
            if key.endswith("_path") and key != "source_path":
                bucket_path = to_bucket(value)
                if bucket_path:
                    obj[key] = bucket_path
            elif key.endswith("_paths") and isinstance(value, list):   # extra_crop_paths
                obj[key] = [to_bucket(v) or v for v in value]

    for f, media_id in zip(out["files"], media_ids):
        f["mediaid"] = int(media_id)
        f["source_path"] = PureWindowsPath(f.get("source_path", "")).name  # no local folders
        if f.get("crops_folder"):
            f["crops_folder"] = f"{folder}/{PureWindowsPath(f['crops_folder']).name}"
    out["incidentid"] = int(incident_id)
    out["storage_bucket"] = BUCKET
    out["storage_folder"] = folder
    return out, folder, sorted(pictures.items())


def check_media(client, incident_id, media_ids):
    """Every media id must belong to that incident (stops results landing on
    the wrong report)."""
    rows = (client.table("media").select("mediaid, incidentid")
            .in_("mediaid", [int(m) for m in media_ids]).execute().data)
    found = {r["mediaid"]: r["incidentid"] for r in rows}
    wrong = [m for m in media_ids if found.get(int(m)) != int(incident_id)]
    if wrong:
        raise UploadError(f"media id(s) {wrong} are not files of incident {incident_id}")


def upload_results(result, json_path, incident_id, media_ids, client=None):
    """Upload one run (results.json + its pictures) and point the media rows
    at it. Returns the results.json path in the bucket."""
    client = client or get_client()
    check_media(client, incident_id, media_ids)
    out, folder, pictures = prepare(result, json_path, incident_id, media_ids)

    bucket = client.storage.from_(BUCKET)
    for bucket_path, local in pictures:
        bucket.upload(bucket_path, local.read_bytes(),
                      {"content-type": PICTURE_TYPES[local.suffix.lower()], "upsert": "true"})

    # results.json goes last: it only exists once all its pictures are there
    json_bucket_path = f"{folder}/{RESULT_NAME}"
    bucket.upload(json_bucket_path, json.dumps(out, indent=2).encode("utf-8"),
                  {"content-type": "application/json", "upsert": "true"})

    when = processed_time(result).isoformat()
    for f in out["files"]:
        client.table("media").update({
            "airesultpath": json_bucket_path,
            "airesultat": when,
            "processingstatus": "failed" if "error" in f else "completed",
        }).eq("mediaid", f["mediaid"]).execute()
    return json_bucket_path


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Upload an AI pipeline run (results.json + pictures) to Supabase Storage.")
    parser.add_argument("results", help='results.json of the run, e.g. "ai/crops/submission 3/results.json"')
    parser.add_argument("--incident", type=int, required=True, help="crimescene.incidentid of the report")
    parser.add_argument("--media", type=int, nargs="+", required=True,
                        help="media.mediaid of each file, in the order the files were given to main.py")
    args = parser.parse_args(argv)

    json_path = Path(args.results)
    if not json_path.is_file():
        parser.exit(1, f"Error: file not found: {json_path}\n")
    result = json.loads(json_path.read_text(encoding="utf-8"))
    if "files" not in result:
        parser.exit(1, f"Error: {json_path} is not a submission results.json (no 'files' list)\n")

    try:
        path = upload_results(result, json_path, args.incident, args.media)
    except UploadError as error:
        parser.exit(1, f"Error: {error}\n")
    print(f"Uploaded to Supabase Storage: {BUCKET}/{path}")


if __name__ == "__main__":
    sys.exit(main())
