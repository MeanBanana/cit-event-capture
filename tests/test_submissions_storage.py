"""
End-to-end tests for the 'submissions' bucket
(20261009090000_submissions_bucket.sql) and backend/upload_results.py.

Plain script, no pytest. Needs supabase, python-dotenv, requests and pillow,
which are all in ai/requirements.txt already. boto3 is only for the optional
S3 test.

Local Supabase only, it creates real users and data:

    cd database && supabase start && supabase db reset && cd ..
    python tests/test_submissions_storage.py

The defaults match `supabase start`. If `supabase status` shows different
keys, set ARGUS_TEST_URL / ARGUS_TEST_ANON_KEY / ARGUS_TEST_SERVICE_KEY.
The S3 test only runs if ARGUS_TEST_S3_KEY and ARGUS_TEST_S3_SECRET are set.

Unlike the other DB tests this goes through the real Auth/Storage/REST APIs:
accounts get created with the Auth admin API, then actually sign in with
email and password, so it's the bucket's RLS policies deciding every result.
"""

import io
import json
import os
import subprocess
import sys
import tempfile
import time
import traceback
import uuid
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

import requests
from supabase import create_client

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
import upload_results as uploader  # noqa: E402

# The well-known local demo keys `supabase start` prints, not real secrets
DEMO_ANON = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6"
             "ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0")
DEMO_SERVICE = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6"
                "InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU")

URL = os.environ.get("ARGUS_TEST_URL", "http://127.0.0.1:54321")
ANON_KEY = os.environ.get("ARGUS_TEST_ANON_KEY", DEMO_ANON)
SERVICE_KEY = os.environ.get("ARGUS_TEST_SERVICE_KEY", DEMO_SERVICE)
BUCKET = "submissions"
RUN = uuid.uuid4().hex[:8]          # so repeated runs don't collide
PASSWORD = "Test-password-123!"

# Safety net, this must never point at a hosted project
if urlparse(URL).hostname not in ("127.0.0.1", "localhost"):
    sys.exit(f"Refusing to run against {URL}: these tests create users and data. Local Supabase only.")


# ------------------------------------------------------------------ helpers
class Skip(Exception):
    pass


def expect_error(fn, contains=None):
    """Expect the call to be refused, and return the error text."""
    try:
        fn()
    except Exception as e:  # noqa: BLE001
        if contains and contains not in str(e):
            raise AssertionError(f"refused, but with an unexpected error: {e}")
        return str(e)
    raise AssertionError("expected this to be refused, but it was allowed")


def service():
    return create_client(URL, SERVICE_KEY)


_clients = {}


def client_for(user):
    """Client signed in as that user, same as the app after login."""
    if user["email"] not in _clients:
        c = create_client(URL, ANON_KEY)
        c.auth.sign_in_with_password({"email": user["email"], "password": PASSWORD})
        _clients[user["email"]] = c
    return _clients[user["email"]]


def make_user(name, role, meta=None):
    """Make a login via the Auth admin API, putting the role in app_metadata
    the way create-investigator does. The sign-up trigger creates the
    "User" row."""
    email = f"{name}.{RUN}@test.local"
    res = service().auth.admin.create_user({
        "email": email, "password": PASSWORD, "email_confirm": True,
        "app_metadata": {"role": role},
        "user_metadata": {"username": f"{name}_{RUN}", "firstname": name.title(),
                          "surname": "Test", **(meta or {})},
    })
    row = service().table("User").select("userid, role").eq("authid", res.user.id).single().execute().data
    assert row["role"] == role, f"{name} became {row['role']}, expected {role}"
    return {"email": email, "authid": res.user.id, "userid": row["userid"], "role": role}


def media_row(mediaid):
    return service().table("media").select("*").eq("mediaid", mediaid).single().execute().data


def png_bytes():
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (8, 8), (200, 30, 30)).save(buf, format="PNG")
    return buf.getvalue()


VIDEO = b"\x00\x00\x00\x18ftypmp42" + os.urandom(2048)   # mp4 header + filler


def report_incident(user):
    """Citizen reports an incident through the REST API, like the app."""
    return client_for(user).table("crimescene").insert({
        "location": "N1, Midrand", "datetime": "2026-10-08T18:30:00+02:00",
        "reportedby": user["userid"], "description": "test"}).execute().data[0]["incidentid"]


def upload_footage(user, incident, data=VIDEO, ctype="video/mp4"):
    path = f"{incident}/media/{uuid.uuid4().hex}.mp4"
    client_for(user).storage.from_(BUCKET).upload(path, data, {"content-type": ctype})
    return path


def add_media_row(user, incident, path):
    return client_for(user).table("media").insert({
        "incidentid": incident, "uploadedby": user["userid"], "mediatype": "video",
        "storagepath": path, "filesize": len(VIDEO)}).execute().data[0]["mediaid"]


def names_in(client, folder):
    return {o["name"] for o in client.storage.from_(BUCKET).list(folder)}


# ------------------------------------------------------------------ setup
SUBMISSION = 7
PROCESSED_AT = "2026-10-08T17:01:55.918215"      # main.py writes local time with no zone


def pic(folder, name):
    return f"crops\\submission {SUBMISSION}\\{folder}\\{name}"   # Windows-style, as main.py writes


def make_submission(tmp, processed_at=PROCESSED_AT, second_file_error=False):
    """A two-file results.json in main.py's format, plus a tiny image for every
    path it mentions, under ai/crops/submission N/."""
    clip = {
        "source_path": "C:\\Users\\someone\\Videos\\clip1.mp4", "source_type": "video",
        "crops_folder": f"crops\\submission {SUBMISSION}\\1_clip1",
        "vehicle_count": 1, "person_count": 1, "weapon_count": 1,
        "people_peak_frame_path": pic("1_clip1", "people_peak.png"),
        "audio_available": True, "audio_events": [],
        "detections": [
            {"track_id": 3, "detection_type": "vehicle", "class_name": "car",
             "crop_path": pic("1_clip1", "vehicle_3.png"), "plate_crop_path": pic("1_clip1", "plate_3.png"),
             "plate": "CA123456"},
            {"track_id": 7, "detection_type": "person", "class_name": "person",
             "person_crop_path": pic("1_clip1", "person_7.png"), "face_crop_path": pic("1_clip1", "face_7.png")},
            {"track_id": 2, "detection_type": "weapon", "class_name": "long_gun",
             "crop_path": pic("1_clip1", "weapon_2.png")},
        ],
    }
    photo = {
        "source_path": "photo1.jpg", "source_type": "image",
        "crops_folder": f"crops\\submission {SUBMISSION}\\2_photo1",
        "vehicle_count": 1, "person_count": 0, "weapon_count": 0,
        "audio_available": False, "audio_events": [],
        "detections": [{"track_id": 1, "detection_type": "vehicle", "class_name": "car",
                        "crop_path": pic("2_photo1", "vehicle_1.png")}],
    }
    if second_file_error:
        photo = {"source_path": "photo1.jpg", "error": "Could not open"}
    result = {"submission": SUBMISSION, "processed_at": processed_at, "model_version": "test",
              "file_count": 2, "totals": {"vehicles": 2, "people": 1, "weapons": 1, "audio_events": 0},
              "files": [clip, photo]}

    ai = Path(tmp, "ai")
    for obj in [f for f in result["files"]] + [d for f in result["files"] for d in f.get("detections", [])]:
        for key, val in obj.items():
            if key.endswith("_path") and key != "source_path":
                f = ai.joinpath(*val.split("\\"))
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_bytes(png_bytes())
    json_path = ai / "crops" / f"submission {SUBMISSION}" / "results.json"
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return result, json_path


def picture_names(result):
    names = set()
    for f in result["files"]:
        for obj in [f, *f.get("detections", [])]:
            for key, val in obj.items():
                if key.endswith("_path") and key != "source_path" and val:
                    names.add("/".join(val.split("\\")[-2:]))
    return names


def build_world(tmp):
    """Fixture: two citizens with an incident each, two investigators, an admin,
    alice's two files uploaded and one AI run stored."""
    w = {
        "alice": make_user("alice", "citizen"),
        "bob": make_user("bob", "citizen"),
        "ivan": make_user("ivan", "investigator", {"badgenumber": f"B{RUN}1", "station": "Midrand"}),
        "ian": make_user("ian", "investigator", {"badgenumber": f"B{RUN}2", "station": "Sandton"}),
        "admin": make_user("admin", "admin"),
    }
    w["inc_a"] = report_incident(w["alice"])
    w["inc_b"] = report_incident(w["bob"])
    w["video_a"] = upload_footage(w["alice"], w["inc_a"])
    w["media_a"] = add_media_row(w["alice"], w["inc_a"], w["video_a"])
    w["photo_a"] = upload_footage(w["alice"], w["inc_a"])
    w["media_a2"] = add_media_row(w["alice"], w["inc_a"], w["photo_a"])
    w["video_b"] = upload_footage(w["bob"], w["inc_b"])
    w["media_b"] = add_media_row(w["bob"], w["inc_b"], w["video_b"])

    w["tmp"] = Path(tmp)
    w["result"], w["json_path"] = make_submission(Path(tmp, "run1"))
    w["ai_json"] = uploader.upload_results(w["result"], w["json_path"], w["inc_a"],
                                           [w["media_a"], w["media_a2"]], client=service())
    w["ai_folder"] = w["ai_json"].rsplit("/", 1)[0]

    # admin puts incident A in a case and assigns ivan, ian stays unassigned
    adm = client_for(w["admin"])
    w["case"] = adm.rpc("create_case", {"p_title": f"Test {RUN}",
                                        "p_incidentids": [w["inc_a"]]}).execute().data
    adm.rpc("assign_investigator", {"p_caseid": w["case"], "p_userid": w["ivan"]["userid"]}).execute()
    return w


# ------------------------------------------------------------------ bucket
def test_bucket_is_private_with_limits(w):
    b = service().storage.get_bucket(BUCKET)
    assert b.public is False
    assert b.file_size_limit == 50 * 1024 * 1024
    assert {"video/mp4", "video/quicktime", "image/jpeg", "image/heic",
            "application/json"} <= set(b.allowed_mime_types)


def test_public_link_does_not_work(w):
    url = service().storage.from_(BUCKET).get_public_url(w["video_a"])
    assert requests.get(url).status_code in (400, 404)


# ------------------------------------------------------------------ citizen
def test_citizen_uploads_and_reads_own_footage(w):
    alice = client_for(w["alice"])
    assert alice.storage.from_(BUCKET).download(w["video_a"]) == VIDEO
    assert w["video_a"].split("/")[-1] in names_in(alice, f"{w['inc_a']}/media")


def test_citizen_cannot_upload_to_someone_elses_incident(w):
    expect_error(lambda: upload_footage(w["alice"], w["inc_b"]), "row-level security")


def test_citizen_cannot_read_someone_elses_footage(w):
    alice = client_for(w["alice"])
    expect_error(lambda: alice.storage.from_(BUCKET).download(w["video_b"]))
    assert names_in(alice, f"{w['inc_b']}/media") == set()


def test_citizen_cannot_write_or_read_ai_folder(w):
    alice = client_for(w["alice"]).storage.from_(BUCKET)
    expect_error(lambda: alice.upload(f"{w['inc_a']}/ai/{w['media_a']}/fake/output_detections.json",
                                      b"{}", {"content-type": "application/json"}))
    expect_error(lambda: alice.download(w["ai_json"]))
    assert names_in(client_for(w["alice"]), f"{w['inc_a']}/ai") == set()


def test_citizen_cannot_overwrite_or_delete_footage(w):
    alice = client_for(w["alice"]).storage.from_(BUCKET)
    expect_error(lambda: alice.upload(w["video_a"], b"tampered",
                                      {"content-type": "video/mp4", "upsert": "true"}))
    alice.remove([w["video_a"]])          # silently ignored: no delete policy
    assert alice.download(w["video_a"]) == VIDEO


def test_citizen_cannot_upload_outside_media_folder(w):
    alice = client_for(w["alice"]).storage.from_(BUCKET)
    for path in (f"{w['inc_a']}/clip.mp4",            # not in media/
                 f"{w['inc_a']}/media/sub/clip.mp4",  # nested folder
                 f"x{w['inc_a']}/media/clip.mp4"):    # not an incident id
        expect_error(lambda p=path: alice.upload(p, VIDEO, {"content-type": "video/mp4"}))


def test_wrong_file_type_rejected(w):
    expect_error(lambda: upload_footage(w["alice"], w["inc_a"], data=b"MZ...",
                                        ctype="application/x-msdownload"))


def test_file_over_50mb_rejected(w):
    big = b"\x00" * (50 * 1024 * 1024 + 1)
    expect_error(lambda: upload_footage(w["alice"], w["inc_a"], data=big))


def test_media_row_must_point_into_own_incident(w):
    expect_error(lambda: add_media_row(w["alice"], w["inc_a"], w["video_b"]), "storagepath")


def test_app_users_cannot_set_ai_pointer(w):
    before = media_row(w["media_a"])["airesultpath"]
    # citizens can't update media rows at all, the update just matches nothing
    client_for(w["alice"]).table("media").update({"airesultpath": "x"}).eq("mediaid", w["media_a"]).execute()
    # admins can update media rows, just not the AI fields
    expect_error(lambda: client_for(w["admin"]).table("media").update({"airesultpath": "x"})
                 .eq("mediaid", w["media_a"]).execute(), "analysis pipeline only")
    assert media_row(w["media_a"])["airesultpath"] == before


def test_signed_out_user_gets_nothing(w):
    anon = create_client(URL, ANON_KEY).storage.from_(BUCKET)
    expect_error(lambda: anon.download(w["video_a"]))
    expect_error(lambda: anon.upload(f"{w['inc_a']}/media/anon.mp4", VIDEO, {"content-type": "video/mp4"}))


# ------------------------------------------------------------------ pipeline
def test_pipeline_upload_layout(w):
    run = w["ai_folder"]
    local = datetime.fromisoformat(PROCESSED_AT).astimezone()
    assert run == f"{w['inc_a']}/ai/{local.strftime('%Y%m%dT%H%M%S')}", run
    uploaded = set()
    for sub in ("1_clip1", "2_photo1"):
        uploaded |= {f"{sub}/{n}" for n in names_in(service(), f"{run}/{sub}")}
    assert uploaded == picture_names(w["result"]), uploaded
    assert "results.json" in names_in(service(), run)

    data = json.loads(service().storage.from_(BUCKET).download(w["ai_json"]))
    assert data["storage_folder"] == run and data["incidentid"] == w["inc_a"]
    assert [f["mediaid"] for f in data["files"]] == [w["media_a"], w["media_a2"]]
    assert data["files"][0]["source_path"] == "clip1.mp4"          # no local folders uploaded
    for f in data["files"]:
        for obj in [f, *f["detections"]]:
            for key, val in obj.items():
                if key.endswith("_path") and key != "source_path":
                    assert val.startswith(f"{run}/"), val


def test_pipeline_sets_media_pointers(w):
    for mid in (w["media_a"], w["media_a2"]):
        row = media_row(mid)
        assert row["airesultpath"] == w["ai_json"]
        assert row["processingstatus"] == "completed"
        # the run's local time should be stored as the right moment, not shifted
        assert datetime.fromisoformat(row["airesultat"]) == datetime.fromisoformat(PROCESSED_AT).astimezone()


def test_rerun_keeps_old_result_and_marks_failed_file(w):
    result, json_path = make_submission(w["tmp"] / "run2", processed_at="2026-10-09T10:00:00",
                                        second_file_error=True)
    new = uploader.upload_results(result, json_path, w["inc_a"], [w["media_a"], w["media_a2"]],
                                  client=service())
    assert new != w["ai_json"]
    assert json.loads(service().storage.from_(BUCKET).download(w["ai_json"]))   # old one still there
    assert media_row(w["media_a"])["airesultpath"] == new
    assert media_row(w["media_a"])["processingstatus"] == "completed"
    assert media_row(w["media_a2"])["processingstatus"] == "failed"


def test_uploader_refuses_wrong_media(w):
    # need one media id per file
    expect_error(lambda: uploader.upload_results(w["result"], w["json_path"], w["inc_a"],
                                                 [w["media_a"]], client=service()), "one per file")
    # bob's file is not part of alice's incident
    expect_error(lambda: uploader.upload_results(w["result"], w["json_path"], w["inc_a"],
                                                 [w["media_a"], w["media_b"]], client=service()),
                 "not files of incident")


# ------------------------------------------------------------------ investigators / admin
def test_assigned_investigator_reads_footage_and_ai(w):
    ivan = client_for(w["ivan"]).storage.from_(BUCKET)
    assert ivan.download(w["video_a"]) == VIDEO
    data = json.loads(ivan.download(w["ai_json"]))
    crop = next(d["crop_path"] for f in data["files"] for d in f.get("detections", []) if d.get("crop_path"))
    r = requests.get(ivan.create_signed_url(crop, 60)["signedURL"])
    assert r.status_code == 200 and r.content[:4] == b"\x89PNG"


def test_assigned_investigator_can_add_footage_but_not_elsewhere(w):
    upload_footage(w["ivan"], w["inc_a"])
    expect_error(lambda: upload_footage(w["ivan"], w["inc_b"]), "row-level security")


def test_unassigned_investigator_sees_nothing(w):
    ian = client_for(w["ian"])
    expect_error(lambda: ian.storage.from_(BUCKET).download(w["video_a"]))
    expect_error(lambda: ian.storage.from_(BUCKET).download(w["ai_json"]))
    assert names_in(ian, f"{w['inc_a']}/media") == set()


def test_admin_reads_everything(w):
    adm = client_for(w["admin"]).storage.from_(BUCKET)
    assert adm.download(w["video_a"]) == VIDEO
    assert adm.download(w["video_b"]) == VIDEO
    assert json.loads(adm.download(w["ai_json"]))


# ------------------------------------------------------------------ command line
def test_command_line_upload(w):
    """Run backend/upload_results.py the way it's used after ai/main.py."""
    result, json_path = make_submission(w["tmp"] / "run3", processed_at="2026-10-09T11:30:00")
    script = str(ROOT / "backend" / "upload_results.py")
    env = dict(os.environ, SUPABASE_URL=URL, SUPABASE_SERVICE_ROLE_KEY=SERVICE_KEY, PYTHONIOENCODING="utf-8")
    run = dict(env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")

    bad = subprocess.run([sys.executable, script, str(json_path), "--incident", str(w["inc_a"]),
                          "--media", str(w["media_a"])], **run)
    assert bad.returncode != 0 and "one per file" in bad.stderr, bad.stderr

    ok = subprocess.run([sys.executable, script, str(json_path), "--incident", str(w["inc_a"]),
                         "--media", str(w["media_a"]), str(w["media_a2"])], **run)
    assert ok.returncode == 0, ok.stderr
    assert f"Uploaded to Supabase Storage: {BUCKET}/{w['inc_a']}/ai/" in ok.stdout, ok.stdout

    # the copy main.py drops next to itself (ai/output_detections.json) works too
    copy_path = json_path.parents[2] / "output_detections.json"
    copy_path.write_text(json_path.read_text(encoding="utf-8"), encoding="utf-8")
    ok2 = subprocess.run([sys.executable, script, str(copy_path), "--incident", str(w["inc_a"]),
                          "--media", str(w["media_a"]), str(w["media_a2"])], **run)
    assert ok2.returncode == 0, ok2.stderr


# ------------------------------------------------------------------ S3 protocol
def test_s3_protocol_access(w):
    if not os.environ.get("ARGUS_TEST_S3_KEY"):
        raise Skip("set ARGUS_TEST_S3_KEY / ARGUS_TEST_S3_SECRET (from `supabase status`)")
    try:
        import boto3
    except ImportError:
        raise Skip("pip install boto3 to run this one")
    s3 = boto3.client("s3", endpoint_url=f"{URL}/storage/v1/s3",
                      aws_access_key_id=os.environ["ARGUS_TEST_S3_KEY"],
                      aws_secret_access_key=os.environ["ARGUS_TEST_S3_SECRET"],
                      region_name=os.environ.get("ARGUS_TEST_S3_REGION", "local"))
    keys = {o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET, Prefix=f"{w['inc_a']}/")["Contents"]}
    assert w["video_a"] in keys and w["ai_json"] in keys
    assert s3.get_object(Bucket=BUCKET, Key=w["video_a"])["Body"].read() == VIDEO


# ------------------------------------------------------------------ runner
def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    only = sys.argv[1:]                       # optional: names (or parts of names) to run
    if only:
        tests = [(n, f) for n, f in tests if any(o in n for o in only)]

    try:
        requests.get(f"{URL}/rest/v1/", headers={"apikey": ANON_KEY}, timeout=5)
    except requests.RequestException:
        sys.exit(f"Can't reach Supabase at {URL}. Run `supabase start` in the database folder first.")

    print(f"Setting up test users and data on {URL} ...")
    started = time.time()
    with tempfile.TemporaryDirectory() as tmp:
        try:
            world = build_world(tmp)
        except Exception:
            traceback.print_exc()
            sys.exit("\nSetup failed (did you run `supabase db reset` so all migrations are applied?)")

        passed = failed = skipped = 0
        for name, fn in tests:
            label = name[len("test_"):].replace("_", " ")
            try:
                fn(world)
                passed += 1
                print(f"  PASS  {label}")
            except Skip as s:
                skipped += 1
                print(f"  SKIP  {label}  ({s})")
            except Exception as e:  # noqa: BLE001
                failed += 1
                print(f"  FAIL  {label}\n        {type(e).__name__}: {e}")

    print(f"\n{passed} passed, {failed} failed, {skipped} skipped in {time.time() - started:.1f}s")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
