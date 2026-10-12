"""
submit_test.py - send test footage to Supabase as a new submission, the way
the citizen app will, so the AI worker picks it up. For testing the worker
before the app's real upload is finished.

    python backend/submit_test.py clip.mp4 photo.jpg                     (1-5 files = 1 submission)
    python backend/submit_test.py clip.mp4 --location "N1 Midrand" --lat -25.99 --lon 28.13
    python backend/submit_test.py clip.mp4 --reporter someone@example.com

What it does (with the service key from backend/.env):
  1. creates the incident (crimescene), reported by --reporter (an existing
     user's email; default: the first admin)
  2. uploads each file to  submissions/<incidentid>/media/<random>.<ext>
  3. adds the media rows
  4. queues the analysis (an 'analyse' job) - like submit_for_analysis()
Then the worker (python backend/worker.py) analyses it within seconds.
The submission shows up in the admin app's Submissions tab like any other.
"""

import argparse
import mimetypes
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from worker import BUCKET, make_client  # noqa: E402

IMAGE_TYPES = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".bmp", ".tif", ".tiff", ".gif"}
MIME = {".mp4": "video/mp4", ".mov": "video/quicktime", ".avi": "video/x-msvideo",
        ".mkv": "video/x-matroska", ".m4v": "video/x-m4v", ".3gp": "video/3gpp",
        ".webm": "video/webm", ".heic": "image/heic", ".heif": "image/heif"}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Send test footage to Supabase as a submission.")
    parser.add_argument("files", nargs="+", help="1-5 videos / photos (one submission)")
    parser.add_argument("--location", default="Test submission", help="typed location text")
    parser.add_argument("--lat", type=float, help="phone latitude (used when the files have no GPS)")
    parser.add_argument("--lon", type=float, help="phone longitude")
    parser.add_argument("--description", default="Test footage sent with backend/submit_test.py")
    parser.add_argument("--reporter", help="email of the user who 'reports' it (default: first admin)")
    args = parser.parse_args(argv)

    files = [Path(f) for f in args.files]
    if not 1 <= len(files) <= 5:
        parser.exit(1, "Give 1 to 5 files (one submission)\n")
    missing = [str(f) for f in files if not f.is_file()]
    if missing:
        parser.exit(1, f"File(s) not found: {', '.join(missing)}\n")
    if (args.lat is None) != (args.lon is None):
        parser.exit(1, "Give both --lat and --lon, or neither\n")

    client = make_client()
    users = client.table("User").select("userid, email, role")
    users = (users.eq("email", args.reporter) if args.reporter
             else users.eq("role", "admin")).order("userid").limit(1).execute().data
    if not users:
        parser.exit(1, f"No user {'with email ' + args.reporter if args.reporter else 'with role admin'}\n")
    reporter = users[0]

    incident = client.table("crimescene").insert({
        "location": args.location,
        "datetime": datetime.now(timezone.utc).isoformat(),
        "reportedby": reporter["userid"],
        "description": args.description,
        "latitude": args.lat,
        "longitude": args.lon,
        "gpssource": "phone" if args.lat is not None else "typed",
    }).execute().data[0]["incidentid"]
    print(f"Incident {incident} created (reported by {reporter['email']})")

    bucket = client.storage.from_(BUCKET)
    for f in files:
        ext = f.suffix.lower()
        path = f"{incident}/media/{uuid.uuid4().hex}{ext}"
        mime = MIME.get(ext) or mimetypes.guess_type(f.name)[0] or "application/octet-stream"
        bucket.upload(path, f.read_bytes(), {"content-type": mime})
        client.table("media").insert({
            "incidentid": incident,
            "uploadedby": reporter["userid"],
            "mediatype": "image" if ext in IMAGE_TYPES else "video",
            "storagepath": path,
            "filesize": f.stat().st_size,
            "processingstatus": "pending",
        }).execute()
        print(f"  uploaded {f.name} -> {BUCKET}/{path}")

    # what submit_for_analysis() does (that function is for the app's users)
    client.table("crimescene").update({"aisummarystatus": "processing"}).eq("incidentid", incident).execute()
    job = client.table("aijob").insert({"kind": "analyse", "incidentid": incident}).execute().data[0]
    print(f"Analysis queued (job {job['jobid']}). Is the worker running? python backend/worker.py")


if __name__ == "__main__":
    main()
