"""
Uploads one pipeline run (results.json plus its crops) to Supabase Storage.

The worker calls upload_run() directly. You can also run it by hand after
ai/main.py, passing the incident and the media id of each file in the same
order you gave them to main.py:

    python backend/upload_results.py "ai/crops/submission 3/results.json" --incident 42 --media 17 18

We keep results as a JSON file rather than table rows because one submission
can easily have hundreds of detections. It all lands in the incident's
folder in the private 'submissions' bucket:

    42/media/<file>                          the citizen's upload
    42/ai/20261008T170155/results.json       this run
    42/ai/20261008T170155/1_clip1/*.png      its crops

Only crops that results.json actually refers to get uploaded, and the paths
inside it are rewritten to bucket paths. Each run gets its own timestamped
folder so re-runs never overwrite old results. Citizens can't read the ai/
folder, admins and assigned investigators can (see the
20261009090000_submissions_bucket.sql migration).

Needs the service key in backend/.env, which must never end up in an app.
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
    """Something wrong with the input, e.g. mismatched media ids."""


def get_client():
    """Service-role client from backend/.env or the environment."""
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
    """processed_at as an aware datetime. main.py writes local time with no
    zone, and since we run on the same machine, local is correct."""
    t = datetime.fromisoformat(result["processed_at"])
    return t if t.tzinfo else t.astimezone()


def run_folder(incident_id, result):
    """e.g. '42/ai/20261008T170155'"""
    return f"{int(incident_id)}/ai/{processed_time(result).strftime('%Y%m%dT%H%M%S')}"


def submission_dir(result, json_path):
    """Find the local 'submission N' folder with the crops in it."""
    name = f"submission {result['submission']}"
    json_path = Path(json_path)
    for folder in (json_path.parent, json_path.parent / "crops" / name):
        if folder.name == name and folder.is_dir():
            return folder
    raise UploadError(f"Can't find the '{name}' pictures folder next to {json_path}")


def _picture(value, sub_dir):
    """Map a path from results.json to (local file, path within the run
    folder). Paths may have been written on Windows or Linux. Returns None if
    it isn't one of this submission's pictures."""
    if not isinstance(value, str) or not value:
        return None
    parts = PureWindowsPath(value).parts            # handles both \ and /
    if sub_dir.name not in parts:
        return None
    inside = parts[parts.index(sub_dir.name) + 1:]
    if not inside or ".." in inside or Path(inside[-1]).suffix.lower() not in PICTURE_TYPES:
        return None
    local = sub_dir.joinpath(*inside)
    return (local, "/".join(inside)) if local.is_file() else None


def _picture_fields(result):
    """All the dicts in results.json that might hold crop paths."""
    for f in result.get("files", []):
        yield f
        yield from f.get("detections", [])


def prepare(result, json_path, incident_id, media_ids):
    """Build the results.json to upload (bucket paths, media ids filled in)
    plus the list of (bucket path, local file) pictures to send."""
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
        return bucket_path

    for obj in _picture_fields(out):
        for key, value in obj.items():
            if key.endswith("_path") and key != "source_path":
                bucket_path = to_bucket(value)
                if bucket_path:
                    obj[key] = bucket_path
            elif key.endswith("_paths") and isinstance(value, list):   # e.g. extra_crop_paths
                obj[key] = [to_bucket(v) or v for v in value]

    for f, media_id in zip(out["files"], media_ids):
        f["mediaid"] = int(media_id)
        f["source_path"] = PureWindowsPath(f.get("source_path", "")).name  # don't leak local folder names
        if f.get("crops_folder"):
            f["crops_folder"] = f"{folder}/{PureWindowsPath(f['crops_folder']).name}"
    out["incidentid"] = int(incident_id)
    out["storage_bucket"] = BUCKET
    out["storage_folder"] = folder
    return out, folder, sorted(pictures.items())


def check_media(client, incident_id, media_ids):
    """Make sure every media id really belongs to this incident, so results
    can't end up attached to the wrong report."""
    rows = (client.table("media").select("mediaid, incidentid")
            .in_("mediaid", [int(m) for m in media_ids]).execute().data)
    found = {r["mediaid"]: r["incidentid"] for r in rows}
    wrong = [m for m in media_ids if found.get(int(m)) != int(incident_id)]
    if wrong:
        raise UploadError(f"media id(s) {wrong} are not files of incident {incident_id}")


def upload_results(result, json_path, incident_id, media_ids, client=None):
    """Upload a run and point the media rows at it. Returns the bucket path
    of results.json."""
    return upload_run(result, json_path, incident_id, media_ids, client)[0]


def upload_run(result, json_path, incident_id, media_ids, client=None):
    """Like upload_results, but also returns the uploaded results dict. The
    worker needs that to pass to ai_save_analysis()."""
    client = client or get_client()
    check_media(client, incident_id, media_ids)
    out, folder, pictures = prepare(result, json_path, incident_id, media_ids)

    bucket = client.storage.from_(BUCKET)
    for bucket_path, local in pictures:
        bucket.upload(bucket_path, local.read_bytes(),
                      {"content-type": PICTURE_TYPES[local.suffix.lower()], "upsert": "true"})

    # upload results.json last, so if it exists its pictures definitely do too
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
    return json_bucket_path, out


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
