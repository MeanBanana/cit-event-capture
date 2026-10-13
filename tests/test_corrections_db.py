"""
Tests for crime scenes inside a case and investigator corrections
(migration 20261013100000_crime_scenes_and_corrections.sql):

  * list_case_crime_scenes()  the cards on the case page
  * get_crime_scene()         one crime scene: files, detections, corrections log
  * correct_detection()       an investigator corrects what the AI found,
                              logged in correctionlog

Same setup as tests/test_ai_pipeline_db.py (it reuses its helpers): runs
against the LOCAL Supabase database, every test in its own transaction that
is rolled back, each call made as the role the app / worker would have.

    cd database && supabase start && supabase db reset && cd ..
    pip install "psycopg[binary]" numpy opencv-python
    python tests/test_corrections_db.py                (all tests)
    python tests/test_corrections_db.py plate dismiss  (only names containing these)
"""

import os
import sys
import time
import traceback

import psycopg

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_ai_pipeline_db import (  # noqa: E402
    DB_URL, PERSON_A, SANDTON, World, analysed_case, claim, entity, evidence, jobs, look,
    person, report, results, run_case_jobs, session, vehicle, weapon, worker_analyse,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def assign(db, w, case_id, who=None):
    db.rpc("assign_investigator", who=w.admin, p_caseid=case_id,
           p_userid=(who or w.investigator)["userid"])


def detections(db, inc, kind=None):
    rows = db.rows("SELECT d.* FROM public.detection d JOIN public.media m USING (mediaid) "
                   "WHERE m.incidentid = %s ORDER BY d.detectiontype, d.mediaid, d.trackid", [inc])
    return [r for r in rows if kind is None or r["detectiontype"] == kind]


def correct(db, who, detection_id, field, value, note=None):
    return db.rpc("correct_detection", who=who, p_detectionid=detection_id,
                  p_field=field, p_value=value, p_note=note)


def scene(db, inc, who):
    return db.rpc("get_crime_scene", who=who, p_incidentid=inc)


def cards(db, case_id, who):
    return db.rows("SELECT * FROM public.list_case_crime_scenes(%s)", [case_id], who=who)


def field(det, name):
    return next(f for f in det["fields"] if f["field"] == name)


def det_by_label(view, label):
    return next(d for d in view["detections"] if d["label"] == label)


def case_with_investigator(db, w):
    inc, media, case_id, case = analysed_case(db, w)
    assign(db, w, case_id)
    return inc, media, case_id


# ---------------------------------------------------------------------------
# Crime scene cards
# ---------------------------------------------------------------------------

def test_cards_show_counts_per_crime_scene(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    # a second crime scene in the same case, still waiting for the AI
    other, _ = report(db, w.citizen, files=2, location="William Nicol Dr")
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=other)
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[other])

    rows = {r["incidentid"]: r for r in cards(db, case_id, w.investigator)}
    assert set(rows) == {inc, other}, rows
    first = rows[inc]
    assert (first["suspects"], first["vehicles"], first["weapons"]) == (1, 1, 1), first
    assert first["analysisstatus"] == "done" and first["location"] == "Rivonia Rd, Sandton"
    assert first["mediacount"] == 1 and first["correctioncount"] == 0
    second = rows[other]
    assert second["analysisstatus"] == "pending", second
    assert (second["suspects"], second["vehicles"], second["weapons"]) == (0, 0, 0)

    claim(db)                                         # the worker starts on it
    rows = {r["incidentid"]: r for r in cards(db, case_id, w.admin)}
    assert rows[other]["analysisstatus"] == "analysing", rows[other]


def test_same_person_in_two_clips_counts_once(db, w):
    inc, media = report(db, w.citizen, files=2)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    worker_analyse(db, inc, results(inc, media, [[person(1, look(PERSON_A, 0.97, 10))],
                                                 [person(1, look(PERSON_A, 0.96, 20)),
                                                  person(2, look(PERSON_A, 0.2, 30))]]))
    case_id = db.rpc("create_case", who=w.admin, p_title="Two clips", p_incidentids=[inc])
    row = cards(db, case_id, w.admin)[0]
    assert row["suspects"] == 2, row                  # most in one clip, not 3


def test_only_admins_and_assigned_investigators_see_crime_scenes(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    db.fails(cards, db, case_id, w.other_investigator, contains="Only admins and investigators")
    db.fails(cards, db, case_id, w.citizen, contains="Only admins and investigators")
    db.fails(scene, db, inc, w.other_investigator, contains="Only admins and investigators")
    db.fails(scene, db, inc, w.citizen, contains="Only admins and investigators")
    db.fails(scene, db, inc, "anon", contains="permission denied")
    assert scene(db, inc, w.investigator)["incident_id"] == inc
    assert scene(db, inc, w.admin)["incident_id"] == inc


def test_crime_scene_page_lists_files_and_fields(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    view = scene(db, inc, w.investigator)
    assert view["analysis"] == {"status": "done", "files": 1, "done": 1, "failed": 0}, view["analysis"]
    assert view["can_correct"] is True
    assert [f["media_id"] for f in view["files"]] == media
    assert view["files"][0]["status"] == "completed" and view["files"][0]["number"] == 1
    assert [d["label"] for d in view["detections"]] == ["Person 1", "Vehicle 1", "Weapon 1"]

    car = det_by_label(view, "Vehicle 1")
    assert [f["field"] for f in car["fields"]] == ["vehicle_type", "make", "model", "colour", "plate",
                                                   "dismissed"]
    assert field(car, "plate") == {"field": "plate", "ai": "ND123456", "value": "ND123456",
                                   "corrected": False}
    assert field(car, "make")["value"] == "Toyota"
    assert car["crops"] and car["clip"] == 1 and car["can_correct"] is True
    gun = det_by_label(view, "Weapon 1")
    assert field(gun, "weapon_type")["value"] == "long_gun"
    who = det_by_label(view, "Person 1")
    assert field(who, "upper_clothing")["value"] == "black" and who["suspect_status"] == "possible"
    assert view["corrections"] == []


# ---------------------------------------------------------------------------
# Corrections
# ---------------------------------------------------------------------------

def test_correcting_a_plate_is_logged(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    car = detections(db, inc, "vehicle")[0]["detectionid"]

    out = correct(db, w.investigator, car, "plate", "nd 654-321", note="Clear in frame 210")
    assert out["original"] == "ND123456" and out["corrected"] == "ND654321", out

    log = db.rows("SELECT * FROM public.correctionlog WHERE detectionid = %s", [car])
    assert len(log) == 1, log
    row = log[0]
    assert (row["fieldname"], row["originalvalue"], row["correctedvalue"]) == ("plate", "ND123456", "ND654321")
    assert row["correctedby"] == w.investigator["userid"] and row["note"] == "Clear in frame 210"

    # the detail table follows (plate matching between submissions uses it)
    vd = db.one("SELECT * FROM public.vehicledetail WHERE detectionid = %s", [car])
    assert vd["licenceplatenumber"] == "ND654321" and vd["platedetected"] is True, vd

    view = scene(db, inc, w.investigator)
    plate = field(det_by_label(view, "Vehicle 1"), "plate")
    assert plate == {"field": "plate", "ai": "ND123456", "value": "ND654321", "corrected": True}, plate
    entry = view["corrections"][0]
    assert entry["label"] == "Vehicle 1" and entry["field"] == "plate"
    assert entry["original"] == "ND123456" and entry["corrected"] == "ND654321"
    assert entry["by"] == "Investigator Tester", entry
    assert cards(db, case_id, w.investigator)[0]["correctioncount"] == 1

    # the case history says so
    event = db.one("SELECT * FROM public.caseevent WHERE caseid = %s AND eventtype = 'detection_corrected'",
                   [case_id])
    assert event and "ND123456 → ND654321" in event["detail"], event


def test_each_correction_is_linked_to_its_crime_scene(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    other, other_media = report(db, w.citizen, files=1, location="William Nicol Dr")
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=other)
    worker_analyse(db, other, results(other, other_media, [[vehicle(1, plate="CA 1")]]))
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[other])
    run_case_jobs(db)

    here = detections(db, inc, "vehicle")[0]["detectionid"]
    there = detections(db, other, "vehicle")[0]["detectionid"]
    correct(db, w.investigator, here, "make", "Nissan")
    correct(db, w.investigator, there, "colour", "red")

    rows = db.rows("SELECT detectionid, incidentid FROM public.correctionlog ORDER BY correctionid")
    assert [(r["detectionid"], r["incidentid"]) for r in rows] == [(here, inc), (there, other)], rows
    # each crime scene's log has only its own correction
    assert [c["field"] for c in scene(db, inc, w.investigator)["corrections"]] == ["make"]
    assert [c["field"] for c in scene(db, other, w.investigator)["corrections"]] == ["colour"]
    assert scene(db, inc, w.investigator)["corrections"][0]["incident_id"] == inc
    counts = {r["incidentid"]: r["correctioncount"] for r in cards(db, case_id, w.investigator)}
    assert counts == {inc: 1, other: 1}, counts

    # the crime scene always comes from the detection: it can't be set to another one
    db.rows("UPDATE public.correctionlog SET incidentid = %s WHERE detectionid = %s", [other, here])
    assert db.val("SELECT incidentid FROM public.correctionlog WHERE detectionid = %s", [here]) == inc


def test_every_field_kind_can_be_corrected(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    who = detections(db, inc, "person")[0]["detectionid"]
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    gun = detections(db, inc, "weapon")[0]["detectionid"]

    correct(db, w.investigator, who, "upper_clothing", "Red")
    correct(db, w.investigator, who, "lower_clothing", "grey")
    correct(db, w.investigator, car, "vehicle_type", "bakkie")
    correct(db, w.investigator, car, "make", "Nissan")
    correct(db, w.investigator, car, "model", "Navara")
    correct(db, w.investigator, car, "colour", "Silver")
    correct(db, w.admin, gun, "weapon_type", "handgun")         # admins may too

    view = scene(db, inc, w.investigator)
    p, v, g = (det_by_label(view, x) for x in ("Person 1", "Vehicle 1", "Weapon 1"))
    assert field(p, "upper_clothing")["value"] == "red" and field(p, "lower_clothing")["value"] == "grey"
    assert [field(v, f)["value"] for f in ("vehicle_type", "make", "model", "colour")] == \
        ["bakkie", "Nissan", "Navara", "silver"]
    assert field(g, "weapon_type")["value"] == "handgun"
    assert db.val("SELECT weapontype FROM public.weapondetail WHERE detectionid = %s", [gun]) == "handgun"
    vd = db.one("SELECT * FROM public.vehicledetail WHERE detectionid = %s", [car])
    assert (vd["vehicletype"], vd["make"], vd["model"], vd["colour"]) == ("bakkie", "Nissan", "Navara", "silver")
    assert db.val("SELECT count(*) FROM public.correctionlog") == 7


def test_wrong_fields_and_values_are_refused(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    who = detections(db, inc, "person")[0]["detectionid"]
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    gun = detections(db, inc, "weapon")[0]["detectionid"]
    db.fails(correct, db, w.investigator, who, "plate", "ABC123", contains="can't be corrected on a person")
    db.fails(correct, db, w.investigator, gun, "make", "Glock", contains="can't be corrected on a weapon")
    db.fails(correct, db, w.investigator, gun, "weapon_type", "bazooka", contains="Unknown weapon type")
    db.fails(correct, db, w.investigator, car, "plate", "ND 123 456", contains="Nothing changed")
    db.fails(correct, db, w.investigator, car, "plate", "A" * 13, contains="at most 12")
    db.fails(correct, db, w.investigator, car, "dismissed", "maybe", contains="true or false")
    db.fails(correct, db, w.investigator, car, "dismissed", "true", contains="Say why")
    assert db.val("SELECT count(*) FROM public.correctionlog") == 0


def test_only_investigators_on_the_case_and_admins_can_correct(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    db.fails(correct, db, w.other_investigator, car, "make", "Nissan", contains="not assigned")
    db.fails(correct, db, w.citizen, car, "make", "Nissan", contains="Only investigators and admins")
    db.fails(correct, db, "anon", car, "make", "Nissan", contains="permission denied")

    db.rpc("set_case_status", who=w.admin, p_caseid=case_id, p_status="closed")
    db.fails(correct, db, w.investigator, car, "make", "Nissan", contains="is closed")
    assert scene(db, inc, w.investigator)["can_correct"] is False
    correct(db, w.admin, car, "make", "Nissan")                 # admins still can
    assert scene(db, inc, w.admin)["can_correct"] is True


def test_no_corrections_while_the_ai_is_working(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    # the citizen's footage is sent for analysis again (e.g. a new run)
    db.rows("UPDATE public.media SET processingstatus = 'pending' WHERE incidentid = %s", [inc])
    db.rpc("submit_for_analysis", who=w.admin, p_incidentid=inc)
    view = scene(db, inc, w.investigator)
    assert view["analysis"]["status"] == "pending" and view["can_correct"] is False, view["analysis"]
    assert not det_by_label(view, "Vehicle 1")["can_correct"]
    db.fails(correct, db, w.investigator, car, "make", "Nissan", contains="still working")

    claim(db)
    assert scene(db, inc, w.investigator)["analysis"]["status"] == "analysing"
    db.fails(correct, db, w.investigator, car, "make", "Nissan", contains="still working")


def test_app_users_cannot_change_details_or_the_log_directly(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    gun = detections(db, inc, "weapon")[0]["detectionid"]
    me = w.investigator
    db.fails(db.rows, "UPDATE public.vehicledetail SET make = 'Nissan' WHERE detectionid = %s", [car],
             who=me, contains="permission denied")
    db.fails(db.rows, "UPDATE public.weapondetail SET weapontype = 'knife' WHERE detectionid = %s", [gun],
             who=me, contains="permission denied")
    db.fails(db.rows, "INSERT INTO public.correctionlog (detectionid, correctedby, originalvalue, "
                      "correctedvalue) VALUES (%s, %s, 'a', 'b')", [car, me["userid"]],
             who=me, contains="permission denied")
    # (no update policy on detection: the row is simply not changed)
    db.rows("UPDATE public.detection SET corrections = '{\"make\": \"x\"}' WHERE detectionid = %s",
            [car], who=me)
    assert db.val("SELECT corrections FROM public.detection WHERE detectionid = %s", [car]) == {}
    # nor the AI worker: a correction is a person's decision
    db.fails(db.rows, "UPDATE public.detection SET corrections = '{\"make\": \"x\"}' WHERE detectionid = %s",
             [car], who="service", contains="correct_detection")
    # investigators can read the log of their case
    correct(db, me, car, "make", "Nissan")
    assert len(db.rows("SELECT * FROM public.correctionlog", who=me)) == 1
    assert db.rows("SELECT * FROM public.correctionlog", who=w.other_investigator) == []


def test_setting_the_ai_value_again_removes_the_correction(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    correct(db, w.investigator, car, "make", "Nissan")
    correct(db, w.investigator, car, "make", "Toyota")
    det = db.one("SELECT corrections FROM public.detection WHERE detectionid = %s", [car])
    assert det["corrections"] == {}, det
    make = field(det_by_label(scene(db, inc, w.investigator), "Vehicle 1"), "make")
    assert make == {"field": "make", "ai": "Toyota", "value": "Toyota", "corrected": False}
    log = db.rows("SELECT originalvalue, correctedvalue FROM public.correctionlog "
                  "WHERE detectionid = %s ORDER BY correctionid", [car])
    assert [(r["originalvalue"], r["correctedvalue"]) for r in log] == [("Toyota", "Nissan"), ("Nissan", "Toyota")]


def test_clearing_a_plate(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    out = correct(db, w.investigator, car, "plate", "", note="Plate is not readable")
    assert out["corrected"] is None
    vd = db.one("SELECT * FROM public.vehicledetail WHERE detectionid = %s", [car])
    assert vd["licenceplatenumber"] is None and vd["platedetected"] is False
    assert db.val("SELECT correctedvalue FROM public.correctionlog WHERE detectionid = %s", [car]) == ""
    assert field(det_by_label(scene(db, inc, w.admin), "Vehicle 1"), "plate")["value"] is None


def test_corrections_survive_a_new_analysis(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    correct(db, w.investigator, car, "plate", "ND654321")
    run_case_jobs(db)

    # analysed again: same tracks, the AI still reads ND123456
    db.rpc("submit_for_analysis", who=w.admin, p_incidentid=inc)
    worker_analyse(db, inc, results(inc, media, [[person(1, look(PERSON_A, 0.97, 10)),
                                                  vehicle(2), weapon(1, held_by=1)]], location=SANDTON))
    assert detections(db, inc, "vehicle")[0]["detectionid"] == car
    plate = field(det_by_label(scene(db, inc, w.investigator), "Vehicle 1"), "plate")
    assert plate["value"] == "ND654321" and plate["corrected"] is True, plate
    assert db.val("SELECT licenceplatenumber FROM public.vehicledetail WHERE detectionid = %s",
                  [car]) == "ND654321"


def test_case_summary_uses_the_corrected_values(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    gun = detections(db, inc, "weapon")[0]["detectionid"]
    correct(db, w.investigator, car, "plate", "ND654321")
    correct(db, w.investigator, gun, "weapon_type", "shotgun")

    assert jobs(db, kind="summary", caseid=case_id, status="queued"), "a summary job is queued"
    assert db.val("SELECT aisummarystatus FROM public.cases WHERE caseid = %s", [case_id]) == "outdated"
    member = db.rpc("ai_member", who="postgres", p_detectionid=car)   # what ai_load_case uses
    assert member["attributes"]["plate"] == "ND654321" and member["attributes"]["plate_confidence"] == 1

    run_case_jobs(db)
    view = evidence(db, case_id, w.admin)
    assert entity(view, "Vehicle 1")["attributes"]["plate"] == "ND654321", entity(view, "Vehicle 1")
    assert entity(view, "Weapon 1")["attributes"]["kind"] == "shotgun", entity(view, "Weapon 1")


def test_dismissing_a_false_weapon(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    gun = detections(db, inc, "weapon")[0]["detectionid"]
    assert db.val("SELECT caseentityid FROM public.detection WHERE detectionid = %s", [gun]) is not None

    correct(db, w.investigator, gun, "dismissed", "true", note="It is an umbrella")
    # out of the case straight away; Weapon 1 had nothing else, so it is gone
    assert db.val("SELECT caseentityid FROM public.detection WHERE detectionid = %s", [gun]) is None
    assert db.val("SELECT count(*) FROM public.caseentity WHERE caseid = %s AND kind = 'weapon'",
                  [case_id]) == 0
    row = cards(db, case_id, w.investigator)[0]
    assert (row["suspects"], row["vehicles"], row["weapons"]) == (1, 1, 0), row
    view = scene(db, inc, w.investigator)
    assert det_by_label(view, "Weapon 1")["dismissed"] is True
    assert view["corrections"][0]["note"] == "It is an umbrella"

    # the worker never merges it back
    run_case_jobs(db)
    assert evidence(db, case_id, w.admin)["weapons"] == []
    sub = db.rpc("ai_load_submission", who="service", p_incidentid=inc)
    assert str(gun) not in [m["key"] for m in sub["members"]]
    # ... not even a worker that saves a case it loaded before the dismissal
    weapon_entity = db.val("INSERT INTO public.caseentity (caseid, kind, number) VALUES (%s, 'weapon', 9) "
                           "RETURNING entityid", [case_id])
    db.rows("UPDATE public.detection SET caseentityid = %s, matchstatus = 'first' WHERE detectionid = %s",
            [weapon_entity, gun], who="service")
    assert db.val("SELECT caseentityid FROM public.detection WHERE detectionid = %s", [gun]) is None


def test_undoing_a_dismissal_puts_it_back(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    gun = detections(db, inc, "weapon")[0]["detectionid"]
    correct(db, w.investigator, gun, "dismissed", "true", note="Looked like an umbrella")
    run_case_jobs(db)
    correct(db, w.investigator, gun, "dismissed", "false")
    assert jobs(db, kind="rematch", detectionid=gun, status="queued")
    run_case_jobs(db)
    assert [e["label"] for e in evidence(db, case_id, w.admin)["weapons"]] == ["Weapon 1"]
    assert cards(db, case_id, w.admin)[0]["weapons"] == 1
    events = db.rows("SELECT detail FROM public.caseevent WHERE caseid = %s AND eventtype = "
                     "'detection_corrected' ORDER BY eventid", [case_id])
    assert [e["detail"] for e in events] == ["Weapon 1 marked as not a real weapon", "Weapon 1 restored"]


def test_a_confirmed_suspect_cannot_be_dismissed(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    who = detections(db, inc, "person")[0]["detectionid"]
    db.rpc("review_possible_suspect", who=w.investigator, p_detectionid=who, p_decision="confirmed")
    db.fails(correct, db, w.investigator, who, "dismissed", "true", note="bystander",
             contains="confirmed suspect")


def test_corrections_before_a_case(db, w):
    """A crime scene not in a case yet: admins may correct it; nothing is queued."""
    inc, media = report(db, w.citizen, files=1)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    worker_analyse(db, inc, results(inc, media, [[vehicle(1)]]))
    car = detections(db, inc, "vehicle")[0]["detectionid"]
    correct(db, w.admin, car, "colour", "blue")
    assert jobs(db, kind="summary") == []
    assert scene(db, inc, w.admin)["case_id"] is None


def test_failed_analysis_is_reported(db, w):
    inc, media, case_id = case_with_investigator(db, w)
    other, other_media = report(db, w.citizen, files=1)
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=other)
    for _ in range(3):                                 # three attempts, then failed
        job = claim(db)
        db.rpc("finish_job", p_jobid=job["jobid"], p_error="RuntimeError: CUDA out of memory")
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[other])
    row = next(r for r in cards(db, case_id, w.admin) if r["incidentid"] == other)
    assert row["analysisstatus"] == "failed" and row["filesfailed"] == 1, row

    empty, _ = report(db, w.citizen, files=0)
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[empty])
    row = next(r for r in cards(db, case_id, w.admin) if r["incidentid"] == empty)
    assert row["analysisstatus"] == "no_footage", row


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
